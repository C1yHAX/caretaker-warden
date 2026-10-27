local tr = require("i18n").t
-- All writes run on the game thread. Keep original values per character, never
-- treat a value written by Warden as a new multiplier base.
local core = require("core")
local M = { state = { fly = false, noclip = false } }
M.speeds = { 0.5, 1, 1.5, 2, 3, 4, 6 }
M.jumps = { 1, 1.5, 2, 3, 4 }
M.flights = { 1, 2, 4, 8, 15 }
M.indices = { walk = 2, jump = 1, fly = 1 }
local saved, loop
local speedProps = { "MaxWalkSpeed", "MaxWalkSpeedCrouched", "MaxAcceleration", "JumpZVelocity", "MaxFlySpeed" }
local function read(o, p)
    local ok, v = pcall(function() return o[p] end)
    if ok then return v end
end
local function write(o, p, v)
    if v ~= nil then pcall(function() o[p] = v end) end
end
local function restoreCollision(s)
    if not s.collision then return end
    for _, c in ipairs(s.collision) do
        if core.isValid(c.object) then pcall(function() c.object:SetCollisionEnabled(c.mode) end) end
    end
    if s.actorCollision ~= nil then pcall(function() s.pawn:SetActorEnableCollision(s.actorCollision) end) end
    if s.dynamicActive ~= nil and core.isValid(s.dynamic) then
        pcall(function() s.dynamic:SetActive(s.dynamicActive, false) end)
    end
    s.collision = nil
end
local function restore(s)
    if s == nil or not core.isValid(s.pawn) or not core.isValid(s.cmc) then return end
    restoreCollision(s)
    for p, v in pairs(s.base) do write(s.cmc, p, v) end
    if s.flight then
        write(s.cmc, "bCheatFlying", s.cheatFlying)
        -- Falling re-evaluates floor/water at the new location instead of forcing walking in mid-air.
        pcall(function() s.cmc:SetMovementMode(3, 0) end)
    end
end
local function worldKey()
    local pc, lib = core.pc(), core.lib("misc")
    if not pc or not lib then return nil end
    local ok, world = pcall(function() return lib:GetActorWorld(pc) end)
    if ok and core.isValid(world) then return tostring(core.address(world)) .. core.fullName(world) end
end
local function bind()
    local world = worldKey()
    -- The frame loop can see travel before main's 250-ms watcher. Never restore
    -- through wrappers from a previous (or already missing) world in that gap.
    if saved and (world == nil or saved.world ~= world) then saved = nil end
    if world == nil then return nil end
    local pawn, cmc = core.character()
    if pawn == nil then
        restore(saved); saved = nil
        return nil
    end
    if saved == nil or saved.address ~= core.address(pawn) then
        restore(saved)
        saved = { pawn = pawn, cmc = cmc, address = core.address(pawn), world = world, base = {} }
        for _, p in ipairs(speedProps) do
            local v = read(cmc, p)
            if type(v) == "number" then saved.base[p] = v end
        end
        saved.cheatFlying = read(cmc, "bCheatFlying")
    end
    return saved
end
local function collision(s)
    if not M.state.noclip then restoreCollision(s); return end
    if not s.collision then
        s.collision = {}
        pcall(function() s.actorCollision = s.pawn:GetActorEnableCollision() end)
        local seen = {}
        for _, name in ipairs({ "CapsuleComponent", "CollisionCylinderPhysical" }) do
            local c = read(s.pawn, name)
            if core.isValid(c) and not seen[core.address(c)] then
                local ok, mode = pcall(function() return c:GetCollisionEnabled() end)
                if ok and type(mode) == "number" then
                    s.collision[#s.collision + 1] = { object = c, mode = mode }
                    seen[core.address(c)] = true
                end
            end
        end
        s.dynamic = read(s.pawn, "VoyageDynamicCollision")
        if core.isValid(s.dynamic) then pcall(function() s.dynamicActive = s.dynamic:IsActive() end) end
    end
    for _, c in ipairs(s.collision) do pcall(function() c.object:SetCollisionEnabled(0) end) end
    pcall(function() s.pawn:SetActorEnableCollision(false) end)
    if s.dynamicActive == true then pcall(function() s.dynamic:SetActive(false, false) end) end
end
local function down(pc, key)
    local ok, v = pcall(function() return pc:IsInputKeyDown({ KeyName = FName(key) }) end)
    return ok and v == true and 1 or 0
end
local function axis(pc, key)
    local ok, v = pcall(function() return pc:GetInputAnalogKeyState({ KeyName = FName(key) }) end)
    return ok and type(v) == "number" and math.abs(v) > 0.15 and v or 0
end
local function frame()
    local s = bind()
    if s == nil then return end
    local flying = M.state.fly or M.state.noclip
    local walk, flight = M.speeds[M.indices.walk], M.flights[M.indices.fly]
    for _, p in ipairs({ "MaxWalkSpeed", "MaxWalkSpeedCrouched" }) do
        if s.base[p] then write(s.cmc, p, s.base[p] * walk) end
    end
    if s.base.MaxAcceleration then write(s.cmc, "MaxAcceleration", s.base.MaxAcceleration * math.max(1, walk, flying and flight or 1)) end
    if s.base.JumpZVelocity then write(s.cmc, "JumpZVelocity", s.base.JumpZVelocity * M.jumps[M.indices.jump]) end
    if s.base.MaxFlySpeed then write(s.cmc, "MaxFlySpeed", s.base.MaxFlySpeed * flight) end
    collision(s)
    if not flying then
        if s.flight then
            s.flight = false
            write(s.cmc, "bCheatFlying", s.cheatFlying)
            pcall(function() s.cmc:SetMovementMode(3, 0) end)
        end
        return
    end
    local pc, gs = core.pc(), core.lib("gameplay")
    if not pc or not gs then return end
    local rot = pc:GetControlRotation()
    -- FNames retain their first registered spelling. The actual 0.10 dump has
    -- 'pitch', 'Yaw', 'Roll'; C++ spelling alone is NOT a Lua reflection contract.
    local pitch = read(rot, "pitch") or read(rot, "Pitch")
    local yaw = read(rot, "Yaw") or read(rot, "yaw")
    assert(type(pitch) == "number" and pitch == pitch and math.abs(pitch) < math.huge
        and type(yaw) == "number" and yaw == yaw and math.abs(yaw) < math.huge,
        tr("Blickrichtung nicht lesbar; Flug beendet"))
    yaw, pitch = math.rad(yaw), math.rad(pitch)
    -- Validate the camera BEFORE suspending native movement. Hover while idle,
    -- but restore normal movement if any part of this frame subsequently fails.
    s.flight = true
    write(s.cmc, "bCheatFlying", true)
    s.cmc:StopMovementImmediately()
    s.cmc:SetMovementMode(0, 0)
    local ui = package.loaded.ui
    if ui and ui.isOpen and not ui.walkWhileOpen then return end
    local inputOK, inputIgnored = pcall(function() return pc:IsMoveInputIgnored() end)
    if inputOK and inputIgnored == true then return end
    local ok, dt = pcall(function() return gs:GetWorldDeltaSeconds(pc) end)
    if not ok or type(dt) ~= "number" or dt <= 0 then return end
    dt = math.min(dt, 0.1)
    local f = down(pc, "W") - down(pc, "S") + axis(pc, "Gamepad_LeftY")
    local r = down(pc, "D") - down(pc, "A") + axis(pc, "Gamepad_LeftX")
    local z = down(pc, "SpaceBar") - math.max(down(pc, "LeftControl"), down(pc, "C"))
    local x = math.cos(yaw) * math.cos(pitch) * f - math.sin(yaw) * r
    local y = math.sin(yaw) * math.cos(pitch) * f + math.cos(yaw) * r
    z = z + math.sin(pitch) * f
    local length = math.sqrt(x*x + y*y + z*z)
    if length <= 0.001 then return end
    local baseFlight = s.base.MaxFlySpeed
    if not baseFlight or baseFlight <= 0 then baseFlight = 600 end
    local step = baseFlight * flight * dt / math.max(1, length)
    -- JMAP: FVector + bool + FHitResult (0x100) + bool = 0x128 bytes total,
    -- below the 0x200 UE4SS limit including the out parameter.
    -- Only noclip bypasses sweeps; ordinary flight still stops at walls.
    s.pawn:K2_AddActorWorldOffset(core.vec(x*step, y*step, z*step), not M.state.noclip, {}, true)
end
function M.frame()
    local ok, err = pcall(frame)
    if not ok then
        M.state.fly, M.state.noclip = false, false
        if saved and saved.world == worldKey() then restore(saved) end
        saved = nil
        if loop and CancelDelayedAction then pcall(CancelDelayedAction, loop) end
        loop = nil
        core.log(tr("Flug sicher beendet: ") .. tostring(err))
    end
    return ok
end
local function active()
    return M.state.fly or M.state.noclip or M.indices.walk ~= 2 or M.indices.jump ~= 1
end
function M.sync()
    if active() then
        local ok = M.frame()
        if ok and loop == nil and LoopInGameThreadAfterFrames then
            loop = LoopInGameThreadAfterFrames(1, function() core.safe("movement", M.frame) end)
        end
    else
        if loop and CancelDelayedAction then pcall(CancelDelayedAction, loop) end
        loop = nil
        if saved and saved.world == worldKey() then restore(saved) end
        saved = nil
    end
end
function M.setFly(on)
    M.state.fly = on
    if not on then M.state.noclip = false end
    M.sync()
end
function M.setNoclip(on)
    M.state.noclip = on
    if on then M.state.fly = true end
    M.sync()
end
function M.setIndex(key, i)
    local values = key == "walk" and M.speeds or key == "jump" and M.jumps or M.flights
    M.indices[key] = math.max(1, math.min(#values, i))
    M.sync()
end
function M.tick() if active() and loop == nil then M.sync() end end
function M.onWorldChanged()
    -- Never touch objects from an unloaded world.
    saved = nil
    if loop and CancelDelayedAction then pcall(CancelDelayedAction, loop) end
    loop = nil
end
return M
