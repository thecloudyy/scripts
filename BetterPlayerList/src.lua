-- BetterPlayerList / src.lua

local function getEnvTable()
	local ok, res = pcall(function()
		local f = rawget(_G, "getgenv")
		if type(f) == "function" then
			return f()
		end
		return _G
	end)
	if ok and type(res) == "table" then
		return res
	end
	return _G
end

local function getConfig(key, fallback)
	local gv = getEnvTable()
	if gv and gv[key] ~= nil then
		return gv[key]
	end
	return fallback
end

local CONFIG = {
	BackgroundImg = getConfig("BACKGROUND_IMG", ""),
	SelfNameColor = getConfig("SELFNAME_COLOR", Color3.fromRGB(255, 170, 0)),
	SelfImagePlate = getConfig("SELF_IMAGEPLATE", ""),
	SelfFont = getConfig("SELF_FONT", Font.new("rbxassetid://12187365364", Enum.FontWeight.Medium, Enum.FontStyle.Normal)),
}

local CoreGui = game:GetService("CoreGui")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local PlayerListGui = CoreGui:WaitForChild("PlayerList")

local TeamsList = nil
local teamsConn = nil
local dropdownConn = nil
local spectateConn = nil

local pendingTarget = nil
local spectatingUserId = nil

local function makeGradient()
	local g = Instance.new("UIGradient")
	g.Rotation = -90
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(157, 157, 157)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
	})
	return g
end

local function tryCopy(text)
	local envTbl = getEnvTable()
	local copyFn = envTbl and envTbl.setclipboard
	if type(copyFn) ~= "function" then
		copyFn = rawget(_G, "setclipboard")
	end
	if type(copyFn) == "function" then
		local ok = pcall(copyFn, text)
		return ok
	end
	return false
end

local function disconnectConn(conn)
	if conn then
		pcall(function()
			conn:Disconnect()
		end)
	end
end

local function unspectate(icon)
	spectatingUserId = nil
	disconnectConn(spectateConn)
	spectateConn = nil
	local cam = workspace.CurrentCamera
	if cam then
		cam.CameraType = Enum.CameraType.Custom
		local myChar = LocalPlayer.Character
		local myHum = myChar and myChar:FindFirstChildOfClass("Humanoid")
		if myHum then
			cam.CameraSubject = myHum
		end
	end
	if icon then
		icon.Text = "eye"
	end
end

local function makeCopyable(label)
	if not label:GetAttribute("BPL_Copyable") then
		label:SetAttribute("BPL_Copyable", true)
		label.Active = true
		label.MouseEnter:Connect(function()
			label:SetAttribute("BPL_Hovering", true)
			label.Text = "Click to copy."
		end)
		label.MouseLeave:Connect(function()
			label:SetAttribute("BPL_Hovering", false)
			local real = label:GetAttribute("RealText")
			label.Text = real or label.Text
		end)
		label.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				local real = label:GetAttribute("RealText") or label.Text
				if tryCopy(tostring(real)) then
					label.Text = "Copied!"
				else
					label.Text = tostring(real)
				end
				task.delay(0.8, function()
					if not label:IsDescendantOf(game) then
						return
					end
					if not label:GetAttribute("BPL_Hovering") then
						local r2 = label:GetAttribute("RealText")
						label.Text = r2 or label.Text
					end
				end)
			end
		end)
	end
end

local function styleButton(btn)
	btn.MouseEnter:Connect(function()
		local hover = btn:FindFirstChild("HoverBackground")
		if hover and hover:IsA("GuiObject") then
			hover.BackgroundTransparency = 0.92
		end
	end)
	btn.MouseLeave:Connect(function()
		local hover = btn:FindFirstChild("HoverBackground")
		if hover and hover:IsA("GuiObject") then
			hover.BackgroundTransparency = 1
		end
	end)
end

local function setupPlayerDropdown(inner, isLocal, userId)
	if not inner or not inner:IsDescendantOf(game) then
		return
	end

	local listLayout = inner:WaitForChild("UIListLayout", 3)
	if listLayout and listLayout:IsA("UIListLayout") then
		listLayout.Wraps = true
		listLayout.FillDirection = Enum.FillDirection.Horizontal
	end

	local pad = 8
	pcall(function()
		if listLayout and listLayout.Padding then
			pad = listLayout.Padding.Offset
			if pad == 0 then
				pad = 8
			end
		end
	end)

	for _, v in ipairs(inner:GetChildren()) do
		if v:IsA("GuiObject") and string.find(v.Name, "Button") then
			v.Size = UDim2.new(0.5, -pad / 2, v.Size.Y.Scale, v.Size.Y.Offset)
		end
	end

	local inspectBtn = inner:FindFirstChild("InspectButton")
	if not inspectBtn or not inspectBtn:IsA("GuiButton") then
		return
	end

	if not inner:FindFirstChild("GoToButton") then
		local goBtn = inspectBtn:Clone()
		goBtn.Name = "GoToButton"
		local hover = goBtn:FindFirstChild("HoverBackground")
		if hover then
			for _, d in ipairs(hover:GetDescendants()) do
				if d:IsA("TextLabel") and d.Name == "Text" then
					d.Text = "GoTo"
				elseif d:IsA("TextLabel") and d.Name == "Icon" then
					d.Text = "double-chevron-large-right"
				end
			end
		end
		goBtn.Size = UDim2.new(0.5, -pad / 2, goBtn.Size.Y.Scale, goBtn.Size.Y.Offset)
		goBtn.Parent = inner
		styleButton(goBtn)
		goBtn.MouseButton1Click:Connect(function()
			local target = pendingTarget
			local id
			if target and target.userId then
				id = target.userId
			else
				id = userId
			end
			local plr = Players:GetPlayerByUserId(id)
			local myChar = LocalPlayer.Character
			if plr and plr.Character and myChar then
				pcall(function()
					myChar:PivotTo(plr.Character:GetPivot())
				end)
			end
		end)
	end

	if not inner:FindFirstChild("SpectateButton") then
		local specBtn = inspectBtn:Clone()
		specBtn.Name = "SpectateButton"
		local hover = specBtn:FindFirstChild("HoverBackground")
		local icon = nil
		if hover then
			for _, d in ipairs(hover:GetDescendants()) do
				if d:IsA("TextLabel") and d.Name == "Text" then
					d.Text = "Spectate"
				elseif d:IsA("TextLabel") and d.Name == "Icon" then
					d.Text = "eye"
					icon = d
				end
			end
		end
		specBtn.Size = UDim2.new(0.5, -pad / 2, specBtn.Size.Y.Scale, specBtn.Size.Y.Offset)
		specBtn.Parent = inner
		styleButton(specBtn)
		specBtn.MouseButton1Click:Connect(function()
			local target = pendingTarget
			local id
			if target and target.userId then
				id = target.userId
			else
				id = userId
			end
			local cam = workspace.CurrentCamera
			if not cam then
				return
			end
			local iconLabel = icon
			if not iconLabel and hover then
				for _, d in ipairs(hover:GetDescendants()) do
					if d:IsA("TextLabel") and d.Name == "Icon" then
						iconLabel = d
						break
					end
				end
			end

			if spectatingUserId == id then
				unspectate(iconLabel)
				return
			end
			if spectatingUserId then
				unspectate(nil)
			end

			local plr = Players:GetPlayerByUserId(id)
			local hum = plr and plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
			if not hum then
				return
			end
			spectatingUserId = id
			cam.CameraSubject = hum
			cam.CameraType = Enum.CameraType.Custom
			if iconLabel then
				iconLabel.Text = "eye-slash"
			end
			disconnectConn(spectateConn)
			spectateConn = hum.Died:Connect(function()
				unspectate(iconLabel)
			end)
		end)
	end

	if not isLocal then
		local reportBtn = inner:FindFirstChild("ReportButton")
		if reportBtn then
			local hover = reportBtn:FindFirstChild("HoverBackground")
			local t = hover and hover:FindFirstChild("Text")
			if t and t:IsA("TextLabel") then
				t.Text = "Report"
			end
		end
		local friendBtn = inner:FindFirstChild("FriendButton")
		if friendBtn then
			local container = friendBtn:FindFirstChild("CurrentButtonContainer")
			local dropBtn = container and container:FindFirstChild("DropDownButton")
			local hover2 = dropBtn and dropBtn:FindFirstChild("HoverBackground")
			local t2 = hover2 and hover2:FindFirstChild("Text")
			if t2 and t2:IsA("TextLabel") then
				t2.Text = "Friend"
			end
		end
	end

	local inspectHover = inspectBtn:FindFirstChild("HoverBackground")
	if inspectHover then
		local t = inspectHover:FindFirstChild("Text")
		if t and t:IsA("TextLabel") then
			t.Text = "Examine"
		end
	end

	local header = inner:FindFirstChild("PlayerHeader")
	local headerBg = header and header:FindFirstChild("Background")
	if headerBg and headerBg:IsA("GuiObject") then
		if CONFIG.BackgroundImg ~= "" then
			pcall(function()
				headerBg.Image = CONFIG.BackgroundImg
				headerBg.ImageTransparency = 0.1
			end)
		end
		if not headerBg:FindFirstChildOfClass("UICorner") then
			local corner = Instance.new("UICorner")
			corner.BottomRightRadius = UDim.new(0, 0)
			corner.BottomLeftRadius = UDim.new(0, 0)
			corner.Parent = headerBg
		end
	end

	local avatar = header and header:FindFirstChild("AvatarImage")
	if avatar and avatar:IsA("GuiObject") then
		avatar.AnchorPoint = Vector2.new(0, 1)
		avatar.Position = UDim2.new(0, 0, 1, 0)
	end
	local textFrame = headerBg and headerBg:FindFirstChild("TextContainerFrame")
	if textFrame and textFrame:IsA("GuiObject") then
		textFrame.Position = UDim2.new(0.3, 0, 0, 0)
		local playerName = textFrame:FindFirstChild("PlayerName")
		local displayName = textFrame:FindFirstChild("DisplayName")
		if not inner:GetAttribute("BPL_Shrunk") then
			if playerName and playerName:IsA("GuiObject") then
				playerName.Size = playerName.Size - UDim2.new(0, 0, 0, 6)
			end
			if displayName and displayName:IsA("GuiObject") then
				displayName.Size = displayName.Size - UDim2.new(0, 0, 0, 2)
			end
			inner:SetAttribute("BPL_Shrunk", true)
		end
		if not textFrame:FindFirstChild("UserId") and playerName then
			local uid = playerName:Clone()
			uid.Name = "UserId"
			uid.Parent = textFrame
		end

		local targetPlr = nil
		pcall(function()
			targetPlr = Players:GetPlayerByUserId(userId)
		end)
		local realName = tostring(userId)
		if targetPlr and targetPlr.Name then
			realName = targetPlr.Name
		elseif playerName and playerName:IsA("TextLabel") then
			realName = playerName.Text
		end
		local uidLabel = textFrame:FindFirstChild("UserId")
		if uidLabel and uidLabel:IsA("TextLabel") then
			uidLabel:SetAttribute("RealText", tostring(userId))
			if not uidLabel:GetAttribute("BPL_Hovering") then
				uidLabel.Text = tostring(userId)
			end
			makeCopyable(uidLabel)
		end
		if playerName and playerName:IsA("TextLabel") then
			playerName:SetAttribute("RealText", realName)
			playerName.Text = realName
			makeCopyable(playerName)
		end
	end
end

local function openDropdownFor(isLocal, userId, root)
	pendingTarget = { isLocal = isLocal, userId = userId }
	task.spawn(function()
		local dd = root:WaitForChild("PlayerDropDown", 5)
		if not dd then
			return
		end
		local current = pendingTarget
		if not current or current.userId ~= userId then
			return
		end
		local inner = dd:WaitForChild("InnerFrame", 5)
		if inner and inner:IsA("Frame") then
			setupPlayerDropdown(inner, current.isLocal, current.userId)
		end
	end)
end

local function wireEntry(entry)
	if not string.find(entry.Name, "PlayerEntry") then
		return
	end
	if entry:GetAttribute("BPL_Wired") then
		return
	end
	entry:SetAttribute("BPL_Wired", true)

	local content = entry:WaitForChild("PlayerEntryContentFrame", 5)
	if not content then
		return
	end

	local function applySelfStyle()
		local id = tonumber(string.match(entry.Name, "^PlayerEntry_(%d+)$"))
		if not id or id ~= LocalPlayer.UserId then
			return
		end
		local overlay = content:FindFirstChild("OverlayFrame")
		local nameFrame = overlay and overlay:FindFirstChild("NameFrame")
		if not nameFrame then
			return
		end
		local icon = nameFrame:FindFirstChild("PlayerIcon")
		local nameHolder = nameFrame:FindFirstChild("PlayerName")
		local nameLabel = nameHolder and nameHolder:FindFirstChild("PlayerName")
		if icon and icon:IsA("TextLabel") then
			icon.TextColor3 = CONFIG.SelfNameColor
			if not icon:FindFirstChildOfClass("UIGradient") then
				local g1 = makeGradient()
				g1.Parent = icon
			end
		end
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.TextColor3 = CONFIG.SelfNameColor
			pcall(function()
				nameLabel.FontFace = CONFIG.SelfFont
			end)
			if not nameLabel:FindFirstChildOfClass("UIGradient") then
				local g2 = makeGradient()
				g2.Parent = nameLabel
			end
		end
		if CONFIG.SelfImagePlate ~= "" and not content:FindFirstChild("CustomOverlay") then
			local overlayImg = Instance.new("ImageLabel")
			overlayImg.Name = "CustomOverlay"
			overlayImg.ScaleType = Enum.ScaleType.Crop
			overlayImg.BorderSizePixel = 0
			overlayImg.BackgroundTransparency = 1
			overlayImg.Size = UDim2.new(1, 0, 1, 0)
			overlayImg.Image = CONFIG.SelfImagePlate
			overlayImg.Parent = content
		end
	end
	applySelfStyle()

	if content:IsA("GuiButton") then
		content.MouseButton1Click:Connect(function()
			local id = tonumber(string.match(entry.Name, "^PlayerEntry_(%d+)$"))
			if not id then
				return
			end
			local isLocal = (id == LocalPlayer.UserId)
			local root = PlayerListGui:FindFirstChild("Children")
			if root then
				openDropdownFor(isLocal, id, root)
			end
		end)
	end
end

local function getTeamsList(root)
	-- New Roblox PlayerList hierarchy changes often; try the old deep path
	-- first, then fall back to a recursive search. Never throws.
	local found = nil
	pcall(function()
		found = root:FindFirstChild("OffsetUndoFrame", true)
	end)
	if found then
		return found
	end
	pcall(function()
		local a = root:WaitForChild("OffsetFrame", 5)
		local b = a:WaitForChild("PlayerScrollList", 5)
		local c = b:WaitForChild("SizeOffsetFrame", 5)
		local d = c:WaitForChild("ScrollingFrameContainer", 5)
		local e = d:WaitForChild("ScrollingFrameClippingFrame", 5)
		local f = e:WaitForChild("ScrollingFrame", 5)
		local g = f:WaitForChild("OffsetUndoFrame", 5)
		found = g
	end)
	return found
end

local function bindChildrenContainer(children)
	disconnectConn(teamsConn)
	teamsConn = nil
	disconnectConn(dropdownConn)
	dropdownConn = nil

	-- Wire everything found right now (no dependency on exact hierarchy).
	pcall(function()
		for _, entry in ipairs(children:GetDescendants()) do
			if type(entry.Name) == "string" and string.find(entry.Name, "PlayerEntry") then
				task.spawn(wireEntry, entry)
			end
		end
	end)

	TeamsList = getTeamsList(children)
	if TeamsList then
		local ok = pcall(function()
			for _, teamFrame in ipairs(TeamsList:GetChildren()) do
				if teamFrame:IsA("Frame") then
					for _, entry in ipairs(teamFrame:GetChildren()) do
						task.spawn(wireEntry, entry)
					end
				end
			end
		end)
		if not ok then
			TeamsList = nil
		end
	end
	if TeamsList then
		pcall(function()
			teamsConn = TeamsList.DescendantAdded:Connect(function(d)
				task.spawn(wireEntry, d)
			end)
		end)
	end

	-- Always watch the whole subtree so path changes can't break wiring.
	pcall(function()
		teamsConn = children.DescendantAdded:Connect(function(d)
			task.spawn(wireEntry, d)
		end)
	end)

	dropdownConn = children.DescendantAdded:Connect(function(d)
		if d.Name == "PlayerDropDown" then
			task.spawn(function()
				local inner = d:WaitForChild("InnerFrame", 5)
				local current = pendingTarget
				if inner and inner:IsA("Frame") and current then
					setupPlayerDropdown(inner, current.isLocal, current.userId)
				end
			end)
		end
	end)
end

local existing = PlayerListGui:FindFirstChild("Children")
if existing then
	bindChildrenContainer(existing)
end
PlayerListGui.ChildAdded:Connect(function(c)
	if c.Name == "Children" then
		bindChildrenContainer(c)
	end
end)

LocalPlayer.CharacterAdded:Connect(function()
	if spectatingUserId then
		spectatingUserId = nil
		disconnectConn(spectateConn)
		spectateConn = nil
	end
end)
