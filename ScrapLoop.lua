local env = getgenv()

if env.ScrapLoopToggle and env.ScrapLoopToggle.Stop then
    pcall(env.ScrapLoopToggle.Stop)
end

local CollectionService = game:GetService("CollectionService")
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
