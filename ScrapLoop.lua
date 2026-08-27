local env = getgenv()

if env.ScrapLoopToggle and env.ScrapLoopToggle.Stop then
    pcall(env.ScrapLoopToggle.Stop)
end

local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Knit"))
local service = Knit.GetService("PickupManager")

local Config = {
    MenuToggleKey = Enum.KeyCode.Delete,
    ScanInterval = 0.3,
    ScrapAmount = 1000,
}

local Ui = {
    Window = nil,
    Toggle = nil,
    StatusTag = nil,
    AmountInput = nil,
    AimerToggle = nil,
    SentStat = nil,
}

local State = {
    Enabled = false,
    Running = false,
    Stopped = false,
    Sent = 0,
    LastId = nil,
    UsedIds = {},
    LastError = nil,
}
local AimerState = {
    Enabled = false,
    Hooked = false,
    CastRays = nil,
    OriginalCastRays = nil,
    RenderConnection = nil,
    Line = nil,
    Circle = nil,
}


local function findTargetId()
    for _, pickup in ipairs(CollectionService:GetTagged("Collectible")) do
        local id = pickup:GetAttribute("Id")
        if pickup:IsA("BasePart")
            and pickup.Parent
            and pickup:GetAttribute("Currency") == "SCRAP"
            and id ~= nil
            and id ~= State.LastId
            and not State.UsedIds[id] then
            return id
        end
    end
end

local function notify(text)
    warn("[ScrapLoop] " .. text)

    if not Ui.Window or Ui.Window.unloaded then
        return
    end

    pcall(function()
        Ui.Window:Notify({
            title = "Scrap Tool",
            content = text,
            duration = 2,
        })
    end)
end

local refreshUI
local function getClosestZombie()
    local camera = workspace.CurrentCamera
    local zombies = workspace:FindFirstChild("ServerZombies")
    if not camera or not zombies then
        return nil, nil, nil
    end

    local closestDistance = math.huge
    local mouseLocation = UserInputService:GetMouseLocation()
    local closestPart = nil
    local closestHumanoid = nil
    local closestPosition = nil

    for _, zombie in ipairs(zombies:GetChildren()) do
        local headPart = zombie:FindFirstChild("Head")
        local humanoid = zombie:FindFirstChildOfClass("Humanoid")
        if not (
            headPart
            and headPart:IsA("BasePart")
            and humanoid
            and humanoid.Health > 1
        ) then
            continue
        end

        local viewportPoint, onScreen = camera:WorldToViewportPoint(headPart.Position)
        if not onScreen then
            continue
        end

        local screenPosition = Vector2.new(viewportPoint.X, viewportPoint.Y)
        local distance = (screenPosition - mouseLocation).Magnitude
        if distance < closestDistance then
            closestPart = headPart
            closestHumanoid = humanoid
            closestPosition = screenPosition
            closestDistance = distance
        end
    end

    return closestPart, closestHumanoid, closestPosition
end

local function setAimerDrawingVisible(visible)
    if AimerState.Line then
        pcall(function()
            AimerState.Line.Visible = visible
        end)
    end

    if AimerState.Circle then
        pcall(function()
            AimerState.Circle.Visible = visible
        end)
    end
end

local function disconnectAimerRender()
    if not AimerState.RenderConnection then
        return
    end

    pcall(function()
        AimerState.RenderConnection:Disconnect()
    end)
    AimerState.RenderConnection = nil
end

local function destroyAimerDrawings()
    if AimerState.Line then
        pcall(function()
            AimerState.Line:Remove()
        end)
        AimerState.Line = nil
    end

    if AimerState.Circle then
        pcall(function()
            AimerState.Circle:Remove()
        end)
        AimerState.Circle = nil
    end
end

local function restoreAimerHook()
    if not AimerState.Hooked then
        return
    end

    local castRays = AimerState.CastRays
    local originalCastRays = AimerState.OriginalCastRays
    local restored = true

    if castRays and originalCastRays then
        restored = pcall(function()
            hookfunction(castRays, originalCastRays)
        end)
    end

    if restored then
        AimerState.Hooked = false
        AimerState.CastRays = nil
        AimerState.OriginalCastRays = nil
    end
end

local function updateAimerOverlay()
    pcall(function()
        if not AimerState.Enabled then
            setAimerDrawingVisible(false)
            return
        end

        local part, humanoid, position = getClosestZombie()
        if not part or not humanoid or not position then
            setAimerDrawingVisible(false)
            return
        end

        local mouseLocation = UserInputService:GetMouseLocation()
        AimerState.Line.From = mouseLocation
        AimerState.Line.To = position
        AimerState.Line.Visible = true
        AimerState.Circle.Position = position
        AimerState.Circle.Visible = true
    end)
end

local function ensureAimer()
    if AimerState.Hooked then
        return true
    end

    if type(Drawing) ~= "table" or type(Drawing.new) ~= "function" then
        return false, "Drawing API is unavailable"
    end
    if type(hookfunction) ~= "function" then
        return false, "hookfunction is unavailable"
    end

    local shared = ReplicatedStorage:FindFirstChild("Shared")
    local gunSystem = shared and shared:FindFirstChild("GunSystem")
    local utility = gunSystem and gunSystem:FindFirstChild("Utility")
    local castModule = utility and utility:FindFirstChild("castRays")
    if not castModule then
        return false, "castRays module was not found"
    end

    local requireOk, castRays = pcall(require, castModule)
    if not requireOk or type(castRays) ~= "function" then
        return false, "castRays could not be loaded"
    end

    local lineOk, line = pcall(Drawing.new, "Line")
    if not lineOk or not line then
        return false, "Line drawing could not be created"
    end

    local circleOk, circle = pcall(Drawing.new, "Circle")
    if not circleOk or not circle then
        pcall(function()
            line:Remove()
        end)
        return false, "Circle drawing could not be created"
    end

    pcall(function()
        line.Color = Color3.fromRGB(255, 0, 0)
        line.Visible = false
        circle.Color = Color3.fromRGB(255, 0, 0)
        circle.Radius = 5
        circle.Visible = false
    end)

    local originalCastRays
    local hookOk, hookError = pcall(function()
        originalCastRays = hookfunction(castRays, function(...)
            if AimerState.Enabled then
                local targetOk, part, humanoid = pcall(getClosestZombie)
                if targetOk and part and humanoid then
                    return {{
                        normal = Vector3.zero,
                        instance = part,
                        taggedHumanoid = humanoid,
                        position = part.Position,
                    }}
                end
            end

            return originalCastRays(...)
        end)
    end)

    if not hookOk or type(originalCastRays) ~= "function" then
        pcall(function()
            line:Remove()
            circle:Remove()
        end)
        return false, hookOk and "hookfunction returned an invalid original" or tostring(hookError)
    end

    AimerState.Line = line
    AimerState.Circle = circle
    AimerState.CastRays = castRays
    AimerState.OriginalCastRays = originalCastRays
    AimerState.Hooked = true

    local connectOk, connection = pcall(function()
        return RunService.RenderStepped:Connect(updateAimerOverlay)
    end)
    if not connectOk then
        restoreAimerHook()
        destroyAimerDrawings()
        return false, tostring(connection)
    end

    AimerState.RenderConnection = connection
    return true
end

local function stopAimer()
    AimerState.Enabled = false
    setAimerDrawingVisible(false)
    disconnectAimerRender()
    restoreAimerHook()
    destroyAimerDrawings()
end

local function setAimerEnabled(enabled)
    if State.Stopped then
        return
    end

    if enabled ~= true then
        AimerState.Enabled = false
        setAimerDrawingVisible(false)
        refreshUI()
        return
    end

    local ok, err = ensureAimer()
    if not ok then
        AimerState.Enabled = false
        setAimerDrawingVisible(false)
        notify("aimer unavailable: " .. tostring(err))
        refreshUI()
        return
    end

    AimerState.Enabled = true
    refreshUI()
end

local function scanOnce()
    if not State.Enabled or State.Stopped then
        return
    end

    local targetId = findTargetId()
    if targetId == nil then
        return
    end
    State.LastId = targetId

    local ok, err = pcall(function()
        service.Collect:Fire(targetId, "SCRAP", Config.ScrapAmount)
    end)

    if not ok then
        State.LastError = tostring(err)
        notify("remote error: " .. State.LastError)
        return
    end

    State.UsedIds[targetId] = true
    State.Sent += 1
    State.LastError = nil
    refreshUI()
end

local function startWorker()
    if State.Running then
        return
    end

    State.Running = true
    task.spawn(function()
        while State.Enabled and not State.Stopped do
            local ok, err = pcall(scanOnce)
            if not ok then
                State.LastError = tostring(err)
                notify("loop error: " .. State.LastError)
            end
            task.wait(Config.ScanInterval)
        end
        State.Running = false
    end)
end

local function setEnabled(enabled)
    if State.Stopped then
        return
    end

    State.Enabled = enabled == true
    refreshUI()

    if State.Enabled then
        startWorker()
    end
end

local function setScrapAmount(value)
    if State.Stopped then
        return
    end

    local amount = tonumber(value)
    if not amount
        or amount ~= amount
        or amount == math.huge
        or amount == -math.huge then
        return
    end

    Config.ScrapAmount = math.max(1, math.floor(amount))

    if Ui.AmountInput then
        pcall(function()
            Ui.AmountInput:Set(tostring(Config.ScrapAmount), true)
        end)
    end
end
local Controller = {
    Config = Config,
    SetEnabled = setEnabled,
    IsEnabled = function()
        return State.Enabled
    end,
    GetSentCount = function()
        return State.Sent
    end,
    Stop = function()
        if State.Stopped then
            return
        end

        State.Stopped = true
        State.Enabled = false
        stopAimer()

        if Ui.Window and not Ui.Window.unloaded then
            pcall(function()
                Ui.Window:Unload()
            end)
        end

        env.ScrapLoopToggle = nil
    end,
}

local function safeUiCall(callback)
    pcall(callback)
end

refreshUI = function()
    if State.Stopped then
        return
    end

    if Ui.Toggle then
        safeUiCall(function()
            Ui.Toggle:Set(State.Enabled, true)
        end)
    end

    if Ui.StatusTag then
        safeUiCall(function()
            Ui.StatusTag:Set({
                text = State.Enabled and "ACTIVE" or "IDLE",
                color = State.Enabled
                    and Color3.fromRGB(55, 171, 112)
                    or Color3.fromRGB(82, 82, 82),
            })
        end)
    end

    if Ui.SentStat then
        safeUiCall(function()
            Ui.SentStat:Set(State.Sent)
        end)
    end
    if Ui.AimerToggle then
        safeUiCall(function()
            Ui.AimerToggle:Set(AimerState.Enabled, true)
        end)
    end
end

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/gen2"))()
local Window = Rayfield:CreateWindow({
    name = "Scrap Tool",
    subtitle = "use in game",
    theme = "default",
})
Ui.Window = Window

local tab = Window:CreateTab({
    name = "Scrap",
})

Ui.StatusTag = Window:CreateTag({
    text = "IDLE",
    color = Color3.fromRGB(82, 82, 82),
})

Ui.Toggle = tab:CreateToggle({
    name = "Unique-ID scrap loop",
    description = "Finds a new SCRAP pickup ID each cycle and sends it once",
    value = false,
    flag = "ScrapLoopEnabled",
    forgetState = true,
    callback = setEnabled,
})

Ui.AmountInput = tab:CreateInput({
    name = "Scrap amount",
    description = "Amount sent with each pickup request",
    numeric = true,
    value = tostring(Config.ScrapAmount),
    placeholder = "Enter a whole number",
    flag = "ScrapAmount",
    forgetState = true,
    callback = setScrapAmount,
})
Ui.SentStat = tab:CreateStat({
    name = "Remote sends",
    value = 0,
})

local aimerTab = Window:CreateTab({
    name = "Aimer",
})

Ui.AimerToggle = aimerTab:CreateToggle({
    name = "Zombie aimer",
    description = "Hooks the gun raycast to the nearest visible zombie head",
    value = false,
    flag = "AimerEnabled",
    forgetState = true,
    callback = setAimerEnabled,
})

tab:CreateKeybind({
    name = "Toggle window",
    description = "Show or hide the Rayfield window",
    value = Config.MenuToggleKey,
    forgetState = true,
    callback = function()
        if Window.unloaded then
            return
        end
        Window:ToggleHide()
    end,
})

tab:CreateButton({
    name = "Stop and unload",
    description = "Disable the loop and close the interface",
    callback = Controller.Stop,
})

refreshUI()
env.ScrapLoopToggle = Controller
notify("loaded; loop is off")
return Controller
