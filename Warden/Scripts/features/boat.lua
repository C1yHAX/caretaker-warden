local tr = require("i18n").t
--[[
    Boat controls, TLC 0.10.0.653173 (UE 5.8.2). Game-thread entry points only.
    Integration: addToPage(ui, page, parent), tick(), onWorldChanged().
    No settings, hooks, timers, asset loading or global vehicle/physics CVars.

    Evidence: reference/CXXHeaderDump-0.10.0.653173/{Voyage,Engine}.hpp
    and Voyage-0.10.0.653173.jmap.gz. UFunction properties_size INCLUDING return:
      Engine.Actor:GetLevel                         8
      Engine.Actor:GetAttachParentActor             8
      Engine.Actor:GetAttachedActors               24 (TArray out, bool, bool)
      Engine.Actor:K2_GetComponentsByClass          24 (class + TArray return)
      Engine.Actor:K2_GetActorLocation              24
      Engine.Actor:HasAuthority                     1
      Engine.Actor:IsActorBeingDestroyed            1
      Engine.ActorComponent:GetOwner                8
      Engine.GameplayStatics:GetAllActorsOfClass    32 (via core.actorsOf)
      Engine.Controller:K2_GetPawn                   8 (via core.pawn fallback)
      Voyage.VoyageBoatPawn:GetAllModules           16 (TArray out)
      Voyage.VoyageModuleComponent:GetDurability     4
      Voyage.VoyageModuleComponent:GetMaxDurability  4
      Voyage.VoyageModuleComponent:Repair            4 (float Amount, void)
      Voyage.VoyageDestructibleObjectComponent:OverrideHealth 4 (float, void)
    UE4SS 527a LuaUFunction.hpp: DynamicUnrealFunctionData.data[0x200].
    LuaUObject.cpp call_ufunction_from_lua reuses the supplied out-array table;
    UObject property reads/writes use property pushers, not ProcessEvent.
    IsValid/IsA/GetAddress/GetFullName are UE4SS wrapper methods.

    BoatMovementComponent is CPF_Deprecated. Boats have no reflected MaxSpeed.
    Speed here scales the per-instance rotor RotationSpeedToLinearSpeed FLOAT
    (VoyageModuleRotorActor, offset 0x314); original values are read back/restored.
    This is an actuator conversion factor, NOT proof of proportional actual speed.
    The native rotor physics implementation is not in the supplied source.
    No changes to resource production, time dilation, CDOs or other vehicles.

    Repair uses actual durability deltas, plus attached destructible components
    using OverrideHealth with the scalar
    DestructibleObjectProperties.Health read directly. Never pass the 0x320-byte
    properties struct to a UFunction. Repair is a one-shot gameplay change, not an
    undoable toggle. Destroyed/unloaded actors cannot be recreated by this module.
    Lua mock + reflection checks do not constitute a test in the running game.
]]

local core = require("core")
local M = {}
local outfit=require("features.boat_outfit")
local BOAT = "/Script/Voyage.VoyageBoatPawn"
local ROTOR = "/Script/Voyage.VoyageModuleRotorActor"
local MODULE = "/Script/Voyage.VoyageModuleComponent"
local DAMAGE = "/Script/Voyage.VoyageDestructibleObjectComponent"
local SPEED_FIELD = "RotationSpeedToLinearSpeed"
local FACTORS = { 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4 }
local RANGE = 10000 -- cm: nearest boat must be within 100 m, in this world.
local MAX_ITEMS, WORK_PER_TICK = 2048, 12
local DISCOVERY_PER_TICK = 2 -- at most four local component enumerations per tick.
local S = { index = 3, active = false, saved = {}, status = tr("Noch kein Boot gewaehlt") }
local uiRef

local function finite(n)
    return type(n) == "number" and n == n and math.abs(n) < math.huge
end

local function close(a, b)
    return finite(a) and finite(b) and math.abs(a - b) <= math.max(0.000001, math.abs(b) * 0.000001)
end

local function read(o, key)
    if not core.isValid(o) then return nil end
    local ok, value = pcall(function() return o[key] end)
    if ok then return value end
end

local function call(o, method, ...)
    if not core.isValid(o) then return false, nil end
    local args = table.pack(...)
    return pcall(function() return o[method](o, table.unpack(args, 1, args.n)) end)
end

local function isa(o, class)
    local ok, yes = call(o, "IsA", class)
    return ok and yes == true
end

local function identity(o)
    if not core.isValid(o) then return nil end
    local address = core.address(o)
    local name = core.fullName(o)
    if address == nil or address == 0 or name == "?" then return nil end
    return tostring(address) .. "|" .. name
end

local function live(actor)
    local ok, destroying = call(actor, "IsActorBeingDestroyed")
    return ok and destroying == false
end

local function worldOf(actor)
    local ok, level = call(actor, "GetLevel")
    return ok and identity(read(level, "OwningWorld")) or nil
end

local function say(text, good)
    S.status = text
    core.log("Boat: " .. text)
    if uiRef then uiRef.toast(text, good and "good" or "bad") end
end

-- Unlike core.outList, propagate failure and distinguish it from an empty array.
local function array(value)
    -- UFunction return/out arrays are Lua tables whose elements are UE4SS
    -- RemoteUnrealParam wrappers, not bare UObjects. Property arrays are TArray.
    if type(value) == "table" then
        if #value > MAX_ITEMS then return nil end
        local result = {}
        for i, item in ipairs(value) do result[i] = core.unwrap(item) end
        return result
    end
    local ok, count = pcall(function() return value:GetArrayNum() end)
    if not ok or not finite(count) or count < 0 or count > MAX_ITEMS then return nil end
    local result = {}
    for i = 1, count do
        local got, item = pcall(function() return core.unwrap(value[i]) end)
        if not got then return nil end
        result[i] = item
    end
    return result
end

local function outArray(o, fn, name, ...)
    local holder = {}
    local ok, ret = call(o, fn, holder, ...)
    if not ok then return nil end
    return array(ret) or array(holder[name]) or array(holder)
end

local function attachedTo(actor, boat)
    local goal = identity(boat)
    if not goal then return false end
    local seen = {}
    for _ = 1, 32 do
        local id = identity(actor)
        if not id or seen[id] then return false end
        if id == goal then return true end
        seen[id] = true
        local ok, parent = call(actor, "GetAttachParentActor")
        if not ok then return false end
        actor = parent
    end
    return false -- bounded traversal, including malformed attachment cycles.
end

local function withinScope(boat, pawn)
    if attachedTo(pawn, boat) then return true end
    local x, y, z = core.location(pawn)
    local a, b, c = core.location(boat)
    if not (finite(x) and finite(y) and finite(z) and finite(a) and finite(b) and finite(c)) then return false end
    return (x-a)^2 + (y-b)^2 + (z-c)^2 <= RANGE^2
end

local function setScalar(actor, value)
    if not core.isValid(actor) or not finite(value) or math.abs(value) > 3.402823466e38 then return false end
    local ok = pcall(function() actor[SPEED_FIELD] = value end)
    return ok and close(read(actor, SPEED_FIELD), value)
end

-- Retain failed restores for retry; do not silently forget an altered live rotor.
-- A conflicting external edit is reported, and is never overwritten.
local function restore()
    S.active = false
    local pending, restored, conflicts, lost = {}, 0, 0, 0
    for _, item in ipairs(S.saved) do
        if identity(item.actor) ~= item.id then
            lost = lost + 1
        else
            local now = read(item.actor, SPEED_FIELD)
            if close(now, item.original) then
                restored = restored + 1
            elseif not finite(now) then
                pending[#pending+1] = item
            elseif not close(now, item.applied) then
                conflicts = conflicts + 1
            elseif setScalar(item.actor, item.original) then
                restored = restored + 1
            else
                pending[#pending+1] = item
            end
        end
    end
    S.saved = pending
    if #pending == 0 then S.restoreWorld = nil end
    return #pending == 0 and conflicts == 0, string.format(
        tr("%d Rotorwerte restauriert; %d offen, %d externe Aenderungen, %d ungueltig"),
        restored, #pending, conflicts, lost)
end

local function cancel(reason)
    outfit.cancel()
    local hadWork = S.active or S.job ~= nil or #S.saved > 0
    local _, result = restore()
    local repair = S.job and string.format(tr("; Reparatur abgebrochen nach %d bestaetigten Reparaturen"), S.job.fixed) or ""
    S.job, S.target, S.targetID, S.context, S.world = nil, nil, nil, nil, nil
    S.targetName = nil
    if hadWork then say(reason .. "; " .. result .. repair, false) else S.status = reason end
end

-- This callback may arrive AFTER Unreal has unloaded the old world. In particular,
-- do not call IsValid, GetAddress, or restore() on ANY saved wrapper here.
local function forgetWorld(reason)
    outfit.onWorldChanged()
    local count = #S.saved
    local fixed = S.job and S.job.fixed or 0
    S.active, S.saved, S.job = false, {}, nil
    S.target, S.targetID, S.context, S.world, S.restoreWorld = nil, nil, nil, nil, nil
    S.targetName = nil
    S.index = 3
    S.status = reason
    core.log(string.format(tr("Boat: %s; %d alte Rotorreferenzen verworfen; %d bestaetigte Reparaturen vor Abbruch"),
        reason, count, fixed))
end

local function context()
    local pc, pawn = core.pc(), core.pawn()
    local a, b, w = identity(pc), identity(pawn), worldOf(pawn) or worldOf(pc)
    if not a or not b or not w or not live(pawn) then return nil, pawn, w end
    return a .. ":" .. b .. ":" .. w, pawn, w
end

local function validate()
    local ctx, pawn, world = context()
    if (S.world or S.restoreWorld) and (S.world or S.restoreWorld) ~= world then forgetWorld(tr("Welt gewechselt"))
    elseif S.context and S.context ~= ctx then cancel(tr("Spieler gewechselt")) end
    if not ctx then return nil end
    if S.target and (identity(S.target) ~= S.targetID or not live(S.target)
        or worldOf(S.target) ~= world or not withinScope(S.target, pawn)) then
        cancel(tr("Boot ungueltig oder ausserhalb des 100-m-Bereichs"))
    end
    return ctx, pawn, world
end

local function choose()
    outfit.cancel()
    local ctx, pawn, world = validate()
    if not ctx then say(tr("Kein gueltiger Spieler in einer Welt"), false) return false end
    if S.job then say(tr("Reparatur laeuft; Bootwahl danach moeglich"), false) return false end
    local ok, result = restore()
    S.job, S.target, S.targetID = nil, nil, nil
    S.targetName = nil
    if not ok then say(tr("Bootwechsel gestoppt: ") .. result, false) return false end
    -- First the possessed boat, then the pawn's physical attachment parents.
    local target, parent, seen = nil, pawn, {}
    for _ = 1, 32 do
        local id = identity(parent)
        if not id or seen[id] then break end
        seen[id] = true
        if isa(parent, BOAT) and live(parent) and worldOf(parent) == world then target = parent break end
        local got, nextParent = call(parent, "GetAttachParentActor")
        if not got then break end
        parent = nextParent
    end
    -- One world-scoped actor enumeration, only on an explicit action; never in tick.
    if not target then
        local x, y, z = core.location(pawn)
        if finite(x) and finite(y) and finite(z) then
            local best = RANGE^2
            for _, boat in ipairs(core.actorsOf(BOAT)) do
                if isa(boat, BOAT) and live(boat) and worldOf(boat) == world then
                    local a, b, c = core.location(boat)
                    if finite(a) and finite(b) and finite(c) then
                        local distance = (x-a)^2 + (y-b)^2 + (z-c)^2
                        if distance <= best then target, best = boat, distance end
                    end
                end
            end
        end
    end
    if not target then say(tr("Kein Boot im Spielerbezug oder innerhalb von 100 m"), false) return false end
    S.target, S.targetID, S.context, S.world = target, identity(target), ctx, world
    S.targetName = core.shortName(target)
    say(tr("Ziel: ") .. S.targetName .. tr(" (nur dieses Boot)"), true)
    return true
end

local function targetForAction()
    validate()
    if not S.target and not choose() then return nil end
    local ok, authority = call(S.target, "HasAuthority")
    if not ok or authority ~= true then say(tr("Boot kann hier nicht geaendert werden (nur Host)"), false) return nil end
    return S.target
end

-- Native boat membership + physical attachments. The second list also finds
-- broken modules omitted by gameplay filtering. No FindAllOf(Module) world scan.
local function collect(boat)
    local modules = outArray(boat, "GetAllModules", "Modules")
    local actors = outArray(boat, "GetAttachedActors", "OutActors", true, true)
    if not modules or not actors or #modules > MAX_ITEMS or #actors >= MAX_ITEMS then return nil end
    local items, seenModules, seenActors = {}, {}, {}
    local function add(kind, object, seen)
        local id = identity(object)
        if id and not seen[id] then
            seen[id] = true
            items[#items+1] = { kind = kind, object = object, id = id }
        end
    end
    add("actor", boat, seenActors)
    for _, actor in ipairs(actors) do add("actor", core.unwrap(actor), seenActors) end
    for _, module in ipairs(modules) do add("module", core.unwrap(module), seenModules) end
    if #items > MAX_ITEMS then return nil end
    return items
end

local function applySpeed()
    local boat = targetForAction()
    if not boat then return false end
    local ok, result = restore()
    if not ok then say(tr("Antrieb gestoppt: ") .. result, false) return false end
    local items = collect(boat)
    if not items then say(tr("Boot-Module konnten nicht vollstaendig gelesen werden"), false) return false end
    local seen, records = {}, {}
    for _, item in ipairs(items) do
        local actor = item.object
        if item.kind == "module" then local _, owner = call(actor, "GetOwner") actor = owner end
        local id = identity(actor)
        if id and not seen[id] and isa(actor, ROTOR) and live(actor) and attachedTo(actor, boat) then
            seen[id] = true
            local value = read(actor, SPEED_FIELD)
            if not finite(value) or value <= 0 or value * FACTORS[S.index] > 3.402823466e38 then
                say(tr("Rotor hat keinen gueltigen Geschwindigkeitsfaktor; nichts angewandt"), false) return false
            end
            records[#records+1] = { actor = actor, id = id, original = value, applied = value * FACTORS[S.index] }
        end
    end
    if #records == 0 then say(tr("Kein unterstuetzter, physisch angebauter Boot-Rotor gefunden"), false) return false end
    for _, item in ipairs(records) do
        -- Record BEFORE attempting the write, including a write that throws after mutation.
        S.saved[#S.saved+1] = item
        S.restoreWorld = S.world
        if not setScalar(item.actor, item.applied) then
            local _, rollback = restore()
            say(tr("Antriebswert nicht bestaetigt; ") .. rollback, false)
            return false
        end
    end
    S.active, S.checkIndex = true, 1
    say(string.format(tr("Antriebsfaktor %.2fx: %d Rotorwerte bestaetigt"), FACTORS[S.index], #records), true)
    return true
end

local function stopSpeed()
    validate()
    local ok, result = restore()
    say(result, ok)
end

local function startRepair(mode)
    local boat = targetForAction()
    if not boat then return end
    if S.job then say(tr("Reparatur laeuft bereits"), false) return end
    local items = collect(boat)
    if not items then say(tr("Reparatur nicht gestartet: Boot-Module nicht vollstaendig lesbar"), false) return end
    local cls, damageCls = core.find(MODULE), core.find(DAMAGE)
    if not cls or not damageCls then say(tr("Reparaturdaten fehlen; nicht gestartet"), false) return end
    S.job = { mode = mode or "repair", items = items, next = 1, moduleClass = cls, damageClass = damageCls, seen = {}, checked = 0,
        fixed = 0, fixedModules = 0, fixedParts = 0, healthy = 0, partial = 0, failed = 0, skipped = 0, errors = 0 }
    say((mode == "refill" and tr("Auffuellen gestartet: ") or tr("Reparatur gestartet: ")) .. core.shortName(boat), true)
end

local function health(object)
    local before = read(object, "Health")
    local ok, maximum = pcall(function() return object.DestructibleObjectProperties.Health end)
    return before, ok and maximum or nil
end

local function markSharedDamage(job, module)
    local damage = read(module, "DestructibleObjectReference")
    if not isa(damage, DAMAGE) then return end
    local before, maximum = health(damage)
    -- Only deduplicate damage already confirmed fully healthy. Separate damage
    -- components remain in the queue and are repaired independently.
    if finite(before) and finite(maximum) and maximum > 0 and before >= maximum then
        local id = identity(damage)
        if id then job.seen[id] = true end
    end
end

local function repairOne(job, object, kind)
    local id = identity(object)
    if not id then job.skipped = job.skipped + 1 return end
    if job.seen[id] then return end
    job.seen[id] = true
    if job.mode == "refill" then
        if kind ~= "module" then return end
        local got, resource = call(object, "GetPrimaryResourceType")
        local a, current = call(object, "GetResourceAmount", resource)
        local b, maximum = call(object, "GetMaxResourceAmount", resource)
        if not got or not a or not b or not finite(current) or not finite(maximum) then
            job.failed = job.failed + 1; return
        end
        job.checked = job.checked + 1
        if maximum <= 0 or current >= maximum then job.healthy = job.healthy + 1; return end
        local ok = call(object, "ForceAddResource", resource, maximum - current)
        local readOK, after = call(object, "GetResourceAmount", resource)
        if ok and readOK and close(after, maximum) then
            job.fixed, job.fixedModules = job.fixed + 1, job.fixedModules + 1
        else job.failed = job.failed + 1 end
        return
    end
    local before, maximum
    if kind == "module" then
        local ok1, value = call(object, "GetDurability")
        local ok2, max = call(object, "GetMaxDurability")
        if ok1 and ok2 then before, maximum = value, max end
    else
        before, maximum = health(object)
    end
    if not finite(before) or not finite(maximum) or maximum <= 0 or before < 0 then
        job.failed = job.failed + 1 return
    end
    job.checked = job.checked + 1
    if before >= maximum then
        job.healthy = job.healthy + 1
        if kind == "module" then markSharedDamage(job, object) end
        return
    end
    local ok
    if kind == "module" then ok = call(object, "Repair", maximum - before)
    else ok = call(object, "OverrideHealth", maximum) end
    local after
    if kind == "module" then local got, value = call(object, "GetDurability") if got then after = value end
    else after = read(object, "Health") end
    if ok and finite(after) and after > before and close(after, maximum) then
        job.fixed = job.fixed + 1
        if kind == "module" then job.fixedModules = job.fixedModules + 1
        else job.fixedParts = job.fixedParts + 1 end
    elseif ok and finite(after) and after > before then job.partial = job.partial + 1
    else job.failed = job.failed + 1 end
    if kind == "module" then markSharedDamage(job, object) end
end

local function repairTick()
    local job, boat = S.job, S.target
    if not job then return end
    local ok, authority = call(boat, "HasAuthority")
    if not ok or authority ~= true then cancel(tr("Boot kann hier nicht mehr geaendert werden")) return end
    local work, discoveries = 0, 0
    while work < WORK_PER_TICK and job.next <= #job.items do
        work = work + 1
        local item = job.items[job.next]
        if item.kind == "actor" and discoveries >= DISCOVERY_PER_TICK then break end
        job.next = job.next + 1
        local object = item.object
        local good = identity(object) == item.id
        if item.kind == "actor" then
            discoveries = discoveries + 1
            if good and live(object) and attachedTo(object, boat) then
                for _, spec in ipairs({ { "module", job.moduleClass }, { "damage", job.damageClass } }) do
                    local got, components = call(object, "K2_GetComponentsByClass", spec[2])
                    components = got and array(components) or nil
                    if not components then job.errors = job.errors + 1
                    else
                        for _, component in ipairs(components) do
                            component = core.unwrap(component)
                            if #job.items < MAX_ITEMS then
                                job.items[#job.items+1] = { kind = spec[1], object = component, id = identity(component) }
                            else job.errors = job.errors + 1 break end
                        end
                    end
                end
            else job.skipped = job.skipped + 1 end
        else
            local got, owner = call(object, "GetOwner")
            local expected = item.kind == "module" and MODULE or DAMAGE
            if good and isa(object, expected) and got and live(owner) and attachedTo(owner, boat) then
                repairOne(job, object, item.kind)
            else job.skipped = job.skipped + 1 end
        end
    end
    S.status = string.format(tr("%s: %d/%d Eintraege; %d bestaetigt"),
        job.mode == "refill" and tr("Auffuellen") or tr("Reparatur"), job.next-1, #job.items, job.fixed)
    if job.next > #job.items then
        S.job = nil
        say(string.format((job.mode == "refill" and tr("Aufgefuellt") or tr("Repariert")) .. tr(": %d Module, %d Bauteile. Intakt: %d; teilweise: %d; fehlgeschlagen: %d; uebersprungen: %d; Lesefehler: %d"),
            job.fixedModules, job.fixedParts, job.healthy, job.partial, job.failed, job.skipped, job.errors),
            job.partial == 0 and job.failed == 0 and job.skipped == 0 and job.errors == 0)
    end
end

function M.tick()
    outfit.tick()
    if not S.context and not S.job and not S.active and #S.saved == 0 then return end
    validate()
    -- No actor enumeration here. Check one saved rotor per tick; detached rotors
    -- stop the session and restore all snapshots, without choosing another boat.
    if S.active then
        local item = S.saved[S.checkIndex or 1]
        local ok, authority = call(S.target, "HasAuthority")
        if not item or not ok or authority ~= true or identity(item.actor) ~= item.id
            or not live(item.actor) or not attachedTo(item.actor, S.target)
            or not close(read(item.actor, SPEED_FIELD), item.applied) then
            cancel(tr("Antriebsbindung oder Rotorwert geaendert"))
        else S.checkIndex = (S.checkIndex or 1) % #S.saved + 1 end
    elseif #S.saved > 0 then
        local ok, result = restore()
        if #S.saved == 0 then say(tr("Wiederherstellung: ") .. result, ok) end
    end
    repairTick()
end

function M.onWorldChanged()
    forgetWorld(tr("Boot-Sitzung beendet: Weltwechsel"))
end

function M.addToPage(ui, page, parent)
    uiRef = ui
    local card = ui.card(parent, tr("Boot"))
    ui.infoRow(page, card, tr("Zielboot"), function()
        return S.targetName or tr("Keines")
    end)
    ui.infoRow(page,card,tr("Motorleistung"),function()
        if not S.target then return tr("Boot waehlen") end
        local ok,value=call(S.target,"GetTotalEnginePower")
        return ok and finite(value) and string.format("%.1f",value) or "-"
    end)
    ui.button(card, tr("Boot waehlen"), "action", choose)
    ui.add(card, ui.paragraph(tr("Spielerboot oder naechstes Boot bis 100 m. Auswahl bleibt fest.")))
    ui.stepperRow(page, card, tr("Tempo"), {
        values = FACTORS, index = function() return S.index end,
        format = function(value) return string.format("%.2fx", value) end,
        set = function(i)
            if not finite(i) or i % 1 ~= 0 or not FACTORS[i] then return end
            S.index = i
            if S.active then applySpeed() end
        end,
    })
    ui.toggleRow(page, card, tr("Tempo aktiv"), function() return S.active end,
        function(on) if on then applySpeed() else stopSpeed() end end, tr("Antriebsfaktor, nur diese Sitzung"))
    ui.buttonGrid(card, 2, {
        { tr("Originaltempo"), stopSpeed }, { tr("Alles reparieren"), function() startRepair() end, "primary" },
        { tr("Tanks & Batterien fuellen"), function() startRepair("refill") end },
        { tr("Zum Zielboot"), function()
            local boat = targetForAction()
            if not boat then return end
            local x,y,z = core.location(boat)
            if not (finite(x) and finite(y) and finite(z)) then return end
            local ok, message = require("features.teleport").teleport(x,y,z+300,core.yaw(boat),tr("Zielboot"))
            say(message, ok)
        end },
    })
    local function anchor(up)
        local boat = targetForAction()
        if not boat then return end
        local ok = call(boat, up and "LiftAnchors" or "DropAnchors")
        local confirmed = ok and read(boat,"AnchorsDropped") == not up
        say(confirmed and (up and tr("Anker gelichtet") or tr("Anker gesetzt")) or tr("Ankerzustand nicht bestaetigt"), confirmed)
    end
    ui.buttonGrid(card, 2, {
        { tr("Anker lichten"), function() anchor(true) end },
        { tr("Anker setzen"), function() anchor(false) end },
    })
    ui.add(card, ui.paragraph(tr("Repariert vorhandene Bauteile und Module dauerhaft.")))
    local status = ui.paragraph(S.status)
    ui.add(card, status)
    local last
    ui.addRefresher(page, function()
        if last ~= S.status then ui.setText(status, S.status) last = S.status end
    end)
    return card
end

local CYLINDER_TYPES = {"Electric", "Diesel", "Petrol"}
local CYLINDER_LEVELS = {"", "_Eco", "_Booster", "_SuperBooster", "_CheatBooster"}
function M.giveCylinder(kind, level, count)
    if not CYLINDER_TYPES[kind] or not CYLINDER_LEVELS[level]
        or not finite(count) or count%1~=0 or count<1 or count>50 then
        return false,tr("Ungueltige Zylinderauswahl")
    end
    -- The old developer retrofit destroys owners of EVERY connected engine
    -- socket, including the boat hull. Never call it, even for basic cylinders.
    local name="DA_Item_"..CYLINDER_TYPES[kind].."EngineCylinder"..CYLINDER_LEVELS[level]
    local packages=require("features.packages")
    local item=packages.load("/Game/Data/Assets/Items/"..name.."."..name)
    if not item then return false,tr("Motorzylinder nicht geladen") end
    local amount,reason=packages.give(item,count,1)
    return amount==count,string.format(tr("%d/%d Zylinder ins Inventar%s"),amount,count,reason and (": "..reason) or "")
end

function M.page(ui)
    local page = ui.newPage(tr("Boot"))
    M.addToPage(ui, page, page.left)
    local engines=ui.card(page.right,tr("Motoren ausruesten"),tr("Direkt am ausgewaehlten Boot"))
    local choices={tr("Basis"),"Eco","Booster","Super-Booster"}
    local level=1
    ui.stepperRow(page,engines,tr("Zylindervariante"),{
        values=choices,index=function() return level end,format=tostring,
        set=function(i) if choices[i] then level=i end end,
    })
    ui.button(engines,tr("Boot ausruesten"),"primary",function()
        local boat=targetForAction();if not boat then return end
        local ok,msg=outfit.start(boat,level,say);say(msg,ok)
    end)
    ui.button(engines,tr("Ausstattung beenden"),"action",outfit.cancel)
    ui.button(engines,tr("Motoranschluesse pruefen"),"action",function()
        local boat=targetForAction();if not boat then return end
        local ok,msg=outfit.inspect(boat);say(msg,ok)
    end)
    ui.infoRow(page,engines,tr("Anschluesse"),outfit.status)
    ui.add(engines,ui.paragraph(tr("Diesel- und Elektromotoren: passende Zylinder werden an jedem Motoranschluss eingesetzt. Bestehende Zylinder werden ersetzt; andere Anbauteile bleiben erhalten. Anschluss wird einzeln geprueft.")))
    local navigation = ui.card(page.right, tr("Boot bergen & steuern"))
    ui.button(navigation, tr("Boot aufrichten"), "action", function()
        local boat = targetForAction()
        if not boat then return end
        local ok = call(boat, "AddUprightForce", 1.0)
        say(ok and tr("Aufrichtimpuls angewandt") or tr("Aufrichten fehlgeschlagen"), ok)
    end)
    ui.add(navigation, ui.paragraph(tr("Aufrichtimpuls fuer das gewaehlte Boot. Bei Bedarf erneut ausloesen.")))
    ui.button(navigation, tr("Bootsteuerung uebernehmen"), "action", function()
        local boat=targetForAction()
        if not boat then return end
        local _,driver=call(boat,"GetDriver")
        if core.isValid(driver) then say(tr("Dieses Boot hat bereits einen Fahrer"),false);return end
        local ok,err=call(boat,"OnEnterVehicle",core.pc())
        local pawn = core.pawn()
        local success = ok and identity(pawn)==identity(boat)
        if success then ui.hide() end
        say(success and tr("Bootsteuerung aktiv; normale Aussteigen-Taste verwenden")
            or tr("Bootsteuerung nicht uebernommen: ") .. tostring(err), success)
    end)
    ui.add(navigation, ui.paragraph(tr("Steuerung des ausgewaehlten Boots; normale Aussteigen-Taste verwenden.")))
    return page
end

return M
