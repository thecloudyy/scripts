-- BetterPlayerList / src.lua
-- Fixed version of the PlayerList customization script.
--
-- Fixes applied:
-- 1. Defines missing globals (BACKGROUND_IMG, SELFNAME_COLOR, SELF_IMAGEPLATE, SELF_FONT)
--    via CONFIG so the script no longer errors on first run. The old
--    loadstring(game:HttpGet(...)) returned `true` and defined nothing.
-- 2. Handles "Children" already existing before ChildAdded fires (race fix).
-- 3. Disconnects old TeamsList / dropdown connections when the list rebuilds
--    (fixes connection leaks).
-- 4. wireEntry no longer captures a stale userId in a closure. The click
--    handler re-parses entry.Name live, so recycled PlayerEntry frames still
--    open the right player.
-- 5. Dropdown setup takes the InnerFrame directly + waits with a timeout
--    instead of `repeat task.wait() until PlayerDropdown` (which could hang).
-- 6. Spectate tracks spectatingUserId, restores camera correctly, resets the
--    eye/eye-slash icon, and auto-unspectates on respawn.
-- 7. GoTo wrapped in pcall; nil-guards for missing Character.
-- 8. setclipboard guarded (nil on normal clients, pcall on executors).
-- 9. UICorner / GoTo / Spectate buttons created once per dropdown instance
--    (instances are destroyed each open, so no cross-open leaks).
-- 10. FriendButton chain nil-guarded.
-- 11. Removed dead loadstring + profanity attribute names.

local CONFIG = {
	BackgroundImg = "", -- rbxassetid://... or "" to skip
	SelfNameColor = Color3.fromRGB(255, 170, 0),
	SelfImagePlate = "", -- rbxassetid://... or "" to skip custom overlay
	SelfFont = Font.new("rbxassetid://12187365364", Enum.FontWeight.Medium, Enum.FontStyle.Normal),
}

local CoreGui = game:GetService("CoreGui")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local PlayerListGui = CoreGui:WaitForChild("PlayerList")

local TeamsList: Frame?
local teamsConn: RBXScriptConnection?
local dropdownConn: RBXScriptConnection?
local spectateConn: RBXScriptConnection?

local pendingTarget: { isLocal: boolean, userId: number }? = nil
local spectatingUserId: number? = nil

local function makeGradient(): UIGradient
	local g = Instance.new("UIGradient")
	g.Rotation = -90
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(157, 157, 157)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
	})
	return g
end

local function tryCopy(text: string)
	local copyFn = rawget(getgenv and getgenv() or {}, "setclipboard") or (_G and rawget(_G, "setclipboard"))
	if typeof(copyFn) ~= "function" then
		local ok = pcall(function()
			return setclipboard :: any
		end)
		if not ok then
			return false
		end
	end
	local ok = pcall(function()
		(setclipboard :: any)(text)
	end)
	return ok
end

local function unspectate(icon: TextLabel?)
	spectatingUserId = nil
	if spectateConn then
		pcall(function()
			(spectateConn :: RBXScriptConnection):Disconnect()
		end)
		spectateConn = nil
	end
	local cam = workspace.CurrentCamera
	if cam then
		cam.CameraType = Enum.CameraType.Custom
		local myHum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
		if myHum then
			cam.CameraSubject = myHum
		end
	end
	if icon then
		icon.Text = "eye"
	end
end

local function makeCopyable(label: TextLabel)
	if not label:GetAttribute("BPL_Copyable") then
		label:SetAttribute("BPL_Copyable", true)
		label.Active = true
		label.MouseEnter:Connect(function()
			label:SetAttribute("BPL_Hovering", true)
			label.Text = "Click to copy."
		end)
		label.MouseLeave:Connect(function()
			label:SetAttribute("BPL_Hovering", false)
			label.Text = (label:GetAttribute("RealText") :: any) or label.Text
		end)
		label.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				local real = (label:GetAttribute("RealText") :: any) or label.Text
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
						label.Text = (label:GetAttribute("RealText") :: any) or label.Text
					end
				end)
			end
		end)
	end
end

local function styleButton(btn: GuiButton)
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

local function setupPlayerDropdown(inner: Frame, isLocal: boolean, userId: number)
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
		if listLayout and (listLayout :: UIListLayout).Padding then
			pad = (listLayout :: UIListLayout).Padding.Offset
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
			local t = hover:FindFirstChildOfClass("TextLabel")
			local ic = hover:FindFirstChildOfClass("TextLabel", true)
			if t then
				t.Text = "GoTo"
			end
			-- Keep it simple: set first two text descendants if structure differs
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
			local id = target and target.userId or userId
			local plr = Players:GetPlayerByUserId(id)
			local myChar = LocalPlayer.Character
			if plr and plr.Character and myChar then
				pcall(function()
					myChar:PivotTo((plr.Character :: Model):GetPivot())
				end)
			end
		end)
	end

	if not inner:FindFirstChild("SpectateButton") then
		local specBtn = inspectBtn:Clone()
		specBtn.Name = "SpectateButton"
		local hover = specBtn:FindFirstChild("HoverBackground")
		local icon: TextLabel? = nil
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
			local id = target and target.userId or userId
			local cam = workspace.CurrentCamera
			if not cam then
				return
			end
			local iconLabel: TextLabel? = icon
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
			-- switching targets: clear old state first
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
			if spectateConn then
				pcall(function()
					(spectateConn :: RBXScriptConnection):Disconnect()
				end)
			end
			spectateConn = (hum :: Humanoid).Died:Connect(function()
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
			local hover = dropBtn and dropBtn:FindFirstChild("HoverBackground")
			local t = hover and hover:FindFirstChild("Text")
			if t and t:IsA("TextLabel") then
				t.Text = "Friend"
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
				(headerBg :: GuiObject & { Image: string }).Image = CONFIG.BackgroundImg
				(headerBg :: ImageLabel).ImageTransparency = 0.1
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
				playerName.Size -= UDim2.new(0, 0, 0, 6)
			end
			if displayName and displayName:IsA("GuiObject") then
				displayName.Size -= UDim2.new(0, 0, 0, 2)
			end
			inner:SetAttribute("BPL_Shrunk", true)
		end
		if not textFrame:FindFirstChild("UserId") and playerName then
			local uid = playerName:Clone()
			uid.Name = "UserId"
			uid.Parent = textFrame
		end

		local targetPlr = Players:GetPlayerByUserId(userId)
		local realName = targetPlr and targetPlr.Name or ((playerName and (playerName :: TextLabel).Text) or tostring(userId))
		local uidLabel = textFrame:FindFirstChild("UserId")
		if uidLabel and uidLabel:IsA("TextLabel") then
			uidLabel:SetAttribute("RealText", tostring(userId))
			if not uidLabel:GetAttribute("BPL_Hovering") then
				uidLabel.Text = tostring(userId)
			end
			makeCopyable(uidLabel)
		end
		if playerName and playerName:IsA("TextLabel") then
			playerName:SetAttribute("RealText", realName);
			(playerName :: TextLabel).Text = realName
			makeCopyable(playerName :: TextLabel)
		end
	end
end

local function openDropdownFor(isLocal: boolean, userId: number, root: Instance)
	pendingTarget = { isLocal = isLocal, userId = userId }
	task.spawn(function()
		local dd = root:WaitForChild("PlayerDropDown", 5)
		if not dd then
			return
		end
		-- make sure this dropdown belongs to the latest click
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

local function wireEntry(entry: Instance)
	if not string.find(entry.Name, "PlayerEntry") then
		return
	end
	-- single-wire guard; click handler reads entry.Name live so recycled
	-- frames still resolve to the correct player
	if entry:GetAttribute("BPL_Wired") then
		return
	end
	entry:SetAttribute("BPL_Wired", true)

	local content = entry:WaitForChild("PlayerEntryContentFrame", 5)
	if not content then
		return
	end

	-- self highlight (reads live Name so recycling is safe)
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
				makeGradient().Parent = icon
			end
		end
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.TextColor3 = CONFIG.SelfNameColor
			pcall(function()
				(nameLabel :: TextLabel).FontFace = CONFIG.SelfFont
			end)
			if not nameLabel:FindFirstChildOfClass("UIGradient") then
				makeGradient().Parent = nameLabel
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

local function getTeamsList(root: Instance): Frame?
	local ok, res = pcall(function()
		return (((((root:WaitForChild("OffsetFrame", 5):WaitForChild("PlayerScrollList", 5):WaitForChild("SizeOffsetFrame", 5):WaitForChild("ScrollingFrameContainer", 5):WaitForChild("ScrollingFrameClippingFrame", 5):WaitForChild("ScrollingFrame", 5):WaitForChild("OffsetUndoFrame", 5)) :: Instance) :: Frame)
	end)
	if ok then
		return res :: Frame
	end
	return nil
end

local function bindChildrenContainer(children: Instance)
	if teamsConn then
		pcall(function()
			(teamsConn :: RBXScriptConnection):Disconnect()
		end)
		teamsConn = nil
	end
	if dropdownConn then
		pcall(function()
			(dropdownConn :: RBXScriptConnection):Disconnect()
		end)
		dropdownConn = nil
	end

	TeamsList = getTeamsList(children)
	if TeamsList then
		for _, teamFrame in ipairs((TeamsList :: Frame):GetChildren()) do
			if teamFrame:IsA("Frame") then
				for _, entry in ipairs(teamFrame:GetChildren()) do
					task.spawn(wireEntry, entry)
				end
			end
		end
		teamsConn = (TeamsList :: Frame).DescendantAdded:Connect(function(d)
			task.spawn(wireEntry, d)
		end)
	end

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

-- init: handle already-present Children + future rebuilds
local existing = PlayerListGui:FindFirstChild("Children")
if existing then
	bindChildrenContainer(existing)
end
PlayerListGui.ChildAdded:Connect(function(c)
	if c.Name == "Children" then
		bindChildrenContainer(c)
	end
end)

-- reset spectate state when we respawn
LocalPlayer.CharacterAdded:Connect(function()
	if spectatingUserId then
		spectatingUserId = nil
		if spectateConn then
			pcall(function()
				(spectateConn :: RBXScriptConnection):Disconnect()
			end)
			spectateConn = nil
		end
	end
end)
