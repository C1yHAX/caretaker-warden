local tr = require("i18n").t
--[[
    features/world.lua - time of day, weather, the boat, threats and simulation speed.

    Time of day: the game keeps world time in BP_PersistentWorldTime and drives the
    Ultra Dynamic Sky from it every tick, with TimeOffset added on top. Setting a time
    therefore means choosing the offset that lands the sky on the wanted hour. The
    result is checked a moment later and corrected once if the sky is not there, so the
    exact formula the blueprint uses does not have to be known.

    "Zeit anhalten" keeps re-pinning that offset a few times a second instead of
    touching the blueprint's own override flag, so nothing about it ends up in the save.
--]]

local core = require("core")
local weatherreset = require("weatherreset")

local M = {}

local SKY = "Ultra_Dynamic_Sky_C"
local WORLD_TIME = "BP_PersistentWorldTime_C"
local TOD = "Time of Day"

local function first(className)
    local ok, obj = pcall(FindFirstOf, className)
    if ok and core.isValid(obj) then
        return obj
    end
    return nil
end

function M.time()
    local uds = first(SKY)
    if uds == nil then
        return nil
    end
    local ok, t = pcall(function() return uds[TOD] end)
    if ok and type(t) == "number" then
        return t
    end
    return nil
end

local function wrap(t)
    return t % 2400
end

local function pin(t)
    local uds, wt = first(SKY), first(WORLD_TIME)
    if uds == nil or wt == nil then
        return false
    end
    local okCur, cur = pcall(function() return uds[TOD] end)
    local okOff, off = pcall(function() return wt.TimeOffset end)
    if not (okCur and okOff) or type(cur) ~= "number" or type(off) ~= "number" then
        return false
    end
    local base = wrap(cur - off)
    pcall(function() wt.TimeOffset = wrap(t - base) end)
    pcall(function() uds[TOD] = wrap(t) end)
    return true
end

local frozen = nil

function M.setTime(t)
    t = wrap(t)
    if not pin(t) then
        local ok = core.cheat("SetWorldTime", t)
        if not ok then
            return false, tr("Tageszeit nicht verfügbar")
        end
    end
    if frozen ~= nil then
        frozen = t
    end
    -- One correction after the sky has ticked: whatever the blueprint adds on top shows
    -- up as the difference and is taken out of the offset.
    ExecuteInGameThreadWithDelay(600, function()
        local now = M.time()
        if now ~= nil then
            local diff = wrap(now - t + 1200) - 1200
            if math.abs(diff) > 15 then
                local wt = first(WORLD_TIME)
                if wt ~= nil then
                    pcall(function() wt.TimeOffset = wrap(wt.TimeOffset - diff) end)
                    core.log(string.format("time corrected by %.0f", -diff))
                end
            end
        end
    end)
    return true, tr("Uhrzeit: ") .. M.clock(t)
end

function M.clock(t)
    if t == nil then
        return "-"
    end
    local h = math.floor(t / 100) % 24
    local m = math.floor((t % 100) * 0.6)
    return string.format("%02d:%02d", h, m)
end

function M.setFrozen(on)
    frozen = on and M.time() or nil
end

function M.isFrozen()
    return frozen ~= nil
end

------------------------------------------------------------------------------------------
-- Simulation speeds
------------------------------------------------------------------------------------------

local PRODUCTION = { 1, 2, 3, 5, 10, 25 }
local PRODUCTION_CVAR = "Voyage.ModuleSubsystem.SpeedMultiplier"
local GAME_SPEED = { 0.25, 0.5, 1.0, 1.5, 2.0, 3.0 }

local function nearest(values, v)
    local best, bestD = 1, math.huge
    for i, x in ipairs(values) do
        local d = math.abs(x - v)
        if d < bestD then
            best, bestD = i, d
        end
    end
    return best
end

local function productionIndex()
    local v = core.cvarFloat(PRODUCTION_CVAR)
    return nearest(PRODUCTION, v or 1)
end

local function gameSpeedIndex()
    local gs, pc = core.lib("gameplay"), core.pc()
    local ok, v = pcall(function() return gs:GetGlobalTimeDilation(pc) end)
    return nearest(GAME_SPEED, (ok and type(v) == "number") and v or 1)
end

------------------------------------------------------------------------------------------
-- Tick
------------------------------------------------------------------------------------------

function M.tick()
    if frozen ~= nil then
        pin(frozen)
    end
end

function M.onWorldChanged()
    frozen = nil
end

------------------------------------------------------------------------------------------
-- Page
------------------------------------------------------------------------------------------

local function fmt(v)
    return (v == math.floor(v)) and string.format("\u{00D7}%d", v) or string.format("\u{00D7}%.2g", v)
end

function M.page(ui)
    local page = ui.newPage(tr("Welt"))

    local function show(ok, msg)
        ui.toast(msg, ok and "good" or "bad")
    end
    local function at(t)
        return function() show(M.setTime(t)) end
    end
    local function shift(delta)
        return function()
            local now = M.time()
            if now == nil then
                show(false, tr("Tageszeit nicht lesbar"))
                return
            end
            show(M.setTime(now + delta))
        end
    end

    local time = ui.card(page.left, tr("Tageszeit"))
    ui.infoRow(page, time, tr("Aktuelle Uhrzeit"), function() return M.clock(M.time()) end)
    ui.buttonGrid(time, 4, {
        { tr("Morgen"), at(600) }, { tr("Mittag"), at(1200) }, { tr("Abend"), at(1800) }, { tr("Nacht"), at(0) },
        { "\u{2212}3 h", shift(-300) }, { "\u{2212}1 h", shift(-100) }, { "+1 h", shift(100) }, { "+3 h", shift(300) },
    })
    ui.toggleRow(page, time, tr("Zeit anhalten"), M.isFrozen, M.setFrozen, tr("Hält die aktuelle Uhrzeit fest"))

    local weather = ui.card(page.left, tr("Wetter"))
    ui.add(weather, ui.paragraph(tr("Setzt das weltweite Wetter auf den Spiel-Standard zurück, nachdem ")
        .. tr("das Admin-Menü des Spiels es verändert hat. Danach speichern.")), { pad = { 2, 0, 2, 6 } })
    ui.button(weather, tr("Wetter auf Standard zurücksetzen"), "action", function()
        local ok, msg = weatherreset.reset()
        ui.toast(ok and tr("Wetter zurückgesetzt \u{2013} jetzt speichern") or tostring(msg), ok and "good" or "bad")
    end)

    local sim = ui.card(page.left, "Simulation")
    ui.stepperRow(page, sim, tr("Produktionstempo"), {
        values = PRODUCTION, format = fmt, note = tr("Module, Generatoren, Fabriken"),
        index = productionIndex,
        set = function(i)
            if core.setCvar(PRODUCTION_CVAR, PRODUCTION[i]) then
                ui.toast(tr("Produktionstempo ") .. fmt(PRODUCTION[i]), "good")
            else
                ui.toast(tr("Produktionstempo lässt sich in diesem Build nicht setzen"), "warn")
            end
        end,
    })
    ui.stepperRow(page, sim, tr("Spielgeschwindigkeit"), {
        values = GAME_SPEED, format = fmt,
        index = gameSpeedIndex,
        set = function(i)
            local gs, pc = core.lib("gameplay"), core.pc()
            local ok = pcall(function() gs:SetGlobalTimeDilation(pc, GAME_SPEED[i]) end)
            ui.toast(ok and (tr("Spielgeschwindigkeit ") .. fmt(GAME_SPEED[i])) or tr("Fehlgeschlagen"), ok and "good" or "bad")
        end,
    })

    local function cheat(fn, done, ...)
        local args = table.pack(...)
        return function()
            local ok, err = core.cheat(fn, table.unpack(args, 1, args.n))
            ui.toast(ok and done or (tr("Fehlgeschlagen: ") .. tostring(err)), ok and "good" or "bad")
        end
    end

    local danger = ui.card(page.right, tr("Gefahren in der Nähe"))
    require("features.storage").addToPage(ui, page, page.right)
    require("features.building").addToPage(ui, page, page.right)
    require("features.carrier").addToPage(ui,page,page.right)
    ui.button(danger, tr("Schwärme vernichten"), "action", cheat("Kill Swarm", tr("Schwärme in der Nähe vernichtet")))
    ui.button(danger, tr("Eiersäcke zerstören"), "action", cheat("DestroyEggs", tr("Eiersäcke zerstört")))
    ui.button(danger, tr("NPCs in der Nähe ausschalten"), "danger",
        cheat("Damage NPCs", tr("NPCs in der Nähe getroffen"), 5000.0))

    return page
end

return M
