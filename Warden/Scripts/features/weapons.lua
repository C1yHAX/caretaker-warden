local tr = require("i18n").t
--[[
    Player-holster weapons, TLC 0.10.0.653173 / UE 5.8.2.

    Integration: require this module at mod startup (RegisterHook is unavailable in
    UE4SS game-thread callbacks). Add page(ui), call tick() on the game thread,
    onWorldChanged() on travel, and reset() for panic/shutdown while objects live.
    No settings, timers, asset loads, CDO edits or world-wide actor searches.

    Audited against reference/CXXHeaderDump-0.10.0.653173/Voyage.hpp and the JMAP:
      VoyagePlayerController.GetWeaponHolsterComponent                 8 bytes
      VoyageWeaponHolsterComponent.GetActiveSlotActor(bool)           16
      VoyageWeaponHolsterComponent.GetSlotActors(out TMap)            80
      VoyageWeaponHolsterComponent.GetSlotActor(int32)                16
      VoyageEquipmentActor.GetOwnerController                         8
      VoyageWeaponBallistic.GetCurrentAmmo / GetAttachedWeaponMagazine 8 each
      VoyageWeaponBallistic.GetMagazineSize / GetCurrentAmmoAmount     4 each
      VoyageWeaponBallistic.IsReloading                               1
      VoyageWeaponBallistic.SetAmmoAmount(int32), INCLUDING return     8
      VoyageWeaponBallistic.OnAmmoCountChanged(int32, int32) hook      8
      VoyageWeaponResource.ModuleValuesChanged(Module*) hook          8
      VoyageModuleComponent.GetResourceAmount / GetMaxResourceAmount  16 each
      VoyageModuleComponent.ForceAddResource / RemoveResource         24 each
      ActorComponent.GetOwner                                        8
      Actor.IsActorBeingDestroyed                                     1
      VoyageMiscBlueprintFunctionLibrary.GetActorWorld(Actor*)        16
    UObject IsA/IsValid/GetAddress/GetFullName are UE4SS bindings. Do not depend
    on GetWorld (not verified against the 527a wrapper header).

    UE4SS LuaUFunction.hpp uses data[0x200]; LuaUObject.cpp marshals return
    properties into that same buffer. GetWeaponData[Mutable] is NEVER called:
    FVoyageWeaponDataStruct alone is 0x460 bytes. No soft pointer parameters.
    Bool/int instance properties use UE4SS's reflected property setters.
    LuaMod.cpp supplies RemoteUnrealParam context/arguments to native pre-hooks.

    Overheat uses the actual bUseActivationCooldown switch (true on the dumped
    BP_Weapon_Flamethrower CDO). It does not fake cooldown/animation callbacks.
    Resources refills all player-holster magazines and every positive-capacity
    resource in each resource weapon's module, not only Petrol/Electricity.
    No Reload additionally holds the magazine at capacity in the native ammo
    notification, without recursive SetAmmoAmount calls. Native caller ordering
    and Blueprint override behavior still require an in-game test. Existing or
    manually started reload animations are NOT forcibly completed/cancelled.

    Snapshots restore on disable, removal from the holster, or pawn changes.
    Ammo snapshots are scoped to the exact ammo/magazine pair. Changed pairs are
    never overwritten with an old count. World teardown discards stale handles.
    Refills are real game state: saves/transfers while enabled cannot be undone
    by a Lua-session snapshot. No in-game validation is claimed by this file.
]]

local core = require("core")
local M = {}
local S = { noOverheat = false, infiniteResources = false, noReload = false }
M.state = S

local HOOK = "/Script/Voyage.VoyageWeaponBallistic:OnAmmoCountChanged"
local tracked, busy = {}, false
local hookReady, resourceHookReady, hookAttempted = false, false, false
local RESOURCE_HOOK = "/Script/Voyage.VoyageWeaponResource:ModuleValuesChanged"
local status = tr("Aus")

local function warn(key, message)
    status = message
    core.logOnce("weapons." .. key, tr("Waffen: ") .. message)
end

local function call(label, fn)
    local ok, result = pcall(fn)
    if not ok then
        warn(label, label .. tr(" fehlgeschlagen: ") .. tostring(result))
        return nil
    end
    return result
end

local function number(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

local function identity(o)
    if not core.isValid(o) then return nil end
    local address, name = core.address(o), core.fullName(o)
    if address == nil or address == 0 or name == "?" then return nil end
    return tostring(address) .. ":" .. name
end

local function same(o, key)
    return key ~= nil and identity(o) == key
end

local function worldOf(o)
    if not core.isValid(o) then return nil end
    local lib = core.lib("misc")
    if lib == nil then
        warn("worldLibrary", tr("Spielwelt nicht lesbar; Waffenfunktionen warten"))
        return nil
    end
    return call("GetActorWorld", function() return lib:GetActorWorld(o) end)
end

local function isA(o, name)
    return core.isValid(o) and call("IsA " .. name, function()
        return o:IsA("/Script/Voyage." .. name)
    end) == true
end

local function liveActor(o)
    return core.isValid(o) and call("IsActorBeingDestroyed", function()
        return o:IsActorBeingDestroyed()
    end) == false
end

local function context()
    local pc, pawn = core.pc(), core.pawn()
    if not liveActor(pc) then return nil end
    local worldKey = identity(worldOf(pc))
    if worldKey == nil then return nil end
    return { pc = pc, pcKey = identity(pc), pawn = pawn,
        pawnKey = identity(pawn), worldKey = worldKey }
end

local function canRestore(r, ctx)
    return ctx ~= nil and ctx.worldKey == r.worldKey
        and same(r.weapon, r.key) and liveActor(r.weapon)
        and identity(worldOf(r.weapon)) == r.worldKey
end

local function writeProperty(o, name, value)
    local ok, err = pcall(function() o[name] = value end)
    if not ok then
        warn(name, name .. tr(" konnte nicht gesetzt werden: ") .. tostring(err))
        return false
    end
    return call(tr("Lesen ") .. name, function() return o[name] end) == value
end

-- Store before writing, including false values; keep failed restores for retry.
local function flag(r, name, enabled)
    local old = r.flags[name]
    if enabled then
        if old == nil then
            old = call(tr("Lesen ") .. name, function() return r.weapon[name] end)
            if type(old) ~= "boolean" then return false end
            r.flags[name] = old
        end
        if call(tr("Lesen ") .. name, function() return r.weapon[name] end) == false then return true end
        return writeProperty(r.weapon, name, false)
    end
    if old == nil then return true end
    if writeProperty(r.weapon, name, old) then
        r.flags[name] = nil
        return true
    end
    return false
end

local function ammoState(w)
    local ammo = call("GetCurrentAmmo", function() return w:GetCurrentAmmo() end)
    local magazine = call("GetAttachedWeaponMagazine", function() return w:GetAttachedWeaponMagazine() end)
    local a, m = identity(ammo), identity(magazine)
    if a == nil or m == nil then return nil end
    local capacity = call("GetMagazineSize", function() return w:GetMagazineSize() end)
    local count = call("GetCurrentAmmoAmount", function() return w:GetCurrentAmmoAmount() end)
    if not number(capacity) or capacity <= 0 or capacity % 1 ~= 0 or capacity > 2147483647
        or not number(count) or count < 0 or count % 1 ~= 0 then return nil end
    return { pair = a .. "|" .. m, capacity = capacity, count = count }
end

local function restoreAmmo(r)
    if r.ammo == nil then return true end
    local now = ammoState(r.weapon)
    if now == nil or now.pair ~= r.ammo.pair then
        warn("ammoPair", tr("Munition/Magazin gewechselt; alten Füllstand nicht übertragen"))
        r.ammo = nil
        return true
    end
    local target = math.min(r.ammo.original, now.capacity)
    if now.count ~= target then
        local result = call("SetAmmoAmount restore", function() return r.weapon:SetAmmoAmount(target) end)
        local count = call("GetCurrentAmmoAmount restore", function() return r.weapon:GetCurrentAmmoAmount() end)
        if result ~= true or count ~= target then return false end
    end
    r.ammo = nil
    return true
end

local function refillAmmo(r, inHook, newCount)
    -- Do not interfere with the engine's reload timer or pending inventory debit.
    local reloading = call("IsReloading", function() return r.weapon:IsReloading() end)
    if reloading ~= false then
        status = tr("Warte auf Ende des Nachladens")
        return false
    end
    local now = ammoState(r.weapon)
    if now == nil then
        status = tr("Passende Munition und Magazin erforderlich")
        return false
    end
    if r.ammo == nil or r.ammo.pair ~= now.pair then
        r.ammo = { pair = now.pair, original = now.count }
    end
    if now.count == now.capacity then return true end
    if inHook then
        -- A property write cannot recursively emit the same native notification.
        -- Pass the held count to the notification's original implementation too.
        if not writeProperty(r.weapon, "CurrentAmmoCount", now.capacity) then return false end
        local ok, err = pcall(function() newCount:set(now.capacity) end)
        if not ok then warn("hookParam", tr("Munitionsanzeige: ") .. tostring(err)) end
        return true
    end
    local result = call("SetAmmoAmount", function() return r.weapon:SetAmmoAmount(now.capacity) end)
    return result == true and call("GetCurrentAmmoAmount verify", function()
        return r.weapon:GetCurrentAmmoAmount()
    end) == now.capacity
end

local function resourceValue(module, kind)
    local value = call("GetResourceAmount", function() return module:GetResourceAmount(kind) end)
    return number(value) and value >= 0 and value or nil
end

local function resourceCapacity(module, kind)
    local value = call("GetMaxResourceAmount", function() return module:GetMaxResourceAmount(kind) end)
    return number(value) and value > 0 and value or nil
end

local function restoreResource(r)
    local saved = r.resource
    if saved == nil then return true end
    local module = saved.module
    if not same(module, saved.key) then r.resource = nil return true end
    local owner = call("GetOwner", function() return module:GetOwner() end)
    if not same(owner, r.key) then r.resource = nil return true end
    local ok = true
    for kind, original in pairs(saved.values) do
        local amount, capacity = resourceValue(module, kind), resourceCapacity(module, kind)
        if amount == nil or capacity == nil then
            ok = false
        else
            local target = math.min(original, capacity)
            if amount > target then
                -- Transfer=2, not Consumption (which may apply efficiency modifiers).
                call("RemoveResource restore", function() return module:RemoveResource(kind, amount - target, 2) end)
            elseif amount < target then
                call("ForceAddResource restore", function() return module:ForceAddResource(kind, target - amount) end)
            end
            local after = resourceValue(module, kind)
            if after ~= nil and math.abs(after - target) <= 0.0001 then
                saved.values[kind] = nil
            else
                ok = false
            end
        end
    end
    if ok then r.resource = nil end
    return ok
end

local function refillResource(r, inHook)
    local module = call("ModuleComponent", function() return r.weapon.ModuleComponent end)
    local key = identity(module)
    if key == nil then return false end
    if not isA(module, "VoyageCustomModuleComponent") then return false end
    if not same(call("GetOwner", function() return module:GetOwner() end), r.key) then return false end
    if r.resource and r.resource.key ~= key then
        if inHook then return false end
        if not restoreResource(r) then return false end
    end
    if r.resource == nil then
        if inHook then return false end
        r.resource = { module = module, key = key, values = {} }
        r.discover = 0
    end
    if not inHook then
        if r.discover == 0 then
            -- Small local capability sweep on bind and every fourth tick; no
            -- global scans. Unknown=14/Count=18/MAX=19 are not resource stores.
            for kind = 0, 17 do
                if kind ~= 14 and r.resource.values[kind] == nil and resourceCapacity(module, kind) then
                    r.resource.values[kind] = resourceValue(module, kind)
                end
            end
        end
        r.discover = (r.discover + 1) % 4
    end
    local ok = next(r.resource.values) ~= nil
    for kind in pairs(r.resource.values) do
        local amount, capacity = resourceValue(module, kind), resourceCapacity(module, kind)
        if amount == nil or capacity == nil then
            ok = false
        elseif amount < capacity then
            call("ForceAddResource", function() return module:ForceAddResource(kind, capacity - amount) end)
            local after = resourceValue(module, kind)
            if after == nil or after < capacity - 0.0001 then ok = false end
        end
    end
    return ok
end

local function restore(r, ctx)
    if not canRestore(r, ctx) then return true end -- Never dereference a previous world.
    local ok = true
    for _, name in ipairs({ "bUseActivationCooldown", "bAutoReload" }) do
        if not flag(r, name, false) then ok = false end
    end
    if not restoreAmmo(r) then ok = false end
    if not restoreResource(r) then ok = false end
    if not ok then warn("restore", tr("Wiederherstellung unvollständig; nächster Tick versucht es erneut")) end
    return ok
end

local function enabled()
    return S.noOverheat or S.infiniteResources or S.noReload
end

local function releaseAll(ctx)
    local ok = true
    for key, r in pairs(tracked) do
        if restore(r, ctx) then tracked[key] = nil else ok = false end
    end
    return ok
end

local function playerHolster(ctx)
    if ctx == nil or not liveActor(ctx.pawn) or not isA(ctx.pawn, "VoyageBaseCharacter") then return nil end
    local h = call("GetWeaponHolsterComponent", function() return ctx.pc:GetWeaponHolsterComponent() end)
    if not core.isValid(h) then return nil end
    if not same(call("GetOwner holster", function() return h:GetOwner() end), ctx.pawnKey) then return nil end
    return h
end

local function owns(r, ctx, holster)
    if not canRestore(r, ctx) or ctx.pcKey ~= r.pcKey or ctx.pawnKey ~= r.pawnKey then return false end
    if not same(r.weapon:GetOwnerController(), ctx.pcKey) then return false end
    if r.slot ~= nil and same(holster:GetSlotActor(r.slot), r.key) then return true end
    return same(holster:GetActiveSlotActor(true), r.key)
end

local function update()
    if not enabled() and next(tracked) == nil then status = tr("Aus") return end
    local ctx = context()
    for key, r in pairs(tracked) do
        if ctx == nil or ctx.worldKey ~= r.worldKey or ctx.pcKey ~= r.pcKey
            or ctx.pawnKey ~= r.pawnKey or not same(r.weapon, r.key) then
            if not restore(r, ctx) then return end
            tracked[key] = nil
        end
    end
    if not enabled() then
        if releaseAll(ctx) then status = tr("Aus") end
        return
    end
    local holster = playerHolster(ctx)
    if holster == nil then
        releaseAll(ctx)
        status = tr("Warte auf Spielercharakter")
        return
    end
    -- GetSlotActors is only 80 bytes. The reviewed UE4SS map out pusher places a
    -- table of RemoteUnrealParam entries under holder.OutActors; unwrap NOW.
    local holder = {}
    local got, err = pcall(function() holster:GetSlotActors(holder) end)
    if not got or type(holder.OutActors) ~= "table" then
        releaseAll(ctx)
        warn("slots", tr("Spielerholster nicht lesbar: ") .. tostring(err))
        return
    end
    local found = {}
    local function add(weapon, slot)
        local key = identity(weapon)
        if key == nil or not liveActor(weapon) or not isA(weapon, "VoyageWeapon") then return end
        if not same(call("GetOwnerController", function() return weapon:GetOwnerController() end), ctx.pcKey)
            or identity(worldOf(weapon)) ~= ctx.worldKey then return end
        if found[key] == nil then found[key] = { weapon = weapon, slot = slot } end
    end
    for slot, value in pairs(holder.OutActors) do
        local index = core.unwrap(slot)
        if number(index) and index % 1 == 0 then add(core.unwrap(value), index) end
    end
    add(call("GetActiveSlotActor", function() return holster:GetActiveSlotActor(true) end), nil)
    for key, r in pairs(tracked) do
        if not found[key] then
            if not restore(r, ctx) then return end
            tracked[key] = nil
        end
    end
    local ok, count = true, 0
    status = tr("Waffen im Spielerholster")
    for key, item in pairs(found) do
        local r = tracked[key]
        if r == nil then
            r = { weapon = item.weapon, key = key, pcKey = ctx.pcKey, pawnKey = ctx.pawnKey,
                worldKey = ctx.worldKey, flags = {}, ballistic = isA(item.weapon, "VoyageWeaponBallistic"),
                resourceWeapon = isA(item.weapon, "VoyageWeaponResource") }
            tracked[key] = r
        end
        r.slot = item.slot
        count = count + 1
        if not flag(r, "bUseActivationCooldown", S.noOverheat) then ok = false end
        if r.ballistic then
            if not flag(r, "bAutoReload", S.noReload) then ok = false end
            if S.infiniteResources or S.noReload then
                if not refillAmmo(r, false) then ok = false end
            elseif not restoreAmmo(r) then ok = false end
        end
        if S.infiniteResources and r.resourceWeapon then
            if not refillResource(r, false) then ok = false end
        elseif not restoreResource(r) then ok = false end
    end
    if count == 0 then status = tr("Keine Waffen im Spielerholster")
    elseif not ok and status == tr("Waffen im Spielerholster") then status = tr("Teilweise aktiv; Werte konnten nicht bestätigt werden") end
end

function M.tick()
    if busy then return end
    busy = true
    local ok, err = pcall(update)
    busy = false
    if not ok then warn("tick", tr("Aktualisierung fehlgeschlagen: ") .. tostring(err)) end
end

local function ammoChanged(contextParam, _, newCount)
    if busy or not (S.noReload or S.infiniteResources) or next(tracked) == nil then return end
    busy = true
    local ok, err = pcall(function()
        local w = contextParam:get()
        local key = identity(w)
        local r = key and tracked[key] or nil
        if r == nil or not r.ballistic then return end
        local ctx = context()
        local holster = playerHolster(ctx)
        if holster == nil or not owns(r, ctx, holster) then return end
        refillAmmo(r, true, newCount)
    end)
    busy = false
    if not ok then warn("ammoHook", tr("Munitions-Hook fehlgeschlagen: ") .. tostring(err)) end
end

local function moduleChanged(contextParam, moduleParam)
    if busy or not S.infiniteResources or next(tracked) == nil then return end
    busy = true
    local ok, err = pcall(function()
        local key = identity(contextParam:get())
        local r = key and tracked[key] or nil
        if r == nil or not r.resourceWeapon or r.resource == nil then return end
        if not same(moduleParam:get(), r.resource.key) then return end
        local ctx = context()
        local holster = playerHolster(ctx)
        if holster == nil or not owns(r, ctx, holster) then return end
        -- Post-notification refill; busy prevents recursively refilling when the
        -- native add emits another module change. Tick remains the fallback for
        -- native paths that bypass reflected notifications (not proven by JMAP).
        refillResource(r, true)
    end)
    busy = false
    if not ok then warn("resourceHook", tr("Waffenressourcen konnten nicht aktualisiert werden: ") .. tostring(err)) end
end

-- Call only from the startup Lua state. Failed registration disables No Reload;
-- it is not silently advertised as a 250-ms approximation. Other toggles work.
function M.init()
    if hookAttempted then return hookReady end
    hookAttempted = true
    if type(RegisterHook) ~= "function" then
        warn("hook", tr("No Reload nicht verfügbar: RegisterHook fehlt"))
        return false
    end
    local ok, pre, post = pcall(RegisterHook, HOOK, ammoChanged)
    hookReady = ok and type(pre) == "number" and type(post) == "number"
    if not hookReady then warn("hook", tr("No Reload nicht verfügbar: ") .. tostring(pre)) end
    local rok, rpre, rpost = pcall(RegisterHook, RESOURCE_HOOK, function() end, moduleChanged)
    resourceHookReady = rok and type(rpre) == "number" and type(rpost) == "number"
    if not resourceHookReady then warn("resourceHookMissing", tr("Waffentanks werden nur periodisch aufgefüllt")) end
    return hookReady
end

function M.setNoOverheat(on)
    S.noOverheat = on == true
    M.tick()
    return true
end

function M.setInfiniteResources(on)
    S.infiniteResources = on == true
    M.tick()
    return true
end

function M.setNoReload(on)
    if on and not hookReady then
        status = tr("No Reload nicht verfügbar; Modul beim Modstart laden")
        return false, status
    end
    S.noReload = on == true
    M.tick()
    return true
end

function M.onWorldChanged()
    -- Main may call this after travel. Only restore when still in the SAME world.
    -- Once that world is gone, keeping/retrying UObject references is unsafe.
    if busy then return end
    busy = true
    local ok, err = pcall(function()
        releaseAll(context())
    end)
    tracked = {}
    busy = false
    status = tr("Warte auf Spielercharakter")
    if not ok then warn("world", tr("Weltwechsel: ") .. tostring(err)) end
end

function M.reset()
    S.noOverheat, S.infiniteResources, S.noReload = false, false, false
    M.tick()
    -- Inert hooks stay registered for later re-enabling; no duplicates.
    return next(tracked) == nil
end

function M.page(ui)
    local page = ui.newPage(tr("Waffen"))
    local cheats = ui.card(page.left, tr("Waffen im Spielerholster"))
    ui.toggleRow(page, cheats, tr("Überhitzung aus"), function() return S.noOverheat end,
        M.setNoOverheat, tr("Deaktiviert den Überhitzungs-Cooldown"))
    ui.toggleRow(page, cheats, tr("Unendliche Waffenressourcen"), function() return S.infiniteResources end,
        M.setInfiniteResources, tr("Magazin und Waffentank: Munition, Benzin, Strom usw."))
    ui.toggleRow(page, cheats, "No Reload", function() return S.noReload end,
        function(on)
            local ok, message = M.setNoReload(on)
            if not ok then ui.toast(message, "bad") end
        end, tr("Hält das Magazin voll; laufendes Nachladen erst beenden"))
    local info = ui.card(page.right, tr("Sitzung"))
    ui.infoRow(page, info, "Status", function() return status end)
    ui.infoRow(page, info, tr("Nachladen überspringen"), function() return hookReady and tr("Bereit") or tr("Nicht verfügbar") end)
    ui.infoRow(page, info, tr("Waffentanks auffüllen"), function()
        return resourceHookReady and tr("Bei Verbrauch und regelmäßig") or tr("Nur regelmäßig")
    end)
    ui.button(info, tr("Waffenwerte zurücksetzen"), "danger", function()
        local ok = M.reset()
        ui.toast(ok and tr("Waffen-Schalter aus") or tr("Wiederherstellung wird erneut versucht"), ok and "good" or "bad")
        ui.refreshActive()
    end)
    ui.add(info, ui.paragraph(tr("Gilt für alle Waffen im Spielerholster. Beim Ablegen oder Ausschalten werden gesicherte Werte zurückgesetzt. Nur für diese Sitzung.")))
    return page
end

M.init()
return M
