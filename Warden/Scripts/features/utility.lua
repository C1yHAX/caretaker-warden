local tr = require("i18n").t
--[[
    Session utilities for TLC 0.10.0.653173 / UE5.8.2. NOT tested in the game.
    Integration (caller owns the game-thread scheduler):
      utility.addToPage(ui, playerPage, playerPage.right)
      utility.tick() -- normally every 250 ms, ALSO during loading for restore retries
      utility.onWorldChanged() -- before discarding the old session
    Scalar setters change intent; tick applies/restores it. Free Crafting toggles
    its guarded native helper directly. No settings/save writes.

    Evidence: reference/CXXHeaderDump-0.10.0.653173/Voyage.hpp + corresponding JMAP.
      VoyageCharacter.PhysicsGrabber -> PhysicsGrabComponent (hard UObject pointer)
        MaxMassGrab @0x344, CharacterImpulseMultiplier @0x364: float, 4 bytes each.
      VoyageInventoryWeightLimitedComponent: MaxWeightLimit @0x4A8 (float),
        bAllowBeyondWeightLimit @0x4AC (bool). Only PlayerInventory (enum 1).
    Free Crafting is delegated to features.crafting. It only changes the native
    fabricator's temporary material-cost result. Shared recipe assets, inventory
    contents and recycling/dismantling data are never edited.
    Scalar UFunctions used below span at most 16 bytes (including return/out).
    See tools/test_utility.py and features/crafting.lua for pinned native evidence.
    Limits: grab admission is finite (1e9 mass). Native grab force is unchanged;
    only the held body is temporarily lightened by features.strength. Reaction
    impulse onto the character is zero while enabled. Interaction rules,
    anchoring, stow limits and energy still apply. Weight admission has a bool
    bypass; displayed base limit and extra carry capacity are finite 1e9.
    AddCarryExtraCapability uses only our reserved WardenInventoryWeight key.
    Disable replaces its amount with zero; the game's remove function checks the wrong map. GetMaxCarriedWeight native RVA 0x550B330 adds CharacterData's
    base to the instance's cached extra capability (0x9E4); Add native RVA
    0x54FAF70 updates its keyed map, total and notification. No CharacterData
    edits. Slots remain unchanged; loads above this finite capacity can burden.
    No save/INI write. Already obtained/moved objects are not undone by restore.
    No Lua UObject reference is retained across ticks (Lua is not a GC root).
    Journals hold names/addresses/numbers only; resolve fresh before any access.
--]]

local core = require("core")
local crafting = require("features.crafting")
local strength = require("features.strength")
local M = {}
local S = { strength = false, weight = false, crafting = false }
local CL = {
    character = "/Script/Voyage.VoyageCharacter",
    grab = "/Script/Voyage.PhysicsGrabComponent",
    inventory = "/Script/Voyage.VoyageInventoryWeightLimitedComponent",
}
local grab, inventory, carry, context = nil, nil, nil, nil
local carryKey
local neutralCarry = {}
local message = tr("Aus")

local function report(text)
    message = text
    core.logOnce("utility:" .. text, "utility: " .. text)
end

local function isA(obj, class)
    if not core.isValid(obj) then return false end
    local ok, yes = pcall(function() return obj:IsA(class) end)
    return ok and yes == true
end

local function identity(obj)
    if not core.isValid(obj) then return nil end
    local address, name = core.address(obj), core.fullName(obj)
    local path = name and name:match("^%S+%s+(.+)$")
    if address == nil or address == 0 or not path or path:find("Default__", 1, true)
        or path:find("/Script/", 1, true) == 1 then return nil end
    return { address = address, name = name, path = path, key = name .. "@" .. tostring(address) }
end

local function resolve(id, class)
    -- Unlike core.find, keep lookup errors distinct from a destroyed object.
    local ok, obj = pcall(StaticFindObject, id.path)
    if not ok then return nil, false end
    if not isA(obj, class) then return nil, true end
    if core.address(obj) ~= id.address or core.fullName(obj) ~= id.name then return nil, true end
    return obj, true
end

local function read(obj, prop, expected)
    local ok, value = pcall(function() return obj[prop] end)
    if not ok or type(value) ~= expected then return nil end
    if expected == "number" and (value ~= value or math.abs(value) == math.huge) then return nil end
    return value
end

local function write(obj, field, value)
    local ok = pcall(function()
        if field.prop == "MaxWeightLimit" then
            obj:SetMaxWeightLimit(value) -- broadcasts limit changes; preserve other modifiers
        else
            obj[field.prop] = value
        end
    end)
    return ok and read(obj, field.prop, type(value)) == value
end

-- Compare-before-restore: a later game/mod write wins over our snapshot.
-- Failed reads/writes retain the journal for another tick. Never restore defaults.
local function restoreScalar(record)
    if not record then return nil end
    local obj, resolved = resolve(record.id, record.class)
    if not resolved then return record end
    if not obj then return nil end -- destroyed/unloaded/replaced object: never use the old pointer
    local pending = false
    for _, field in ipairs(record.fields) do
        if field.dirty then
            local current = read(obj, field.prop, type(field.before))
            if current == nil then
                pending = true
            elseif current ~= field.last or write(obj, field, field.before) then
                field.dirty = false
            else
                pending = true
            end
        end
    end
    if pending then return record end
    return nil
end

local function scalarTick(record, obj, class, fields, enabled)
    local id = isA(obj, class) and identity(obj) or nil
    if record and (not enabled or not id or record.id.key ~= id.key) then
        record = restoreScalar(record)
        if record then return record, false end -- do not layer a new snapshot onto failed restore
    end
    if not enabled or not id then return record, true end
    if not record then
        record = { id = id, class = class, fields = fields }
        -- Preflight EVERY scalar before the first write (including false and zero).
        for _, field in ipairs(fields) do
            field.before = read(obj, field.prop, type(field.target))
            if field.before == nil then return nil, false end
        end
    end
    for _, field in ipairs(record.fields) do
        local current = read(obj, field.prop, type(field.target))
        if current == nil then return record, false end
        if not field.dirty or current ~= field.last then field.before = current end
        local target = not field.exact and type(field.target) == "number"
            and math.max(field.before, field.target) or field.target
        if current ~= target then
            field.last, field.dirty = target, true -- journal BEFORE a possibly partial write
            if not write(obj, field, target) then return record, false end
        end
    end
    return record, true
end

local function hasCarry(pawn)
    local ok, value = pcall(function() return pawn:HasCarryExtraCapability(carryKey) end)
    if ok and type(value) == "boolean" then return value end
    return nil
end

local function restoreCarry(record)
    if not record then return nil end
    local pawn, resolved = resolve(record.id, CL.character)
    if not resolved then return record end
    if not pawn then return nil end
    local has = hasCarry(pawn)
    if has == false then return nil end
    if has == nil then return record end
    -- TLC 0.10's RemoveCarryExtraCapability checks the CARRIED-weight map
    -- (+0x990) before removing from the EXTRA-capacity map (+0x9e8). A normal
    -- extra-only entry therefore never gets removed. Add replaces the keyed
    -- amount and recomputes the total + notifications; a zero entry is neutral.
    local ok, reset = pcall(function() return pawn:AddCarryExtraCapability(carryKey, 0.0) end)
    if ok and reset == true then
        neutralCarry[record.id.key] = true
        return nil
    end
    return record
end

local function carryTick(pawn, enabled)
    local id = isA(pawn, CL.character) and identity(pawn) or nil
    if carry and (not enabled or not id or carry.id.key ~= id.key) then
        carry = restoreCarry(carry)
        if carry then return false end
    end
    if not enabled or not id then return true end
    if not carryKey then
        local ok, key = pcall(FName, "WardenInventoryWeight", 1) -- EFindName.FNAME_Add
        if not ok or key == nil then return false end
        carryKey = key
    end
    local has = hasCarry(pawn)
    if has == nil then return false end
    if not carry and has and not neutralCarry[id.key] then
        -- This exact key is reserved by Warden. Recover a leftover from a Lua
        -- reload/older version before applying a fresh, reversible bonus.
        carry = restoreCarry({ id = id })
        if carry then return false end
    end
    if not carry or not has then
        carry = { id = id } -- journal our reserved key before the call
        neutralCarry[id.key] = nil
        local ok, added = pcall(function() return pawn:AddCarryExtraCapability(carryKey, 1000000000.0) end)
        return ok and added == true and hasCarry(pawn) == true
    end
    return true
end

function M.setSuperStrength(on) S.strength = on == true end
function M.setUnlimitedWeight(on) S.weight = on == true end
function M.setFreeCrafting(on)
    local ok = crafting.setEnabled(on == true)
    S.crafting = crafting.status().enabled
    if not ok then report(crafting.status().message) end
    return ok
end

function M.onWorldChanged()
    S.strength, S.weight, S.crafting = false, false, false
    context = nil
    crafting.setEnabled(false)
    strength.tick(nil, false)
    grab, inventory = restoreScalar(grab), restoreScalar(inventory)
    carry = restoreCarry(carry)
    report((grab or inventory or carry) and tr("Weltwechsel: Änderungen werden zurückgesetzt")
        or tr("Weltwechsel: Optionen aus; vorhandene Objekte wiederhergestellt"))
end

function M.tick()
    S.crafting = crafting.status().enabled
    if not (S.strength or S.weight or S.crafting or grab or inventory or carry or strength.pending()) then
        context = nil
        return
    end
    if not (S.strength or S.weight or S.crafting) then
        context = nil
        grab, inventory = restoreScalar(grab), restoreScalar(inventory)
        strength.tick(nil, false)
        carry = restoreCarry(carry)
        return
    end
    local pc = core.pc()
    local pcID = identity(pc)
    local worldID
    if pcID then
        local lib = core.lib("misc")
        if lib then
            local ok, world = pcall(function() return lib:GetActorWorld(pc) end)
            if ok then worldID = identity(world) end
        end
    end
    local now = pcID and worldID and (pcID.key .. "/" .. worldID.key) or nil
    if context and context ~= now then M.onWorldChanged(); return end
    context = now
    if not now then
        strength.tick(nil, false)
        grab, inventory = restoreScalar(grab), restoreScalar(inventory)
        carry = restoreCarry(carry)
        return
    end

    local pawn = core.pawn()
    local character = isA(pawn, CL.character)
    local grabber, inv
    if character then
        pcall(function() grabber = pawn.PhysicsGrabber end)
        -- Explicit controller API; never patch a vehicle, vault or nearby container.
        pcall(function() inv = pc:GetInventoryComponent(1) end)
    end
    local ok
    grab, ok = scalarTick(grab, grabber, CL.grab, {
        { prop = "MaxMassGrab", target = 1000000000.0 },
        -- MassGrabStrength also changes body mass and force, not just admission.
        -- Keep the game's force. Remove only its reaction impulse on the player.
        { prop = "CharacterImpulseMultiplier", target = 0.0, exact = true },
    }, S.strength)
    if ok then ok = strength.tick(grabber, S.strength) end
    if not ok then
        S.strength = false
        strength.tick(nil, false)
        grab = restoreScalar(grab)
        report(tr("Superstärke konnte nicht aktiviert werden; Änderungen werden zurückgesetzt"))
    end
    inventory, ok = scalarTick(inventory, inv, CL.inventory, {
        { prop = "bAllowBeyondWeightLimit", target = true },
        { prop = "MaxWeightLimit", target = 1000000000.0 },
    }, S.weight)
    if ok then ok = carryTick(character and pawn or nil, S.weight and isA(inv, CL.inventory)) end
    if not ok then
        S.weight = false
        inventory = restoreScalar(inventory)
        carry = restoreCarry(carry)
        report(tr("Gewichtslimit konnte nicht aufgehoben werden; Änderungen werden zurückgesetzt"))
    end
end

function M.status()
    local craft = crafting.status()
    return {
        strength = S.strength, weight = S.weight, crafting = craft.enabled,
        strengthApplied = S.strength and grab ~= nil, weightApplied = S.weight and inventory ~= nil,
        carryApplied = S.weight and carry ~= nil,
        craftingAvailable = craft.available, craftingMessage = craft.message,
        restoring = (not S.strength and (grab ~= nil or strength.pending()))
            or (not S.weight and (inventory ~= nil or carry ~= nil)),
        message = message,
    }
end

function M.addToPage(ui, page, parent)
    local card = ui.card(parent or page.right, tr("Tragen & Herstellen"), tr("Sitzung"))
    ui.toggleRow(page, card, tr("Superstärke beim Greifen"), function() return S.strength end,
        M.setSuperStrength, tr("Schwere lose Objekte tragen; normale Kraft, kein Gegenimpuls"))
    ui.toggleRow(page, card, tr("Unbegrenztes Inventargewicht"), function() return S.weight end,
        M.setUnlimitedWeight, tr("Sehr hohes Gewichtslimit und Tragfähigkeit; Slots bleiben"))
    ui.toggleRow(page, card, tr("Free Crafting ohne Materialien"), function() return crafting.status().enabled end,
        M.setFreeCrafting, tr("Nur Materialkosten; Recycling und Zerlegen bleiben unverändert"))
    ui.infoRow(page, card, tr("Herstellung"), function() return crafting.status().message end)
    require("features.instant").addToPage(ui,page,card)
    ui.infoRow(page, card, "Status", function()
        if not context and (S.strength or S.weight or S.crafting) then return tr("Warte auf Spielwelt") end
        if not (S.strength or S.weight or S.crafting) then
            return M.status().restoring and tr("Ausschalten wird abgeschlossen") or tr("Aus")
        end
        return ((S.strength and not grab) or (S.weight and not inventory))
            and tr("Warte auf Spielfigur") or tr("Aktiv")
    end)
    ui.infoRow(page, card, tr("Letzter Hinweis"), function() return message end)
    return card
end

return M
