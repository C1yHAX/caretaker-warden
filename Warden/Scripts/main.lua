--[[
    Warden - admin menu for The Last Caretaker (UE4SS Lua).

      F1          open / close the menu        (toggleKey in settings.ini)
      CTRL + F1   panic: close and hand input back to the game, whatever the state

    The window is built on the first open and then only shown and hidden. Background
    effects (god mode, multipliers, frozen time) run on a game thread loop four times a
    second whether the menu is open or not.
--]]

local core = require("core")
local ui = require("ui")
local player = require("features.player")
local unlocks = require("features.unlocks")
local spawn = require("features.spawn")
local teleport = require("features.teleport")
local world = require("features.world")
local system = require("features.system")
local weapons = require("features.weapons")
local utility = require("features.utility")
local boat = require("features.boat")
local building = require("features.building")
local instant = require("features.instant")

core.loadSettings()

-- This build needs the game-thread scheduler. An async fallback would reintroduce
-- concurrent Lua access. Fail before registering keys on unsupported UE4SS builds.
if LoopInGameThreadWithDelay == nil or RegisterKeyBind == nil then
    core.log("Warden requires LoopInGameThreadWithDelay and RegisterKeyBind; mod inactive")
    return
end

local keyName = tostring(core.setting("toggleKey", "F1")):upper()
local toggleKey = Key[keyName]
if toggleKey == nil then
    core.log("unknown toggleKey '" .. keyName .. "' in settings.ini - using F1")
    keyName, toggleKey = "F1", Key.F1
end

local hooks = {}

local builders = {
    { title = "Spieler", build = player.page },
    { title = "Waffen", build = weapons.page },
    { title = "Freischalten", build = unlocks.page },
    { title = "Spawnen", build = spawn.page },
    { title = "Teleport", build = teleport.page },
    { title = "Boot", build = boat.page },
    { title = "Welt", build = world.page },
    { title = "System", build = function(u) return system.page(u, hooks) end },
    { title = "Log", build = require("features.log").page },
}

local function build()
    ui.walkWhileOpen = core.setting("walk", true)
    ui.traceBuilds = core.setting("trace", false)
    ui.trace = ui.traceBuilds
    ui.reset()
    local ok, err = pcall(ui.build, builders, { position = core.setting("position", "left"), keyName = keyName })
    ui.trace = false
    if not ok then
        error(err, 0)
    end
    ui.setBlocker(core.setting("block", true))
end

-- The player controller changes on every world load. Everything tied to the old one
-- is forgotten; the window is rebuilt on the next open.
local pcAddress = nil
local function watchWorld()
    local pc = core.pc()
    local address = pc and core.address(pc) or nil
    if address ~= pcAddress then
        if pcAddress ~= nil then
            core.log("world changed")
            if ui.isOpen then
                ui.releaseInput()
            end
            ui.reset()
            player.onWorldChanged()
            world.onWorldChanged()
            spawn.onWorldChanged()
            weapons.onWorldChanged()
            utility.onWorldChanged()
            boat.onWorldChanged()
            building.onWorldChanged()
            instant.onWorldChanged()
        end
        pcAddress = address
    end
end

function hooks.rebuild()
    ui.hide()
    local ok = core.safe("rebuild", build)
    if ok then
        ui.show()
        ui.toast("Menü neu aufgebaut", "good")
    end
end

function hooks.keyName()
    return keyName
end

-- Key callbacks run on UE4SS's input thread. Only assign boolean upvalues there:
-- no logging, allocation, Unreal calls, or ExecuteInGameThread/lua_xmove. The locked
-- registration narrows the remaining UE4SS wrapper race; it is not a VM-wide lock.
local pendingToggle, pendingPanic = false, false
local function onToggleKey() pendingToggle = true end
local function onPanicKey() pendingPanic = true end

local function toggle()
    if not core.inGame() then
        core.log("not in a loaded game - menu not opened")
        return
    end
    watchWorld()
    if ui.isOpen then
        ui.hide()
        return
    end
    if not ui.isBuilt() then
        local ok = core.safe("build", build)
        if not ok then
            ui.releaseInput()
            return
        end
    end
    ui.show()
end

local function panic()
    core.safe("panic hide", ui.hide)
    core.safe("panic release", ui.releaseInput)
    core.log("panic key: input handed back to the game")
end

local function drainKeys()
    -- Panic wins if the modifier and plain binding both fire in the same interval.
    -- Run even when no player controller exists (loading/menu/failed open).
    if pendingPanic then
        pendingPanic, pendingToggle = false, false
        panic()
    elseif pendingToggle then
        pendingToggle = false
        toggle()
    end
end

local ticks = 0
local function tick()
    watchWorld()
    core.safe("utility tick", utility.tick)
    if core.pc() == nil then
        return
    end
    ticks = ticks + 1
    core.safe("player tick", player.tick)
    core.safe("world tick", world.tick)
    core.safe("packages tick", spawn.tick)
    core.safe("weapons tick", weapons.tick)
    core.safe("boat tick", boat.tick)
    core.safe("building tick", building.tick)
    core.safe("instant craft tick", instant.tick)
    if ticks % 2 == 0 then
        core.safe("ui tick", ui.tick)
    end
end

LoopInGameThreadWithDelay(50, function()
    core.safe("keys", drainKeys)
    core.safe("Katalog",require("features.catalog").tick)
end)
LoopInGameThreadWithDelay(250, function() core.safe("tick", tick) end)

local NO_MODIFIERS = {}
if IsKeyBindRegistered ~= nil and IsKeyBindRegistered(toggleKey, NO_MODIFIERS) then
    core.log(keyName .. " is already bound by another mod - set toggleKey in settings.ini")
else
    RegisterKeyBind(toggleKey, NO_MODIFIERS, onToggleKey)
    RegisterKeyBind(toggleKey, { ModifierKey.CONTROL }, onPanicKey)
    core.log(string.format("v%s loaded - %s opens the menu, CTRL + %s is the panic key", core.VERSION, keyName, keyName))
    core.log("Build: " .. core.BUILD)
end
