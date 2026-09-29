--[[
	╔══════════════════════════════════════════════╗
	║   Ride A Pet Hub — สคริปต์ครบวงจร (ไฟล์เดียว)   ║
	╠══════════════════════════════════════════════╣
	║  RightShift : เปิด/ปิดเมนู                      ║
	║  F          : บิน (WASD ตามกล้อง, Space/Ctrl ขึ้นลง) ║
	║  N          : Noclip                          ║
	║  ฟีเจอร์: ฟาร์มไข่อัตโนมัติ (เก็บ→กลับบ้านฝาก)     ║
	║           ESP ไข่ทุกระดับ, เดินเร็ว, กระโดดสูง,   ║
	║           Anti-AFK                             ║
	╚══════════════════════════════════════════════╝
	วิธีใช้: คัดลอกทั้งไฟล์ไปรันใน executor ของ Roblox
	(ทำงานกับผู้เล่นทุกคน ตรวจหาบ้าน/รังของแต่ละคนให้อัตโนมัติ)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local VirtualUser = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer

-- ประกาศล่วงหน้า (กำหนดค่าทีหลัง)
local notifyUI, shutdown, statusPara, WindUILib

--═══════════════ ปิดสคริปต์รอบก่อน (ถ้ามี) ═══════════════
do
	local old = getgenv().__RideHubHandle
	if old and old.shutdown then pcall(old.shutdown) end
	local oldFly = getgenv().__FlyHandle
	if oldFly and oldFly.shutdown then pcall(oldFly.shutdown) end
end

--═══════════════ GAME DATA ═══════════════
local EggConfig = {}
do
	local gd = ReplicatedStorage:FindFirstChild("GameData")
	local mod = gd and gd:FindFirstChild("Eggs")
	if mod then
		local ok, result = pcall(require, mod)
		if ok and type(result) == "table" then EggConfig = result end
	end
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Game")
local EggPickup = Remotes:WaitForChild("EggPickup")
local EggArrivalClaim = Remotes:FindFirstChild("EggArrivalClaim")

local RARITY_LIST = { "Common", "Rare", "Epic", "Legendary", "Mythic", "Divine", "Ethereal" }
local RARITY_ORDER = { Common = 1, Rare = 2, Epic = 3, Legendary = 4, Mythic = 5, Divine = 6, Ethereal = 7 }
local RARITY_COLOR = {
	Common = Color3.fromRGB(200, 200, 200),
	Rare = Color3.fromRGB(80, 160, 255),
	Epic = Color3.fromRGB(175, 90, 255),
	Legendary = Color3.fromRGB(255, 170, 30),
	Mythic = Color3.fromRGB(255, 70, 70),
	Divine = Color3.fromRGB(60, 255, 230),
	Ethereal = Color3.fromRGB(255, 255, 255),
}

--═══════════════ SETTINGS ═══════════════
local Settings = {
	rarities = { Common = true, Rare = true, Epic = true, Legendary = true, Mythic = true, Divine = true, Ethereal = true },
	rarestFirst = true,
	settleDelay = 1.2,
	perEggDelay = 0.3,
	autoRepeat = false,
	repeatDelay = 10,
	eggsPerTrip = 1,
	stopWhenNoNest = true,
	esp = false,
	espDistance = true,
	flySpeed = 60,
	walkLock = false,
	walkSpeed = 16,
	jumpLock = false,
	jumpPower = 50,
	antiAfk = false,
}

--═══════════════ STATE ═══════════════
local version = 0
version += 1

local connections = {}
local function bind(signal, fn)
	local conn = signal:Connect(fn)
	table.insert(connections, conn)
	return conn
end

local farming = false
local farmStats = { collected = 0, failed = 0, last = "-" }
local espObjects = {}
local espOrigColors = {}

--═══════════════ HELPERS ═══════════════
local function getRoot(char)
	char = char or LocalPlayer.Character
	if not char then return nil end
	return char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
end

local function getHumanoid(char)
	char = char or LocalPlayer.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function teleportTo(cf)
	local root = getRoot()
	if not root then return false end
	local hum = getHumanoid()
	if hum then hum.Sit = false end
	root.AssemblyLinearVelocity = Vector3.zero
	root.CFrame = cf
	return true
end

local function getPlot()
	local plots = Workspace:FindFirstChild("Plots")
	if not plots then return nil end
	for _, plot in ipairs(plots:GetChildren()) do
		local data = plot:FindFirstChild("Data")
		local owner = data and data:FindFirstChild("Owner")
		if owner and owner.Value == LocalPlayer then
			return plot
		end
	end
	return nil
end

local function getHomeCF()
	local plot = getPlot()
	local base = plot and plot:FindFirstChild("Baseplate")
	if base then
		return CFrame.new(base.Position + Vector3.new(0, base.Size.Y * 0.5 + 3.5, 0))
	end
	return nil
end

local function getBasket()
	return LocalPlayer:FindFirstChild("Basket")
end

local function basketCount()
	local basket = getBasket()
	return basket and #basket:GetChildren() or 0
end

local function hasFreeNest()
	return LocalPlayer:GetAttribute("NoNest") ~= true
end

--═══════════════ FLY ═══════════════
local flyState = { on = false, bv = nil, bg = nil }
local flyOnChanged = nil

local function flyDestroyParts()
	if flyState.bv then
		flyState.bv:Destroy()
		flyState.bv = nil
	end
	if flyState.bg then
		flyState.bg:Destroy()
		flyState.bg = nil
	end
end

local function flyStop(silent)
	flyState.on = false
	flyDestroyParts()
	local hum = getHumanoid()
	if hum then hum.PlatformStand = false end
	local root = getRoot()
	if root then root.AssemblyLinearVelocity = Vector3.zero end
	if flyOnChanged then pcall(flyOnChanged, false) end
	if not silent then notifyUI("ปิดบินแล้ว") end
end

local function flyStart()
	local root, hum = getRoot(), getHumanoid()
	if not root or not hum or hum.Health <= 0 then return end
	hum.Sit = false
	hum.PlatformStand = true
	flyDestroyParts()
	flyState.bv = Instance.new("BodyVelocity")
	flyState.bv.Name = "HubFlyVelocity"
	flyState.bv.MaxForce = Vector3.new(1e9, 1e9, 1e9)
	flyState.bv.Velocity = Vector3.zero
	flyState.bv.Parent = root
	flyState.bg = Instance.new("BodyGyro")
	flyState.bg.Name = "HubFlyGyro"
	flyState.bg.MaxTorque = Vector3.new(1e9, 1e9, 1e9)
	flyState.bg.P = 9e4
	flyState.bg.D = 2659
	flyState.bg.CFrame = root.CFrame
	flyState.bg.Parent = root
	flyState.on = true
	if flyOnChanged then pcall(flyOnChanged, true) end
end

local function flyToggle(silent)
	if flyState.on then flyStop(silent) else flyStart() end
end

local noclip = false

local function setNoclip(on, silent)
	noclip = on
	if not on then
		local char = LocalPlayer.Character
		if char then
			for _, part in ipairs(char:GetDescendants()) do
				if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
					local holder = part.Parent
					if holder and holder:IsA("Accessory") then continue end
					part.CanCollide = true
				end
			end
		end
	end
	if not silent then notifyUI("Noclip: " .. (on and "เปิด" or "ปิด")) end
end

bind(RunService.RenderStepped, function()
	if flyState.on then
		local root, hum = getRoot(), getHumanoid()
		if not root or not hum or hum.Health <= 0 then
			flyStop(true)
			return
		end
		local cam = Workspace.CurrentCamera
		local move = Vector3.zero
		if cam then
			local look = cam.CFrame.LookVector
			local right = cam.CFrame.RightVector
			if UserInputService:IsKeyDown(Enum.KeyCode.W) then move += look end
			if UserInputService:IsKeyDown(Enum.KeyCode.S) then move -= look end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then move += right end
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then move -= right end
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) then move += Vector3.yAxis end
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then move -= Vector3.yAxis end
		if flyState.bv then
			flyState.bv.Velocity = move.Magnitude > 0 and move.Unit * Settings.flySpeed or Vector3.zero
		end
		if flyState.bg and cam then
			local look = cam.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			if flat.Magnitude > 0.01 then
				flyState.bg.CFrame = CFrame.lookAt(root.Position, root.Position + flat)
			end
		end
		hum.PlatformStand = true
	end
	if noclip then
		local char = LocalPlayer.Character
		if char then
			for _, part in ipairs(char:GetDescendants()) do
				if part:IsA("BasePart") then part.CanCollide = false end
			end
		end
	end
end)

bind(UserInputService.InputBegan, function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.F then
		flyToggle()
	elseif input.KeyCode == Enum.KeyCode.N then
		setNoclip(not noclip)
	end
end)

bind(LocalPlayer.CharacterAdded, function(char)
	local v = version
	char:WaitForChild("HumanoidRootPart", 5)
	task.wait(0.2)
	if version == v and flyState.on then
		flyStart()
	end
end)

--═══════════════ ล็อกความเร็วเดิน/กระโดด ═══════════════
bind(RunService.Heartbeat, function()
	local hum = getHumanoid()
	if not hum then return end
	if Settings.walkLock and hum.WalkSpeed ~= Settings.walkSpeed then
		hum.WalkSpeed = Settings.walkSpeed
	end
	if Settings.jumpLock then
		if hum.UseJumpPower then
			if hum.JumpPower ~= Settings.jumpPower then hum.JumpPower = Settings.jumpPower end
		else
			hum.UseJumpPower = true
			hum.JumpPower = Settings.jumpPower
		end
	end
end)

--═══════════════ ANTI-AFK ═══════════════
local antiAfkConn = nil
local function setAntiAfk(on)
	Settings.antiAfk = on
	if antiAfkConn then
		antiAfkConn:Disconnect()
		antiAfkConn = nil
	end
	if on then
		antiAfkConn = LocalPlayer.Idled:Connect(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
		table.insert(connections, antiAfkConn)
	end
end

--═══════════════ ESP ไข่ ═══════════════
local function rarityOf(eggName)
	local info = EggConfig[eggName]
	return info and info.Rarity or "Common"
end

local function espClear()
	for model, obj in pairs(espObjects) do
		if obj.billboard then obj.billboard:Destroy() end
		local hl = model:FindFirstChild("EggOutline")
		if hl and hl:IsA("Highlight") then
			local orig = espOrigColors[model]
			if orig then hl.OutlineColor = orig end
		end
	end
	table.clear(espObjects)
	table.clear(espOrigColors)
end

local function espUpdate()
	local rendered = Workspace:FindFirstChild("RenderedEggs")
	if not rendered then return end
	local root = getRoot()
	local seen = {}
	for _, model in ipairs(rendered:GetChildren()) do
		local base = model:FindFirstChild("EggBase")
		if base then
			seen[model] = true
			local obj = espObjects[model]
			if not obj then
				local billboard = Instance.new("BillboardGui")
				billboard.Name = "HubEggESP"
				billboard.Adornee = base
				billboard.AlwaysOnTop = true
				billboard.Size = UDim2.new(0, 170, 0, 52)
				billboard.StudsOffset = Vector3.new(0, 3.4, 0)
				billboard.MaxDistance = 5000
				local label = Instance.new("TextLabel")
				label.Name = "Label"
				label.BackgroundTransparency = 1
				label.Size = UDim2.new(1, 0, 1, 0)
				label.Font = Enum.Font.GothamBold
				label.TextScaled = true
				label.TextStrokeTransparency = 0.2
				label.TextColor3 = RARITY_COLOR[rarityOf(model.Name)] or Color3.new(1, 1, 1)
				label.Parent = billboard
				billboard.Parent = base
				local hl = model:FindFirstChild("EggOutline")
				if hl and hl:IsA("Highlight") then
					if espOrigColors[model] == nil then
						espOrigColors[model] = hl.OutlineColor
					end
					hl.OutlineColor = RARITY_COLOR[rarityOf(model.Name)] or Color3.new(1, 1, 1)
					hl.OutlineTransparency = 0
				end
				obj = { billboard = billboard, label = label, base = base }
				espObjects[model] = obj
			end
			local dist = root and math.floor((obj.base.Position - root.Position).Magnitude) or 0
			obj.label.Text = ("%s\n%s"):format(model.Name, Settings.espDistance and (dist .. " สตั๊ด") or "")
		end
	end
	for model, obj in pairs(espObjects) do
		if not seen[model] or not model.Parent then
			if obj.billboard then obj.billboard:Destroy() end
			espObjects[model] = nil
		end
	end
end

local function setEsp(on)
	Settings.esp = on
	if not on then
		espClear()
	end
end

-- ลูปอัปเดต ESP ทุก 0.5 วิ
local espAcc = 0
bind(RunService.Heartbeat, function(dt)
	if not Settings.esp then return end
	espAcc += dt
	if espAcc < 0.5 then return end
	espAcc = 0
	espUpdate()
end)

--═══════════════ สแกนไข่ (ข้อมูลฝั่งเซิร์ฟ) ═══════════════
local function anyRaritySelected()
	for _, r in ipairs(RARITY_LIST) do
		if Settings.rarities[r] then return true end
	end
	return false
end

local function scanEggs()
	local list = {}
	local serverData = ReplicatedStorage:FindFirstChild("ServerData")
	local activeEggs = serverData and serverData:FindFirstChild("ActiveEggs")
	local rendered = Workspace:FindFirstChild("RenderedEggs")
	if not activeEggs then return list end
	local filterOn = anyRaritySelected()
	local renderedList = rendered and rendered:GetChildren() or {}
	local root = getRoot()
	for _, marker in ipairs(activeEggs:GetChildren()) do
		local eggName = marker:GetAttribute("Egg")
		local pos = marker:GetAttribute("Position")
		local info = eggName and EggConfig[eggName]
		local rarity = info and info.Rarity or "Common"
		if info and pos and (not filterOn or Settings.rarities[rarity]) then
			local bestModel, bestD
			for _, m in ipairs(renderedList) do
				if m.Name == eggName then
					local base = m:FindFirstChild("EggBase")
					if base then
						local d = (base.Position - pos).Magnitude
						if d < (bestD or 12) then
							bestModel, bestD = m, d
						end
					end
				end
			end
			if bestModel then
				table.insert(list, {
					guid = marker.Name,
					name = eggName,
					rarity = rarity,
					luck = tonumber(info.Luck) or 0,
					pos = pos,
					dist = root and (root.Position - pos).Magnitude or 0,
				})
			end
		end
	end
	if Settings.rarestFirst then
		table.sort(list, function(a, b)
			local ra, rb = RARITY_ORDER[a.rarity] or 0, RARITY_ORDER[b.rarity] or 0
			if ra ~= rb then return ra > rb end
			return a.dist < b.dist
		end)
	else
		table.sort(list, function(a, b)
			return a.dist < b.dist
		end)
	end
	return list
end

--═══════════════ ฟาร์มไข่ ═══════════════
local pendingReplies = {}

bind(EggPickup.OnClientEvent, function(status, info, key)
	if key then
		pendingReplies[key] = { status = status, info = info }
	end
end)

local function tryPickup(entry)
	local root = getRoot()
	if not root then return { status = "NoCharacter" } end
	teleportTo(CFrame.new(entry.pos + Vector3.new(0, 4, 0)))
	task.wait(Settings.settleDelay)
	pendingReplies[entry.guid] = nil
	EggPickup:FireServer(entry.guid)
	local t0 = os.clock()
	while os.clock() - t0 < 3 do
		local reply = pendingReplies[entry.guid]
		if reply then return reply end
		task.wait(0.1)
	end
	return { status = "NoReply" }
end

local function depositAtHome()
	local homeCF = getHomeCF()
	if not homeCF then return false end
	teleportTo(homeCF)
	task.wait(1.0)
	local t0 = os.clock()
	while os.clock() - t0 < 4 do
		if basketCount() == 0 then return true end
		task.wait(0.25)
	end
	local basket = getBasket()
	local root = getRoot()
	if basket and #basket:GetChildren() > 0 and root and EggArrivalClaim then
		pcall(function()
			EggArrivalClaim:FireServer(Workspace:GetServerTimeNow(), root.Position, basket:GetChildren())
		end)
		task.wait(1.5)
	end
	return basketCount() == 0
end

local function farmLoop()
	while farming do
		local hum = getHumanoid()
		if not hum or hum.Health <= 0 then
			task.wait(1)
			continue
		end
		if not hasFreeNest() and Settings.stopWhenNoNest then
			farmStats.last = "รังเต็ม! เอาไข่ไปฟักก่อน"
			farming = false
			break
		end
		local list = scanEggs()
		if #list == 0 then
			farmStats.last = "ไม่มีไข่ตามเงื่อนไข"
			if Settings.autoRepeat then
				task.wait(Settings.repeatDelay)
				continue
			else
				break
			end
		end
		for _, entry in ipairs(list) do
			if not farming then break end
			if not hasFreeNest() and Settings.stopWhenNoNest and basketCount() > 0 then
				break
			end
			local reply = tryPickup(entry)
			if reply.status == "PickedUp" then
				farmStats.collected += 1
				farmStats.last = ("เก็บ %s สำเร็จ"):format(entry.name)
				task.wait(0.2)
				if basketCount() >= Settings.eggsPerTrip then
					if depositAtHome() then
						farmStats.last = "ฝากไข่ที่บ้านแล้ว"
					else
						farmStats.last = "ฝากไม่สำเร็จ (รังเต็ม?)"
					end
				end
			else
				farmStats.failed += 1
				farmStats.last = ("พลาด %s: %s"):format(entry.name, tostring(reply.info or reply.status))
			end
			task.wait(Settings.perEggDelay)
		end
		if basketCount() > 0 then
			depositAtHome()
		end
		if not Settings.autoRepeat then
			break
		end
		task.wait(Settings.repeatDelay)
	end
	farming = false
end

local function startFarm()
	if farming then return end
	if flyState.on then flyStop(true) end
	farming = true
	task.spawn(farmLoop)
end

local function stopFarm()
	farming = false
end

--═══════════════ ฟักไข่ที่พร้อม ═══════════════
local function autoHatch()
	local plot = getPlot()
	local nests = plot and plot:FindFirstChild("Nests")
	if not nests then return 0, "ไม่พบรัง" end
	local done = 0
	for _, nest in ipairs(nests:GetChildren()) do
		for _, egg in ipairs(nest:GetDescendants()) do
			if egg:IsA("ProximityPrompt") and egg.Name == "Hatch" and egg.Enabled then
				local holder = egg.Parent
				local pos = holder and holder:IsA("BasePart") and holder.Position
				if pos then
					teleportTo(CFrame.new(pos + Vector3.new(0, 4, 0)))
					task.wait(1.0)
					local cam = Workspace.CurrentCamera
					if cam then
						cam.CFrame = CFrame.lookAt(pos + Vector3.new(0, 6, 8), pos)
					end
					task.wait(0.3)
					pcall(function()
						fireproximityprompt(egg)
					end)
					task.wait(0.8)
					done += 1
					break
				end
			end
		end
	end
	return done
end

--═══════════════ UI (WindUI) ═══════════════
local Window
do
	local ok, WindUI = pcall(function()
		return loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
	end)
	if ok and WindUI then
		WindUILib = WindUI
		local created, win = pcall(function()
			return WindUI:CreateWindow({
				Title = "Ride A Pet Hub",
				Icon = "egg",
				Author = "ฟาร์มไข่ • บิน • ESP",
				Folder = "RideAPetHub",
				Size = UDim2.fromOffset(560, 480),
				Theme = "Dark",
				Resizable = true,
				ToggleKey = Enum.KeyCode.RightShift,
				OpenButton = {
					Title = "เปิดเมนู RideHub",
					Icon = "egg",
					CornerRadius = UDim.new(0, 16),
					StrokeThickness = 2,
					Color = ColorSequence.new(
						Color3.fromHex("FF0F7B"),
						Color3.fromHex("F89B29")
					),
					OnlyMobile = false,
					Enabled = true,
					Draggable = true,
				},
			})
		end)
		if created then
			Window = win
			local TabMain = Window:Tab({ Title = "หน้าหลัก", Icon = "home" })
			local TabFarm = Window:Tab({ Title = "ฟาร์มไข่", Icon = "egg" })
			local TabEsp = Window:Tab({ Title = "ESP ไข่", Icon = "eye" })
			local TabMove = Window:Tab({ Title = "การเคลื่อนที่", Icon = "feather" })
			local TabOther = Window:Tab({ Title = "อื่น ๆ", Icon = "settings" })

			statusPara = TabMain:Paragraph({
				Title = "📊 สถานะ",
				Desc = "กำลังโหลด...",
			})
			TabMain:Button({
				Title = "▶ เริ่มฟาร์มไข่",
				Desc = "เก็บไข่ → วาบกลับบ้านฝาก → วนต่อ",
				Icon = "play",
				Callback = startFarm,
			})
			TabMain:Button({
				Title = "⏹ หยุดฟาร์ม",
				Icon = "square",
				Callback = stopFarm,
			})
			TabMain:Button({
				Title = "🏠 วาบกลับบ้าน",
				Icon = "house",
				Callback = function()
					local cf = getHomeCF()
					if cf then
						teleportTo(cf)
						notifyUI("กลับบ้านแล้ว")
					else
						notifyUI("ไม่พบบ้านของคุณ")
					end
				end,
			})
			TabMain:Button({
				Title = "🐣 ฟักไข่ทุกรังที่พร้อม",
				Desc = "ไปที่รังที่ไข่โตแล้วและกดฟักให้",
				Icon = "egg",
				Callback = function()
					task.spawn(function()
						local n, msg = autoHatch()
						notifyUI(("ฟักไป %d รัง %s"):format(n, msg or ""))
					end)
				end,
			})

			TabFarm:Dropdown({
				Title = "ระดับไข่ที่จะเก็บ",
				Desc = "ไม่เลือกอะไรเลย = เก็บทุกระดับ",
				Values = RARITY_LIST,
				Multi = true,
				AllowNone = true,
				Callback = function(selected)
					for _, r in ipairs(RARITY_LIST) do
						Settings.rarities[r] = false
					end
					if type(selected) == "table" then
						for _, r in ipairs(selected) do
							Settings.rarities[r] = true
						end
					elseif type(selected) == "string" then
						Settings.rarities[selected] = true
					end
				end,
			})
			TabFarm:Dropdown({
				Title = "ลำดับการเก็บ",
				Values = { "หายากสุดก่อน", "ใกล้สุดก่อน" },
				Callback = function(sel)
					Settings.rarestFirst = (sel == "หายากสุดก่อน")
				end,
			})
			TabFarm:Slider({
				Title = "เวลารอหลังวาบ (วินาที)",
				Desc = "รอเซิร์ฟยอมรับตำแหน่ง — ต่ำไปอาจเก็บไม่ได้",
				Value = { Min = 0.5, Max = 3, Default = 1.2 },
				Step = 0.1,
				Callback = function(v) Settings.settleDelay = v end,
			})
			TabFarm:Slider({
				Title = "หน่วงต่อฟอง (วินาที)",
				Value = { Min = 0.1, Max = 1, Default = 0.3 },
				Step = 0.05,
				Callback = function(v) Settings.perEggDelay = v end,
			})
			TabFarm:Slider({
				Title = "เก็บกี่ฟองต่อการกลับบ้าน",
				Desc = "1 = ปลอดภัยสุด (ไข่หมดเวลาเร็ว)",
				Value = { Min = 1, Max = 5, Default = 1 },
				Step = 1,
				Callback = function(v) Settings.eggsPerTrip = v end,
			})
			TabFarm:Toggle({
				Title = "วนฟาร์มอัตโนมัติ",
				Desc = "เก็บจนหมดแล้วรอแล้วเก็บใหม่",
				Value = false,
				Callback = function(v) Settings.autoRepeat = v end,
			})
			TabFarm:Slider({
				Title = "หน่วงเวลาวนซ้ำ (วินาที)",
				Value = { Min = 3, Max = 120, Default = 10 },
				Step = 1,
				Callback = function(v) Settings.repeatDelay = v end,
			})
			TabFarm:Toggle({
				Title = "หยุดฟาร์มถ้ารังเต็ม",
				Desc = "กันไข่ที่เก็บมาแตกเพราะฝากไม่ได้",
				Value = true,
				Callback = function(v) Settings.stopWhenNoNest = v end,
			})

			TabEsp:Toggle({
				Title = "เปิด ESP ไข่",
				Desc = "เห็นไข่ทะลุกำแพง พร้อมสีตามระดับ",
				Value = false,
				Callback = function(v) setEsp(v) end,
			})
			TabEsp:Toggle({
				Title = "แสดงระยะทาง",
				Value = true,
				Callback = function(v) Settings.espDistance = v end,
			})

			local flyToggleObj = TabMove:Toggle({
				Title = "บิน (หรือกด F)",
				Value = false,
				Callback = function(v)
					if v ~= flyState.on then flyToggle(true) end
				end,
			})
			flyOnChanged = function(on)
				pcall(function() flyToggleObj:Set(on) end)
			end
			TabMove:Slider({
				Title = "ความเร็วบิน",
				Value = { Min = 10, Max = 500, Default = 60 },
				Step = 10,
				Callback = function(v) Settings.flySpeed = v end,
			})
			TabMove:Toggle({
				Title = "ล็อกเดินเร็ว",
				Value = false,
				Callback = function(v)
					Settings.walkLock = v
					if not v then
						local hum = getHumanoid()
						if hum then hum.WalkSpeed = 16 end
					end
				end,
			})
			TabMove:Slider({
				Title = "ความเร็วเดิน",
				Value = { Min = 16, Max = 300, Default = 16 },
				Step = 2,
				Callback = function(v) Settings.walkSpeed = v end,
			})
			TabMove:Toggle({
				Title = "ล็อกกระโดดสูง",
				Value = false,
				Callback = function(v)
					Settings.jumpLock = v
					if not v then
						local hum = getHumanoid()
						if hum then hum.JumpPower = 50 end
					end
				end,
			})
			TabMove:Slider({
				Title = "พลังกระโดด",
				Value = { Min = 50, Max = 500, Default = 50 },
				Step = 5,
				Callback = function(v) Settings.jumpPower = v end,
			})
			TabMove:Toggle({
				Title = "Noclip ทะลุกำแพง (หรือกด N)",
				Value = false,
				Callback = function(v) setNoclip(v, true) end,
			})

			TabOther:Toggle({
				Title = "Anti-AFK",
				Desc = "กันเกมเตะออกเพราะแอฟ",
				Value = false,
				Callback = setAntiAfk,
			})
			TabOther:Paragraph({
				Title = "🎮 ปุ่มลัด",
				Desc = "RightShift = เปิด/ปิดเมนู\nF = บิน • N = ทะลุกำแพง",
			})
			TabOther:Button({
				Title = "🗑 ปิดสคริปต์ทั้งหมด",
				Callback = function()
					pcall(shutdown)
				end,
			})
		else
			warn("[RideHub] สร้างหน้าต่าง WindUI ไม่สำเร็จ: " .. tostring(win))
		end
	else
		warn("[RideHub] โหลด WindUI ไม่สำเร็จ: " .. tostring(WindUI))
	end
end

--═══════════════ อัปเดตสถานะทุก 1 วิ ═══════════════
local statusAcc = 0
bind(RunService.Heartbeat, function(dt)
	statusAcc += dt
	if statusAcc < 1 then return end
	statusAcc = 0
	if Window and statusPara then
		local counts = {}
		local list = scanEggs()
		for _, e in ipairs(list) do
			counts[e.rarity] = (counts[e.rarity] or 0) + 1
		end
		local parts = {}
		for _, r in ipairs(RARITY_LIST) do
			if counts[r] then
				table.insert(parts, r:sub(1, 3) .. ":" .. counts[r])
			end
		end
		local desc = ("ไข่ในแมป: %d (%s)\nตะกร้า: %d • รังว่าง: %s")
			:format(#list, table.concat(parts, " "), basketCount(), hasFreeNest() and "มี" or "ไม่มี!")
		desc = desc .. ("\nสถานะ: %s • เก็บแล้ว %d พลาด %d\nล่าสุด: %s"):format(
			farming and "กำลังฟาร์ม..." or "พร้อม",
			farmStats.collected, farmStats.failed, farmStats.last)
		pcall(function() statusPara:SetDesc(desc) end)
	end
end)

--═══════════════ notifyUI / SHUTDOWN / API ═══════════════
notifyUI = function(text)
	pcall(function()
		if WindUILib then
			WindUILib:Notify({ Title = "RideHub", Content = text, Duration = 2.5, Icon = "info" })
		else
			StarterGui:SetCore("SendNotification", { Title = "RideHub", Text = text, Duration = 2.5 })
		end
	end)
end

shutdown = function()
	version += 1
	farming = false
	flyStop(true)
	setNoclip(false, true)
	setEsp(false)
	setAntiAfk(false)
	Settings.walkLock = false
	Settings.jumpLock = false
	local hum = getHumanoid()
	if hum then
		hum.WalkSpeed = 16
		hum.JumpPower = 50
	end
	for _, conn in ipairs(connections) do
		conn:Disconnect()
	end
	table.clear(connections)
	if Window then pcall(function() Window:Destroy() end) end
end

getgenv().__RideHubHandle = { shutdown = shutdown }
getgenv().RideHub = {
	startFarm = startFarm,
	stopFarm = stopFarm,
	isFarming = function() return farming end,
	teleportHome = function()
		local cf = getHomeCF()
		if cf then teleportTo(cf) end
	end,
	setEsp = setEsp,
	autoHatch = autoHatch,
	fly = {
		toggle = flyToggle,
		start = flyStart,
		stop = function() flyStop() end,
		setSpeed = function(v) Settings.flySpeed = v end,
	},
	settings = Settings,
	shutdown = shutdown,
}

print("[RideHub] โหลดแล้ว — RightShift เปิดเมนู | F บิน | N noclip")
