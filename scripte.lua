local Players = game:GetService("Players")
local lp = Players.LocalPlayer
local RunService = game:GetService("RunService")
local Camera = workspace.CurrentCamera
local UserInputService = game:GetService("UserInputService")

local function bootError(msg)
    warn("[Astraea Boot] " .. tostring(msg))
end

local function ensureWritableEnv()
    local env = getgenv and getgenv()
    if type(env) ~= "table" then return true end
    local function testWrite()
        env.__rw_test = true
        env.__rw_test = nil
    end
    if pcall(testWrite) then
        return true
    end
    pcall(function() if setreadonly then setreadonly(env, false) end end)
    pcall(function() if make_writeable then make_writeable(env) end end)
    if not pcall(testWrite) then
        bootError("getgenv is read-only on this executor; Rayfield cannot initialize.")
        return false
    end
    return true
end

if not ensureWritableEnv() then return end

local RayfieldURL = "https://sirius.menu/rayfield"
local rfSource
local ok, err = pcall(function()
    rfSource = game:HttpGet(RayfieldURL)
end)
if not ok or not rfSource then
    bootError("Failed to fetch Rayfield UI: " .. tostring(err))
    return
end

local rfLoader, compileErr = loadstring(rfSource)
if not rfLoader then
    bootError("Failed to compile Rayfield UI: " .. tostring(compileErr))
    return
end

local Rayfield = rfLoader()
if not Rayfield then
    bootError("Rayfield returned nil; source may be invalid or blocked")
    return
end

local Window = Rayfield:CreateWindow({
    Name = "Astraea Universal Hub",
    LoadingTitle = "Loading...",
    LoadingSubtitle = "Made by Astraea Team",
    ConfigurationSaving = { Enabled = false },
    KeySystem = false
})
local updateNotifyShown = false

local MainTab = Window:CreateTab("Main", 4483362458)
local AimbotTab = Window:CreateTab("Aimbot", 4483362458)
local SettingsTab = Window:CreateTab("Settings", 4483362458)
local ConsoleTab = Window:CreateTab("Console", 4483362458)
local InfoTab = Window:CreateTab("Info", 4483362458)
local UpdatesTab = Window:CreateTab("Updates", 4483362458)
local HighlightAddedConn, HighlightLoopConn
local ESPV1AddedConn, ESPV1RemovingConn, ESPV1LoopConn
local ESPV1CharConns = {}
local ESPV1TeamConns = {}

getgenv().ESP = {
    Enabled = false,
    AutoJoin = true,
    TeamColors = true,
    TeamCheck = true,
    Tracers = false,
    TracerThickness = 1,
    Box = false,
    BoxThickness = 2
}

getgenv().Aimbot = {
    Enabled = false,
    TeamCheck = true,
    VisibilityCheck = false,
    AimPart = "Head",
    MaxDistance = 1000, -- studs
    AimPower = 0.5,      -- 0..1, higher snaps harder
    SmoothDelay = 0.25,  -- seconds of dampening (higher = smoother/slower)
    FOVEnabled = false,
    FOVStick = true,     -- only aim at targets inside the FOV circle
    FOVRadius = 150,
    FOVOpacity = 0.35,
    FOVColor = Color3.fromRGB(80, 170, 255),
}

getgenv().ESPv1 = {
    Enabled = false,
    FillTransparency = 0.6,
    OutlineTransparency = 0,
    AlwaysOnTop = true,
    TeamColors = true,
}
local consoleLines = {}

local ConsoleLabel = ConsoleTab:CreateParagraph({
    Title = "Output",
    Content = ""
})

local function log(t)
    table.insert(consoleLines, os.date("[%H:%M:%S] ") .. t)
    if #consoleLines > 40 then table.remove(consoleLines, 1) end
    ConsoleLabel:Set({ Title = "Output", Content = table.concat(consoleLines, "\n") })
end

local function notifyUpdateOnce()
    if updateNotifyShown then return end
    updateNotifyShown = true
    Rayfield:Notify({
        Title = "Update v2 Patch",
        Content = "New update patch loaded.",
        Duration = 6,
    })
end

local function getColor(player, useTeamColors)
    local teamColorsEnabled = useTeamColors
    if teamColorsEnabled == nil then
        teamColorsEnabled = getgenv().ESP.TeamColors
    end

    if teamColorsEnabled and player.TeamColor then
        return player.TeamColor.Color
    end
    return Color3.fromRGB(80,170,255)
end

local function passesTeamCheck(player)
    if not getgenv().ESP.TeamCheck then return true end
    if not lp.Team or not player.Team then return true end
    return player.Team ~= lp.Team
end

local function getHumanoidIfAlive(character)
    local hum = character and character:FindFirstChildWhichIsA("Humanoid")
    if not hum then return nil end
    local state = hum:GetState()
    if hum.Health <= 0 or state == Enum.HumanoidStateType.Dead then
        return nil
    end
    return hum
end


-- =========================
-- TRACER ESP (Drawing API)
-- =========================

local TracerFolder = {} -- stores Drawing objects

local function createTracer(player)
    local line = Drawing.new("Line")
    line.Visible = false
    line.Color = Color3.new(1,1,1)
    line.Thickness = getgenv().ESP.TracerThickness or 1
    line.Transparency = 1
    TracerFolder[player] = line
    return line
end

local function removeTracer(player)
    if TracerFolder[player] then
        TracerFolder[player]:Remove()
        TracerFolder[player] = nil
    end
end

local function updateTracers()
    if not getgenv().ESP.Tracers then
        for _, line in pairs(TracerFolder) do
            line.Visible = false
        end
        return
    end

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp and player.Character then
            local hrp = player.Character:FindFirstChild("HumanoidRootPart")
            local hum = getHumanoidIfAlive(player.Character)

            if hrp and hum and passesTeamCheck(player) then
                local tracer = TracerFolder[player] or createTracer(player)

                local pos, onScreen = workspace.CurrentCamera:WorldToViewportPoint(hrp.Position)
                if onScreen then
                    tracer.Thickness = getgenv().ESP.TracerThickness or 1
                    tracer.From = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y)
                    tracer.To = Vector2.new(pos.X, pos.Y)
                    tracer.Visible = true
                else
                    tracer.Visible = false
                end
            else
                removeTracer(player)
            end
        end
    end
end

local TracerConn
local function setTracerLoop(on)
    if on and not TracerConn then
        TracerConn = RunService.RenderStepped:Connect(updateTracers)
        log("Tracer loop started")
    elseif not on and TracerConn then
        TracerConn:Disconnect()
        TracerConn = nil
        for _, line in pairs(TracerFolder) do
            line.Visible = false
        end
        log("Tracer loop stopped")
    end
end

Players.PlayerRemoving:Connect(function(p)
    removeTracer(p)
end)

-- =========================
-- SKELETON ESP (Drawing API)
-- =========================

local skeletonSegments = {
    {"Head", "UpperTorso"},
    {"UpperTorso", "LowerTorso"},
    {"LowerTorso", "RightUpperLeg"},
    {"LowerTorso", "LeftUpperLeg"},
    {"RightUpperLeg", "RightLowerLeg"},
    {"RightLowerLeg", "RightFoot"},
    {"LeftUpperLeg", "LeftLowerLeg"},
    {"LeftLowerLeg", "LeftFoot"},
    {"UpperTorso", "RightUpperArm"},
    {"UpperTorso", "LeftUpperArm"},
    {"RightUpperArm", "RightLowerArm"},
    {"RightLowerArm", "RightHand"},
    {"LeftUpperArm", "LeftLowerArm"},
    {"LeftLowerArm", "LeftHand"},
}

local SkeletonLines = {}
local SkeletonConn

local function getPart(character, name)
    return character and character:FindFirstChild(name)
end

local function getSkeletonLines(player)
    if not SkeletonLines[player] then
        SkeletonLines[player] = {}
        for i = 1, #skeletonSegments do
            local line = Drawing.new("Line")
            line.Thickness = 1.5
            line.Transparency = 1
            line.Color = Color3.fromRGB(255, 255, 255)
            line.Visible = false
            SkeletonLines[player][i] = line
        end
    end
    return SkeletonLines[player]
end

local function clearSkeleton(player)
    local lines = SkeletonLines[player]
    if lines then
        for _, line in ipairs(lines) do
            line:Remove()
        end
        SkeletonLines[player] = nil
    end
end

Players.PlayerRemoving:Connect(clearSkeleton)

local function updateSkeleton()
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp and passesTeamCheck(player) then
            local character = player.Character
            local lines = getSkeletonLines(player)

            if character then
                for index, pair in ipairs(skeletonSegments) do
                    local a = getPart(character, pair[1])
                    local b = getPart(character, pair[2])
                    local line = lines[index]

                    if a and b then
                        local aPos, aVis = Camera:WorldToViewportPoint(a.Position)
                        local bPos, bVis = Camera:WorldToViewportPoint(b.Position)

                        if aVis and bVis then
                            line.From = Vector2.new(aPos.X, aPos.Y)
                            line.To = Vector2.new(bPos.X, bPos.Y)
                            line.Color = getColor(player)
                            line.Visible = true
                        else
                            line.Visible = false
                        end
                    else
                        line.Visible = false
                    end
                end
            else
                for _, line in ipairs(lines) do
                    line.Visible = false
                end
            end
        else
            clearSkeleton(player)
        end
    end
end

local function setSkeleton(on)
    if on and not SkeletonConn then
        SkeletonConn = RunService.RenderStepped:Connect(updateSkeleton)
        log("Skeleton ESP loop started")
    elseif not on and SkeletonConn then
        SkeletonConn:Disconnect()
        SkeletonConn = nil
        for _, lines in pairs(SkeletonLines) do
            for _, line in ipairs(lines) do
                line.Visible = false
            end
        end
        log("Skeleton ESP loop stopped")
    end
end


-- =========================
-- BOX ESP (Drawing API)
-- =========================

local BoxObjects = {}
local BoxConn

local function getBox(player)
    if not BoxObjects[player] then
        local sq = Drawing.new("Square")
        sq.Thickness = getgenv().ESP.BoxThickness or 2
        sq.Filled = false
        sq.Color = Color3.fromRGB(255, 255, 255)
        sq.Visible = false
        BoxObjects[player] = sq
    end
    return BoxObjects[player]
end

-- =========================
-- AIMBOT (from aaami.lua)
-- =========================

local AimbotConn
local FOVConn
local visibilityParams = RaycastParams.new()
visibilityParams.FilterType = Enum.RaycastFilterType.Blacklist
visibilityParams.IgnoreWater = true

local FOVCircle

local function ensureFOVCircle()
    if FOVCircle then return FOVCircle end
    if not Drawing or not Drawing.new then
        log("FOV circle unavailable (Drawing API missing)")
        return nil
    end
    FOVCircle = Drawing.new("Circle")
    FOVCircle.Filled = false
    FOVCircle.NumSides = 64
    FOVCircle.Thickness = 2
    return FOVCircle
end

local function updateFOVCircle()
    local circle = ensureFOVCircle()
    if not circle then return end
    local cfg = getgenv().Aimbot
    local color = cfg.FOVColor or Color3.fromRGB(80, 170, 255)
    circle.Position = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    circle.Radius = cfg.FOVRadius or 150
    circle.Transparency = cfg.FOVOpacity or 0.35
    circle.Color = color
    circle.Visible = cfg.FOVEnabled
end

local function setFOVLoop(state)
    if state and not FOVConn then
        if not ensureFOVCircle() then
            getgenv().Aimbot.FOVEnabled = false
            return
        end
        FOVConn = RunService.RenderStepped:Connect(function()
            updateFOVCircle()
        end)
        log("Aimbot FOV circle loop started")
    elseif not state and FOVConn then
        FOVConn:Disconnect()
        FOVConn = nil
        if FOVCircle then FOVCircle.Visible = false end
        log("Aimbot FOV circle loop stopped")
    end
end

local function aimbotPassesTeam(player)
    if not getgenv().Aimbot.TeamCheck then
        return true
    end
    if not lp.Team or not player.Team then
        return true
    end
    return lp.Team ~= player.Team
end

local function isTargetVisible(part)
    -- Raycast twice: first pass ignores local character/camera, second pass ignores
    -- any non-blocking hit (transparent/non-collide) so we don't get stuck after an occlusion.
    if not part or not part.Parent then
        return false
    end

    local origin = Camera.CFrame.Position
    local direction = part.Position - origin
    local ignore = {lp.Character, Camera}

    local function cast(list)
        visibilityParams.FilterDescendantsInstances = list
        return workspace:Raycast(origin, direction, visibilityParams)
    end

    local result = cast(ignore)
    if not result or result.Instance:IsDescendantOf(part.Parent) then
        return true
    end

    if result.Instance.Transparency >= 0.8 or not result.Instance.CanCollide or not result.Instance.CanQuery then
        table.insert(ignore, result.Instance)
        local retry = cast(ignore)
        return (not retry) or retry.Instance:IsDescendantOf(part.Parent)
    end

    return false
end

local function getClosestPlayerToCursor(targetPartName, maxDistance)
    local nearestPart = nil
    local nearestDist = math.huge
    local nearestVisible = false
    local cursorPos = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    local maxDist = maxDistance or 400
    local fovRadius = getgenv().Aimbot.FOVRadius or 150
    local stickToFOV = getgenv().Aimbot.FOVEnabled and getgenv().Aimbot.FOVStick

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp and aimbotPassesTeam(player) then
            local char = player.Character
            local hum = getHumanoidIfAlive(char)
            if char and hum then
                local aimPart
                if targetPartName == "Head" then
                    aimPart = char:FindFirstChild("Head") -- lock to head when requested
                else
                    aimPart = char:FindFirstChild(targetPartName)
                end
                aimPart = aimPart or char:FindFirstChild("UpperTorso") or char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Head")
                if aimPart then
                    local worldDist = (aimPart.Position - Camera.CFrame.Position).Magnitude
                    if worldDist <= maxDist then
                        local visibleNow = (not getgenv().Aimbot.VisibilityCheck) or isTargetVisible(aimPart)
                        if visibleNow then
                            local screenPos, visible = Camera:WorldToViewportPoint(aimPart.Position)
                            if visible then
                                local screenDist = (Vector2.new(screenPos.X, screenPos.Y) - cursorPos).Magnitude
                                if (not stickToFOV or screenDist <= fovRadius) and screenDist < nearestDist then
                                    nearestDist = screenDist
                                    nearestPart = aimPart
                                    nearestVisible = visibleNow
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return nearestPart, nearestVisible
end

local function setAimbot(state)
    getgenv().Aimbot.Enabled = state
    if state then
        if not AimbotConn then
            AimbotConn = RunService.RenderStepped:Connect(function(dt)
                local ok, err = pcall(function()
                    local maxDist = getgenv().Aimbot.MaxDistance or 400
                    local part, partVisible = getClosestPlayerToCursor(getgenv().Aimbot.AimPart or "Head", maxDist)
                    if part and part.Parent and getHumanoidIfAlive(part.Parent) then
                        local desired = CFrame.new(Camera.CFrame.Position, part.Position)
                        local power = math.clamp(getgenv().Aimbot.AimPower or 0.5, 0, 1)
                        local smoothDelay = math.max(0.01, getgenv().Aimbot.SmoothDelay or 0)
                        local alpha
                        if (getgenv().Aimbot.VisibilityCheck and partVisible) or power >= 0.99 then
                            alpha = 1 -- full snap when visible or max power
                        else
                            alpha = math.clamp((power * dt) / smoothDelay, 0, 1)
                        end
                        Camera.CFrame = Camera.CFrame:Lerp(desired, alpha)
                    end
                end)
                if not ok then
                    log("Aimbot error: " .. tostring(err))
                end
            end)
            log("Aimbot loop started")
        end
    else
        if AimbotConn then
            AimbotConn:Disconnect()
            AimbotConn = nil
            log("Aimbot loop stopped")
        end
    end
end

local function removeBox(player)
    local sq = BoxObjects[player]
    if sq then
        sq:Remove()
        BoxObjects[player] = nil
    end
end

Players.PlayerRemoving:Connect(removeBox)

local function updateBoxes()
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= lp and passesTeamCheck(player) then
            local char = player.Character
            local hum = getHumanoidIfAlive(char)
            local root = char and char:FindFirstChild("HumanoidRootPart")
            local head = char and char:FindFirstChild("Head")

            if char and hum and root and head then
                local sq = getBox(player)
                local rootPos, onScreen = Camera:WorldToViewportPoint(root.Position)
                local headPos = Camera:WorldToViewportPoint(head.Position + Vector3.new(0, 0.5, 0))

                if onScreen then
                    local height = math.abs(headPos.Y - rootPos.Y) * 2
                    local width = height / 2

                    sq.Size = Vector2.new(width, height)
                    sq.Position = Vector2.new(rootPos.X - width / 2, rootPos.Y - height / 2)
                    sq.Color = getColor(player)
                    sq.Thickness = getgenv().ESP.BoxThickness or 2
                    sq.Visible = true
                else
                    sq.Visible = false
                end
            else
                removeBox(player)
            end
        else
            removeBox(player)
        end
    end
end

local function setBox(on)
    if on and not BoxConn then
        BoxConn = RunService.RenderStepped:Connect(updateBoxes)
        log("Box ESP loop started")
    elseif not on and BoxConn then
        BoxConn:Disconnect()
        BoxConn = nil
        for _, sq in pairs(BoxObjects) do
            sq.Visible = false
        end
        log("Box ESP loop stopped")
    end
end

-- =========================
-- ESP V1 (Highlight)
-- =========================

local function destroyESPv1(plr)
    local char = plr and plr.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local h = hrp and hrp:FindFirstChild("ESP_V1_Highlight")
    if h then h:Destroy() end
    if ESPV1CharConns[plr] then ESPV1CharConns[plr]:Disconnect() ESPV1CharConns[plr] = nil end
    if ESPV1TeamConns[plr] then ESPV1TeamConns[plr]:Disconnect() ESPV1TeamConns[plr] = nil end
end

local function ensureESPv1(plr)
    if not getgenv().ESPv1.Enabled or plr == lp or not passesTeamCheck(plr) then
        destroyESPv1(plr)
        return
    end

    local char = plr.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    local h = hrp:FindFirstChild("ESP_V1_Highlight")
    if not h then
        h = Instance.new("Highlight")
        h.Name = "ESP_V1_Highlight"
        h.Adornee = char
        h.Parent = hrp
    end

    h.FillTransparency = getgenv().ESPv1.FillTransparency or 0
    h.OutlineTransparency = getgenv().ESPv1.OutlineTransparency or 0
    h.OutlineColor = getColor(plr, getgenv().ESPv1.TeamColors)
    h.DepthMode = getgenv().ESPv1.AlwaysOnTop and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded
end

local function setESPv1(state)
    getgenv().ESPv1.Enabled = state

    if state then
        local function hookPlayer(plr)
            if ESPV1CharConns[plr] then ESPV1CharConns[plr]:Disconnect() end
            ESPV1CharConns[plr] = plr.CharacterAdded:Connect(function()
                ensureESPv1(plr)
            end)

            if ESPV1TeamConns[plr] then ESPV1TeamConns[plr]:Disconnect() end
            ESPV1TeamConns[plr] = plr:GetPropertyChangedSignal("Team"):Connect(function()
                ensureESPv1(plr)
            end)

            ensureESPv1(plr)
        end

        for _, plr in ipairs(Players:GetPlayers()) do
            hookPlayer(plr)
        end
        log("ESP V1 loop started")

        if not ESPV1AddedConn then
            ESPV1AddedConn = Players.PlayerAdded:Connect(function(plr)
                hookPlayer(plr)
            end)
        end

        if not ESPV1RemovingConn then
            ESPV1RemovingConn = Players.PlayerRemoving:Connect(destroyESPv1)
        end

        if not ESPV1LoopConn then
            ESPV1LoopConn = RunService.Heartbeat:Connect(function()
                for _, plr in ipairs(Players:GetPlayers()) do
                    ensureESPv1(plr)
                end
            end)
        end
    else
        for _, plr in ipairs(Players:GetPlayers()) do
            destroyESPv1(plr)
        end

        if ESPV1AddedConn then ESPV1AddedConn:Disconnect() ESPV1AddedConn = nil end
        if ESPV1RemovingConn then ESPV1RemovingConn:Disconnect() ESPV1RemovingConn = nil end
        if ESPV1LoopConn then ESPV1LoopConn:Disconnect() ESPV1LoopConn = nil end
        for plr, conn in pairs(ESPV1CharConns) do conn:Disconnect() ESPV1CharConns[plr] = nil end
        for plr, conn in pairs(ESPV1TeamConns) do conn:Disconnect() ESPV1TeamConns[plr] = nil end
        log("ESP V1 loop stopped")
    end
end

MainTab:CreateToggle({
    Name = "Highlight ESP",
    CurrentValue = false,
    Callback = function(state)
        local function ensureHighlight(plr)
            if plr.Character and plr.Character:FindFirstChild("HumanoidRootPart") and passesTeamCheck(plr) then
                local hrp = plr.Character.HumanoidRootPart
                local h = hrp:FindFirstChild("Highlight") or Instance.new("Highlight")
                h.Name = "Highlight"
                h.Adornee = plr.Character
                h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                h.FillTransparency = 1
                h.OutlineColor = getColor(plr)
                h.Parent = hrp
            end
        end

        if state then
            for _, plr in ipairs(Players:GetPlayers()) do
                ensureHighlight(plr)
            end

            HighlightAddedConn = Players.PlayerAdded:Connect(function(plr)
                plr.CharacterAdded:Connect(function(char)
                    char:WaitForChild("HumanoidRootPart")
                    ensureHighlight(plr)
                end)
            end)

            HighlightLoopConn = RunService.Heartbeat:Connect(function()
                for _, plr in ipairs(Players:GetPlayers()) do
                    if plr.Character and plr.Character:FindFirstChild("HumanoidRootPart") then
                        local hrp = plr.Character.HumanoidRootPart
                        local h = hrp:FindFirstChild("Highlight")
                        if passesTeamCheck(plr) then
                            ensureHighlight(plr)
                            if h then h.OutlineColor = getColor(plr) end
                        elseif h then
                            h:Destroy()
                        end
                    end
                end
            end)
        else
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr.Character and plr.Character:FindFirstChild("HumanoidRootPart") then
                    local h = plr.Character.HumanoidRootPart:FindFirstChild("Highlight")
                    if h then h:Destroy() end
                end
            end

            if HighlightAddedConn then HighlightAddedConn:Disconnect() HighlightAddedConn = nil end
            if HighlightLoopConn then HighlightLoopConn:Disconnect() HighlightLoopConn = nil end
        end

        log("Highlight ESP: " .. (state and "ON" or "OFF"))
    end
})

MainTab:CreateToggle({
    Name = "ESP V1 (Highlight)",
    CurrentValue = false,
    Callback = function(state)
        setESPv1(state)
        log("ESP V1: " .. (state and "ON" or "OFF"))
    end
})

MainTab:CreateToggle({
    Name = "Skeleton ESP",
    CurrentValue = false,
    Callback = function(state)
        setSkeleton(state)
        log("Skeleton ESP: " .. (state and "ON" or "OFF"))
    end
})

MainTab:CreateToggle({
    Name = "Box ESP",
    CurrentValue = false,
    Callback = function(state)
        getgenv().ESP.Box = state
        setBox(state)
        log("Box ESP: " .. (state and "ON" or "OFF"))
    end
})


MainTab:CreateToggle({
    Name = "Tracer ESP",
    CurrentValue = false,
    Callback = function(v)
        getgenv().ESP.Tracers = v
        setTracerLoop(v)
        log("Tracer ESP: " .. (v and "ON" or "OFF"))
    end
})


SettingsTab:CreateToggle({Name="Auto ESP on join",CurrentValue=true,Callback=function(v) getgenv().ESP.AutoJoin=v end})
SettingsTab:CreateToggle({Name="Team colors",CurrentValue=true,Callback=function(v) getgenv().ESP.TeamColors=v end})
SettingsTab:CreateToggle({
    Name = "Team Check (forced ON)",
    CurrentValue = true,
    Callback = function()
        getgenv().ESP.TeamCheck = true
    end
})
SettingsTab:CreateSlider({
    Name = "Tracer Thickness",
    Range = {1, 5},
    Increment = 1,
    CurrentValue = getgenv().ESP.TracerThickness or 1,
    Callback = function(v)
        getgenv().ESP.TracerThickness = v
        for _, line in pairs(TracerFolder) do
            line.Thickness = v
        end
    end
})
SettingsTab:CreateSlider({
    Name = "Box Thickness",
    Range = {1, 5},
    Increment = 1,
    CurrentValue = getgenv().ESP.BoxThickness or 2,
    Callback = function(v)
        getgenv().ESP.BoxThickness = v
        for _, sq in pairs(BoxObjects) do
            sq.Thickness = v
        end
    end
})
SettingsTab:CreateToggle({Name="ESP V1 Team Colors",CurrentValue=true,Callback=function(v)
    getgenv().ESPv1.TeamColors = v
    if getgenv().ESPv1.Enabled then
        for _, plr in ipairs(Players:GetPlayers()) do ensureESPv1(plr) end
    end
end})
SettingsTab:CreateToggle({Name="ESP V1 Always On Top",CurrentValue=true,Callback=function(v)
    getgenv().ESPv1.AlwaysOnTop = v
    if getgenv().ESPv1.Enabled then
        for _, plr in ipairs(Players:GetPlayers()) do ensureESPv1(plr) end
    end
end})
SettingsTab:CreateSlider({
    Name = "ESP V1 Fill Transparency",
    Range = {0, 1},
    Increment = 0.05,
    CurrentValue = getgenv().ESPv1.FillTransparency or 0,
    Callback = function(v)
        getgenv().ESPv1.FillTransparency = v
        if getgenv().ESPv1.Enabled then
            for _, plr in ipairs(Players:GetPlayers()) do ensureESPv1(plr) end
        end
    end
})
SettingsTab:CreateSlider({
    Name = "ESP V1 Outline Transparency",
    Range = {0, 1},
    Increment = 0.05,
    CurrentValue = getgenv().ESPv1.OutlineTransparency or 0,
    Callback = function(v)
        getgenv().ESPv1.OutlineTransparency = v
        if getgenv().ESPv1.Enabled then
            for _, plr in ipairs(Players:GetPlayers()) do ensureESPv1(plr) end
        end
    end
})

ConsoleTab:CreateButton({Name="Clear Console",Callback=function() consoleLines={} ConsoleLabel:Set({Title="Output",Content=""}) end})

InfoTab:CreateLabel("Made by Astraea Team")
log("ESP Hub loaded")

UpdatesTab:CreateParagraph({
    Title = "What's New",
    Content = table.concat({
        "- Anti-spectate safety removed per request.",
        "- Aimbot distance checks improved (respect MaxDistance, fallback aim parts).",
        "- Console logging added for loop start/stop: tracers, skeleton ESP, box ESP, aimbot, ESP V1.",
        "- ESP/aimbot/ESP V1/box/skeleton/tracer controls remain in Main/Aimbot tabs.",
        "",
        "Update v2 Patch:",
        "- Visibility check now retries past transparent/non-collide hits, preventing aimbot from staying disabled after targets reappear.",
        "- Aimbot loop is wrapped in pcall to log errors instead of breaking mid-game.",
        "",
        "Update v3 Patch:",
        "- Team checks are forced ON for ESP and aimbot toggles.",
        "- Aimbot, tracers, and boxes now skip dead bodies using humanoid state checks.",
        "",
        "Update v4 Patch:",
        "- Max Aim Power now snaps instantly (alpha = 1) for full-strength aim.",
        "- Head target selection locks directly to the Head when chosen.",
        "",
        "Update v5 Patch:",
        "- Visibility-on targets now snap instantly; head selection honors visibility directly.",
        "",
        "Update v6 Patch:",
        "- ESP V1 now re-hooks every player on respawn/team changes so highlights persist across new matches.",
    }, "\n")
})

-- Aimbot tab controls
AimbotTab:CreateToggle({
    Name = "Aimbot",
    CurrentValue = getgenv().Aimbot.Enabled,
    Callback = function(v)
        setAimbot(v)
        log("Aimbot: " .. (v and "ON" or "OFF"))
    end
})

notifyUpdateOnce()

AimbotTab:CreateToggle({
    Name = "FOV Circle",
    CurrentValue = getgenv().Aimbot.FOVEnabled,
    Callback = function(v)
        getgenv().Aimbot.FOVEnabled = v
        setFOVLoop(v)
        updateFOVCircle()
        log("FOV Circle: " .. (v and "ON" or "OFF"))
    end
})

AimbotTab:CreateToggle({
    Name = "Stick to targets inside FOV",
    CurrentValue = getgenv().Aimbot.FOVStick,
    Callback = function(v)
        getgenv().Aimbot.FOVStick = v
    end
})

AimbotTab:CreateDropdown({
    Name = "Aim Part",
    Options = {"Head", "Torso"},
    CurrentOption = {getgenv().Aimbot.AimPart or "Head"},
    Callback = function(option)
        if type(option) == "table" then
            option = option[1]
        end
        getgenv().Aimbot.AimPart = option
    end
})

AimbotTab:CreateSlider({
    Name = "Max Distance (studs)",
    Range = {50, 5000},
    Increment = 10,
    CurrentValue = getgenv().Aimbot.MaxDistance or 400,
    Callback = function(v)
        getgenv().Aimbot.MaxDistance = v
    end
})

AimbotTab:CreateSlider({
    Name = "Aim Power",
    Range = {0, 1},
    Increment = 0.05,
    CurrentValue = getgenv().Aimbot.AimPower or 0.5,
    Callback = function(v)
        getgenv().Aimbot.AimPower = v
    end
})

AimbotTab:CreateSlider({
    Name = "Smooth Delay (s)",
    Range = {0.05, 1},
    Increment = 0.05,
    CurrentValue = getgenv().Aimbot.SmoothDelay or 0.25,
    Callback = function(v)
        getgenv().Aimbot.SmoothDelay = v
    end
})

AimbotTab:CreateSlider({
    Name = "FOV Radius",
    Range = {20, 1000},
    Increment = 5,
    CurrentValue = getgenv().Aimbot.FOVRadius or 150,
    Callback = function(v)
        getgenv().Aimbot.FOVRadius = v
        updateFOVCircle()
    end
})

AimbotTab:CreateSlider({
    Name = "FOV Opacity",
    Range = {0, 1},
    Increment = 0.05,
    CurrentValue = getgenv().Aimbot.FOVOpacity or 0.35,
    Callback = function(v)
        getgenv().Aimbot.FOVOpacity = v
        updateFOVCircle()
    end
})

AimbotTab:CreateSlider({
    Name = "FOV Color - Red",
    Range = {0, 255},
    Increment = 5,
    CurrentValue = math.floor((getgenv().Aimbot.FOVColor or Color3.fromRGB(80, 170, 255)).R * 255),
    Callback = function(v)
        local c = getgenv().Aimbot.FOVColor or Color3.fromRGB(80, 170, 255)
        getgenv().Aimbot.FOVColor = Color3.fromRGB(v, math.floor(c.G * 255), math.floor(c.B * 255))
        updateFOVCircle()
    end
})

AimbotTab:CreateSlider({
    Name = "FOV Color - Green",
    Range = {0, 255},
    Increment = 5,
    CurrentValue = math.floor((getgenv().Aimbot.FOVColor or Color3.fromRGB(80, 170, 255)).G * 255),
    Callback = function(v)
        local c = getgenv().Aimbot.FOVColor or Color3.fromRGB(80, 170, 255)
        getgenv().Aimbot.FOVColor = Color3.fromRGB(math.floor(c.R * 255), v, math.floor(c.B * 255))
        updateFOVCircle()
    end
})

AimbotTab:CreateSlider({
    Name = "FOV Color - Blue",
    Range = {0, 255},
    Increment = 5,
    CurrentValue = math.floor((getgenv().Aimbot.FOVColor or Color3.fromRGB(80, 170, 255)).B * 255),
    Callback = function(v)
        local c = getgenv().Aimbot.FOVColor or Color3.fromRGB(80, 170, 255)
        getgenv().Aimbot.FOVColor = Color3.fromRGB(math.floor(c.R * 255), math.floor(c.G * 255), v)
        updateFOVCircle()
    end
})

AimbotTab:CreateToggle({
    Name = "Aimbot Team Check (forced ON)",
    CurrentValue = true,
    Callback = function()
        getgenv().Aimbot.TeamCheck = true
    end
})

AimbotTab:CreateToggle({
    Name = "Visibility Check",
    CurrentValue = getgenv().Aimbot.VisibilityCheck,
    Callback = function(v)
        getgenv().Aimbot.VisibilityCheck = v
    end
})
