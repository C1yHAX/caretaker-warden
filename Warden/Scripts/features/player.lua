local tr = require("i18n").t
--[[
    features/player.lua - survival, movement and character progress.

    Survival values live in the player controller's VoyageSurvivalComponent. Filling one
    reads its maximum with GetAttribute and writes it with SetAttributeValue; when the
    read does not work in this UE4SS build, UpdateMaxValue(type, true) is used instead,
    which recalculates the maximum and sets the value to it.

    Movement is handled by features.movement on a frame loop, with per-character
    snapshots for restoring the original speed and collision settings.
--]]

local core = require("core")
local movement = require("features.movement")
local utility = require("features.utility")
local building = require("features.building")

local M = {}

-- EVoyageSurvivalAttributeType
local A = {
    Temperature = 1, Nutrition = 2, Hydration = 3, Oxygen = 4, Radiation = 5,
    Fever = 6, Hypothermia = 7, Health = 8, Stamina = 9, Charge = 10,
}

local S = {
    god = false,
    oxygen = false,
    food = false,
    stamina = false,
    charge = false,
    immune = false,
}
M.state = S

local SPEEDS, JUMPS, FLY_SPEEDS = movement.speeds, movement.jumps, movement.flights
local mult = movement.indices

------------------------------------------------------------------------------------------
-- Survival
------------------------------------------------------------------------------------------

local readMode = nil   -- "struct" when GetAttribute works, "update" otherwise

local function field(v, name)
    if v == nil then
        return nil
    end
    local ok, x = pcall(function() return v[name] end)
    if ok and type(x) == "number" then
        return x
    end
    return nil
end

local function readAttribute(surv, attr)
    local v = core.outValue("GetAttribute", function(h) return surv:GetAttribute(attr, h) end, "OutValue")
    local value, max = field(v, "Value"), field(v, "MaxValue")
    if value ~= nil and max ~= nil then
        return value, max, field(v, "MinValue") or 0.0
    end
    return nil
end

local function fill(surv, attr)
    if readMode ~= "update" then
        local value, max = readAttribute(surv, attr)
        if value ~= nil then
            if readMode == nil then
                readMode = "struct"
                core.log("survival: values are read with GetAttribute")
            end
            if value < max - 0.01 then
                pcall(function() surv:SetAttributeValue(attr, max, true) end)
            end
            return
        end
        if readMode == nil then
            readMode = "update"
            core.log("survival: GetAttribute unreadable here, using UpdateMaxValue")
        end
    end
    pcall(function() surv:UpdateMaxValue(attr, true) end)
end

local function drain(surv, attr)
    if readMode == "struct" then
        local value, _, min = readAttribute(surv, attr)
        if value ~= nil and value <= min + 0.01 then
            return
        end
        pcall(function() surv:SetAttributeValue(attr, min or 0.0, true) end)
        return
    end
    pcall(function() surv:SetAttributeValue(attr, 0.0, true) end)
end

function M.refillAll()
    local surv = core.survival()
    if surv == nil then
        return false, tr("Kein Überlebens-Status gefunden (im Spiel?)")
    end
    for _, attr in ipairs({ A.Health, A.Oxygen, A.Nutrition, A.Hydration, A.Stamina, A.Charge }) do
        fill(surv, attr)
    end
    for _, attr in ipairs({ A.Radiation, A.Fever, A.Hypothermia }) do
        drain(surv, attr)
    end
    building.fillEnergy()
    return true, tr("Alle Werte aufgefüllt")
end

local damageBlocked = false

local function setDamage(blocked)
    local pawn = core.pawn()
    if pawn ~= nil then
        pcall(function() pawn:SetCanBeDamaged(not blocked) end)
    end
    damageBlocked = blocked
end

function M.setGod(on)
    S.god = on
    setDamage(on)
    core.console("Voyage.Character.PreventDamage " .. (on and "1" or "0"))
    if on then
        M.refillAll()
    end
end

function M.setImmune(on)
    S.immune = on
    core.console("Voyage.Character.ColdImmunity " .. (on and "1" or "0"))
    core.console("Voyage.Survival.DisableCold " .. (on and "1" or "0"))
end

local function survivalTick()
    if not (S.god or S.oxygen or S.food or S.stamina or S.charge or S.immune) then
        return
    end
    local surv = core.survival()
    if surv == nil then
        return
    end
    if S.god then
        fill(surv, A.Health)
        -- The pawn changes on respawn and on leaving a vehicle; keep it invulnerable.
        setDamage(true)
    end
    if S.god or S.oxygen then fill(surv, A.Oxygen) end
    if S.god or S.food then
        fill(surv, A.Nutrition)
        fill(surv, A.Hydration)
    end
    if S.god or S.stamina then fill(surv, A.Stamina) end
    if S.god or S.charge then
        fill(surv, A.Charge)
        building.fillEnergy() -- fill the actual module, not only the survival display
    end
    if S.god or S.immune then
        drain(surv, A.Radiation)
        drain(surv, A.Fever)
        drain(surv, A.Hypothermia)
    end
end

------------------------------------------------------------------------------------------
-- Movement
------------------------------------------------------------------------------------------

M.setFly, M.setNoclip = movement.setFly, movement.setNoclip

------------------------------------------------------------------------------------------
-- Progress
------------------------------------------------------------------------------------------

function M.level()
    local lib, pc = core.lib("gameplayV"), core.pc()
    if lib == nil or pc == nil then
        return nil
    end
    local ok, lvl = pcall(function() return lib:GetLevelFromController(pc) end)
    return ok and lvl or nil
end

local function skillPoints()
    local lib, pc = core.lib("gameplayV"), core.pc()
    local ok, n = pcall(function() return lib:GetAvailableSkillPoints(pc) end)
    return ok and n or nil
end

function M.gainExp(amount)
    local lib, pc = core.lib("gameplayV"), core.pc()
    if lib == nil or pc == nil then
        return false, tr("Kein Spieler")
    end
    local args = {
        Source = 5,   -- EVoyageExperienceType::Cheat
        Amount = math.floor(amount),
        SourceLocation = core.vec(),
        bUseSourceLocation = false,
    }
    local before = M.level()
    local ok, res = pcall(function() return lib:GainPlayerExp(pc, args) end)
    if not ok or res == false then
        local ps = core.playerState()
        if ps ~= nil then
            ok, res = pcall(function() return ps:GainExp(args) end)
        end
    end
    if not ok then
        return false, tr("EXP fehlgeschlagen: ") .. tostring(res)
    end
    local after = M.level()
    local msg = "+" .. core.thousands(amount) .. " EXP"
    if before ~= nil and after ~= nil and after > before then
        msg = msg .. "  \u{2022}  Level " .. before .. " \u{2192} " .. after
    end
    return true, msg
end

function M.levelUp(levels)
    local lib = core.lib("gameplayV")
    local current = M.level()
    if lib == nil or current == nil then
        return false, tr("Level nicht lesbar")
    end
    local okCap, cap = pcall(function() return lib:GetLevelCap() end)
    local target = current + levels
    if okCap and type(cap) == "number" and cap > 0 then
        target = math.min(target, cap)
    end
    if target <= current then
        return false, tr("Maximales Level erreicht")
    end
    local ok, need = pcall(function() return lib:GetTotalExpRequired(current, target) end)
    if not ok or type(need) ~= "number" or need <= 0 then
        need = 25000 * levels
    end
    return M.gainExp(need + 1)
end

------------------------------------------------------------------------------------------
-- Tick and reset
------------------------------------------------------------------------------------------

function M.tick()
    survivalTick()
    movement.tick()
end

-- After a world change: nothing of the old pawn survives, so forget it. The toggles
-- themselves stay on and apply to the new pawn.
function M.onWorldChanged()
    damageBlocked = false
    movement.onWorldChanged()
end

------------------------------------------------------------------------------------------
-- Page
------------------------------------------------------------------------------------------

local function fmtFactor(v)
    return string.format("\u{00D7}%s", (v == math.floor(v)) and string.format("%d", v) or string.format("%.1f", v))
end

function M.page(ui)
    local page = ui.newPage(tr("Spieler"))

    local surv = ui.card(page.left, tr("Überleben"))
    ui.toggleRow(page, surv, tr("Gottmodus"), function() return S.god end, M.setGod,
        tr("Unverwundbar, alle Werte bleiben voll"))
    ui.toggleRow(page, surv, tr("Unendlich Sauerstoff"), function() return S.oxygen end,
        function(on) S.oxygen = on end)
    ui.toggleRow(page, surv, tr("Kein Hunger & Durst"), function() return S.food end,
        function(on) S.food = on end)
    ui.toggleRow(page, surv, tr("Unendlich Ausdauer"), function() return S.stamina end,
        function(on) S.stamina = on end)
    ui.toggleRow(page, surv, tr("Unendlich Anzug-Energie"), function() return S.charge end,
        function(on) S.charge = on end)
    ui.toggleRow(page, surv, tr("Immun: Kälte, Strahlung, Fieber"), function() return S.immune end,
        M.setImmune)
    ui.button(surv, tr("Alles sofort auffüllen"), "primary", function()
        local ok, msg = M.refillAll()
        ui.toast(msg, ok and "good" or "bad")
    end, { slot = { pad = { 0, 6, 0, 0 } } })

    local prog = ui.card(page.left, tr("Charakter"))
    ui.infoRow(page, prog, "Level", function()
        local lvl = M.level()
        return lvl and tostring(lvl) or "-"
    end)
    ui.infoRow(page, prog, tr("Freie Skillpunkte"), function()
        local n = skillPoints()
        return n and tostring(n) or "-"
    end)
    local function exp(n)
        return function()
            local ok, msg = M.gainExp(n)
            ui.toast(msg, ok and "good" or "bad")
            ui.refreshActive()
        end
    end
    local function lvl(n)
        return function()
            local ok, msg = M.levelUp(n)
            ui.toast(msg, ok and "good" or "bad")
            ui.refreshActive()
        end
    end
    ui.buttonGrid(prog, 3, {
        { tr("+1.000 EXP"), exp(1000) }, { tr("+10.000 EXP"), exp(10000) }, { tr("+100.000 EXP"), exp(100000) },
        { "+1 Level", lvl(1) }, { "+5 Level", lvl(5) }, { "+10 Level", lvl(10) },
    })

    local move = ui.card(page.right, tr("Bewegung"))
    ui.toggleRow(page, move, tr("Fliegen"), function() return movement.state.fly end, M.setFly,
        tr("WASD / linker Stick, Leertaste hoch, Strg / C runter"))
    ui.toggleRow(page, move, "Noclip", function() return movement.state.noclip end, M.setNoclip,
        tr("Fliegen durch Wände und Boden"))
    ui.stepperRow(page, move, tr("Lauftempo"), {
        values = SPEEDS, format = fmtFactor,
        index = function() return mult.walk end,
        set = function(i) movement.setIndex("walk", i) end,
    })
    ui.stepperRow(page, move, tr("Sprungkraft"), {
        values = JUMPS, format = fmtFactor,
        index = function() return mult.jump end,
        set = function(i) movement.setIndex("jump", i) end,
    })
    ui.stepperRow(page, move, tr("Fluggeschwindigkeit"), {
        values = FLY_SPEEDS, format = fmtFactor,
        index = function() return mult.fly end,
        set = function(i) movement.setIndex("fly", i) end,
    })

    local view = ui.card(page.right, tr("Ansicht & Notfall"))
    local function cheat(fn, done)
        return function()
            local ok, err = core.cheat(fn)
            ui.toast(ok and done or (tr("Fehlgeschlagen: ") .. tostring(err)), ok and "good" or "bad")
        end
    end
    ui.buttonGrid(view, 2, {
        { "Third-Person", cheat("ToggleCharacterThirdPerson", tr("Kamera umgeschaltet")) },
        { tr("Freie Kamera"), cheat("ToggleSpectatorMode", tr("Zuschauer-Modus umgeschaltet (nochmal = zurück)")) },
    })
    ui.button(view, "Respawn", "danger", cheat("Respawn", tr("Respawn ausgelöst")),
        { slot = { pad = { 0, 4, 0, 0 } } })

    utility.addToPage(ui, page, page.left)
    return page
end

return M
