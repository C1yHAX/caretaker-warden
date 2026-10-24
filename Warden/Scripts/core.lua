--[[
    core.lua - shared plumbing: logging, safe calls, object lookup, the player's
    handles, settings on disk and the game's own cheat functions.

    Three UE4SS habits shape everything in here:

      * A member that does not exist comes back as a TrivialObject, not nil, and calling
        IsValid on one throws. So validity is always tested inside pcall.
      * Out parameters come back in different shapes depending on the type (return
        value, written into the passed table, or under the parameter name). outList and
        outValue accept all of them.
      * Strings come back either as Lua strings or as FString/FText userdata. str()
        turns every shape into a Lua string.
--]]

local UEHelpers = require("UEHelpers")

local M = {}

-- Public release version. Earlier 1.x labels identify internal test snapshots only.
M.VERSION = "1.0.0"
M.BUILD = "20261023-ui-boat"
M.NAME = "Warden"

------------------------------------------------------------------------------------------
-- Logging
------------------------------------------------------------------------------------------

local journal = require("journal")
function M.log(msg, level)
    journal.add(msg, level or (tostring(msg):find("ERROR",1,true) and "Fehler" or "Info"))
    print("[Warden] " .. tostring(msg) .. "\n")
end

local onceSeen = {}
-- Logs a message only the first time it is seen, so loops cannot flood UE4SS.log.
function M.logOnce(key, msg)
    if onceSeen[key] then
        return
    end
    onceSeen[key] = true
    M.log(msg)
end

-- Runs fn, logs any error under `what`, returns ok plus fn's results.
local lastErrors = {}
function M.safe(what, fn, ...)
    local result = table.pack(pcall(fn, ...))
    if not result[1] then
        local now=os.clock()
        if not lastErrors[what] or now-lastErrors[what]>=5 then
            lastErrors[what]=now
            M.log("ERROR in " .. what .. ": " .. tostring(result[2]))
        end
        return false, result[2]
    end
    return true, table.unpack(result, 2, result.n)
end

------------------------------------------------------------------------------------------
-- Objects
------------------------------------------------------------------------------------------

function M.isValid(o)
    if o == nil then
        return false
    end
    local ok, res = pcall(function() return o:IsValid() end)
    return ok and res == true
end

function M.find(path)
    local ok, obj = pcall(StaticFindObject, path)
    if ok and M.isValid(obj) then
        return obj
    end
    return nil
end

local cdoCache = {}
-- Class default objects of function libraries. Cached, but re-checked on every use.
function M.cdo(path)
    local cached = cdoCache[path]
    if M.isValid(cached) then
        return cached
    end
    cached = M.find(path)
    cdoCache[path] = cached
    return cached
end

M.LIB = {
    gameplay  = "/Script/Engine.Default__GameplayStatics",
    system    = "/Script/Engine.Default__KismetSystemLibrary",
    math      = "/Script/Engine.Default__KismetMathLibrary",
    text      = "/Script/Engine.Default__KismetTextLibrary",
    nodes     = "/Script/Engine.Default__KismetNodeHelperLibrary",
    widgets   = "/Script/UMG.Default__WidgetBlueprintLibrary",
    layout    = "/Script/UMG.Default__WidgetLayoutLibrary",
    subsystem = "/Script/Engine.Default__SubsystemBlueprintLibrary",
    gameplayV = "/Script/Voyage.Default__VoyageGameplayBlueprintFunctionLibrary",
    voyage    = "/Script/Voyage.Default__VoyageBlueprintLibrary",
    misc      = "/Script/Voyage.Default__VoyageMiscBlueprintFunctionLibrary",
    teleport  = "/Script/Voyage.Default__VoyageTeleportAsyncAction",
}

function M.lib(name)
    return M.cdo(M.LIB[name])
end

-- Loads a blueprint class. Cooked builds have no UBlueprint object, only the generated
-- class, so the package is loaded by its asset path and the class looked up by its
-- _C path afterwards. Must run on the game thread and never inside a hook callback: a
-- synchronous load from inside a click froze the game in the original admin mod.
function M.loadClass(classPath)
    local cls = M.find(classPath)
    if cls ~= nil then
        return cls
    end
    local assetPath = classPath:gsub("_C$", "")
    if LoadAsset ~= nil then
        pcall(LoadAsset, assetPath)
        cls = M.find(classPath)
        if cls == nil then
            pcall(LoadAsset, classPath)
            cls = M.find(classPath)
        end
    end
    if cls == nil then
        M.logOnce("loadClass" .. classPath, "could not load " .. classPath)
    end
    return cls
end

function M.fullName(o)
    local ok, name = pcall(function() return o:GetFullName() end)
    return ok and tostring(name) or "?"
end

-- The object's own name: everything after the last '.' or ':'.
function M.shortName(o)
    return M.fullName(o):match("([^.:]+)$") or "?"
end

function M.address(o)
    local ok, a = pcall(function() return o:GetAddress() end)
    if ok then
        return a
    end
    return nil
end

------------------------------------------------------------------------------------------
-- Values
------------------------------------------------------------------------------------------

-- Any string shape UE4SS hands back (Lua string, FString, FText, FName) as a Lua string.
function M.str(v)
    if v == nil then
        return nil
    end
    if type(v) == "string" then
        return v
    end
    local s
    if pcall(function() s = v:ToString() end) and s ~= nil then
        return tostring(s)
    end
    return tostring(v)
end

-- Array elements and out values sometimes come back wrapped; get() unwraps them.
function M.unwrap(v)
    local inner
    if type(v) == "userdata" and pcall(function() inner = v:get() end) and inner ~= nil then
        return inner
    end
    return v
end

local function listFrom(x, name)
    if x == nil then
        return nil
    end
    if type(x) == "table" then
        if x[1] ~= nil then
            local t = {}
            for _, v in ipairs(x) do
                t[#t + 1] = M.unwrap(v)
            end
            return t
        end
        if name ~= nil and x[name] ~= nil then
            return listFrom(x[name])
        end
        return nil
    end
    if type(x) == "userdata" then
        local n
        if pcall(function() n = x:GetArrayNum() end) and type(n) == "number" then
            local t = {}
            for i = 1, n do
                local v
                if pcall(function() v = x[i] end) and v ~= nil then
                    t[#t + 1] = M.unwrap(v)
                end
            end
            return t
        end
    end
    return nil
end

-- Calls fn(holder) for a UFunction with a TArray out parameter and returns the array
-- as a plain Lua list, or an empty list. `name` is the out parameter's name.
function M.outList(what, fn, name)
    local holder = {}
    local ok, ret = pcall(fn, holder)
    if not ok then
        M.logOnce("outList" .. what, "ERROR in " .. what .. ": " .. tostring(ret))
        return {}
    end
    return listFrom(ret, name) or listFrom(holder, name) or {}
end

-- Calls fn(holder) for a UFunction with one scalar or struct out parameter and returns
-- the out value, trying every shape UE4SS uses. `name` is the parameter's name.
function M.outValue(what, fn, name)
    local holder = {}
    local ok, ret, extra = pcall(fn, holder)
    if not ok then
        M.logOnce("outValue" .. what, "ERROR in " .. what .. ": " .. tostring(ret))
        return nil
    end
    if extra ~= nil then
        return M.unwrap(extra)
    end
    if name ~= nil and holder[name] ~= nil then
        return M.unwrap(holder[name])
    end
    if holder[1] ~= nil then
        return M.unwrap(holder[1])
    end
    if next(holder) ~= nil then
        return holder
    end
    return nil, ret
end

function M.vec(x, y, z)
    return { X = x or 0.0, Y = y or 0.0, Z = z or 0.0 }
end

function M.rot(pitch, yaw, roll)
    return { pitch = pitch or 0.0, Pitch = pitch or 0.0, Yaw = yaw or 0.0, Roll = roll or 0.0 }
end

-- Reads X/Y/Z out of whatever vector shape came back.
function M.xyz(v)
    if v == nil then
        return nil
    end
    local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
    if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then
        return x, y, z
    end
    return nil
end

function M.text(s)
    local lib = M.lib("text")
    if lib ~= nil then
        local ok, t = pcall(function() return lib:Conv_StringToText(tostring(s)) end)
        if ok and t ~= nil then
            return t
        end
    end
    if FText ~= nil then
        return FText(tostring(s))
    end
    return tostring(s)
end

function M.round(n, places)
    local m = 10 ^ (places or 0)
    return math.floor(n * m + 0.5) / m
end

-- 12345 -> "12.345"
function M.thousands(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1."):reverse()
    return (out:gsub("^%.", ""))
end

------------------------------------------------------------------------------------------
-- The player
------------------------------------------------------------------------------------------

function M.pc()
    local ok, pc = pcall(UEHelpers.GetPlayerController)
    if ok and M.isValid(pc) then
        return pc
    end
    return nil
end

function M.pawn()
    local pc = M.pc()
    if pc == nil then
        return nil
    end
    local pawn
    if pcall(function() pawn = pc.Pawn end) and M.isValid(pawn) then
        return pawn
    end
    if pcall(function() pawn = pc:K2_GetPawn() end) and M.isValid(pawn) then
        return pawn
    end
    return nil
end

-- The player's character, or nil while driving a vehicle or spectating.
function M.character()
    local pawn = M.pawn()
    if pawn == nil then
        return nil, nil
    end
    local cmc
    if pcall(function() cmc = pawn.CharacterMovement end) and M.isValid(cmc) then
        return pawn, cmc
    end
    return nil, nil
end

function M.playerState()
    local pc = M.pc()
    if pc == nil then
        return nil
    end
    local ps
    if pcall(function() ps = pc.PlayerState end) and M.isValid(ps) then
        return ps
    end
    return nil
end

function M.survival()
    local pc = M.pc()
    if pc == nil then
        return nil
    end
    local s
    if pcall(function() s = pc:GetSurvivalComponent() end) and M.isValid(s) then
        return s
    end
    return nil
end

-- 1 = player inventory, 2 = vault (EVoyageInventoryType)
function M.inventory(kind)
    local pc = M.pc()
    if pc == nil then
        return nil
    end
    local inv
    if pcall(function() inv = pc:GetInventoryComponent(kind) end) and M.isValid(inv) then
        return inv
    end
    return nil
end

function M.inGame()
    return M.pc() ~= nil and M.pawn() ~= nil
end

function M.location(actor)
    local loc
    if pcall(function() loc = actor:K2_GetActorLocation() end) then
        return M.xyz(loc)
    end
    return nil
end

function M.yaw(actor)
    local r
    if pcall(function() r = actor:K2_GetActorRotation() end) and r ~= nil then
        local ok, yaw = pcall(function() return r.Yaw end)
        if ok and type(yaw) == "number" then
            return yaw
        end
    end
    return 0.0
end

-- All actors of a class, through GameplayStatics so blueprint subclasses are included.
function M.actorsOf(classPath)
    local cls = M.find(classPath)
    local gs = M.lib("gameplay")
    local pc = M.pc()
    if cls == nil or gs == nil or pc == nil then
        return {}
    end
    return M.outList("GetAllActorsOfClass " .. classPath, function(h)
        return gs:GetAllActorsOfClass(pc, cls, h)
    end, "OutActors")
end

------------------------------------------------------------------------------------------
-- Console variables and commands
------------------------------------------------------------------------------------------

function M.console(cmd)
    local ksl = M.lib("system")
    local pc = M.pc()
    if ksl == nil or pc == nil then
        return false
    end
    local ok = pcall(function() ksl:ExecuteConsoleCommand(pc, cmd, pc) end)
    return ok
end

function M.cvarFloat(name)
    local ksl = M.lib("system")
    if ksl == nil then
        return nil
    end
    local ok, v = pcall(function() return ksl:GetConsoleVariableFloatValue(name) end)
    if ok and type(v) == "number" then
        return v
    end
    return nil
end

function M.cvarInt(name)
    local ksl = M.lib("system")
    if ksl == nil then
        return nil
    end
    local ok, v = pcall(function() return ksl:GetConsoleVariableIntValue(name) end)
    if ok and type(v) == "number" then
        return v
    end
    return nil
end

-- Sets a console variable and reads it back. Returns true when the new value took.
function M.setCvar(name, value)
    M.console(name .. " " .. tostring(value))
    local now = M.cvarFloat(name)
    return now ~= nil and math.abs(now - value) < 0.001
end

------------------------------------------------------------------------------------------
-- The game's own cheat functions
------------------------------------------------------------------------------------------

--[[
    The game's admin menu (BP_VoyageCheatWiget) holds a long list of self-contained
    cheat functions: RefillBoat, ShowAllLocations, CompleteTrackedQuests and so on. Each
    one fetches what it needs through GetPlayerController and friends, so it works on
    any instance of the widget - it does not have to be on screen.

    A fresh instance is made for every call and simply dropped afterwards. Keeping one
    around would need a GC root, which Lua cannot hold, and a stale pointer after a
    garbage collection would crash the game. Creating it is a few milliseconds.
--]]
M.CHEAT_WIDGET = "/Game/UI/Game/HUD/BP_VoyageCheatWiget.BP_VoyageCheatWiget_C"

function M.cheat(fnName, ...)
    local pc = M.pc()
    local wbl = M.lib("widgets")
    if pc == nil or wbl == nil then
        return false, "kein Spieler"
    end
    local cls = M.loadClass(M.CHEAT_WIDGET)
    if cls == nil then
        return false, "Cheat-Widget des Spiels nicht gefunden"
    end
    local widget
    local ok, err = pcall(function() widget = wbl:Create(pc, cls, pc) end)
    if not ok or not M.isValid(widget) then
        return false, "Cheat-Widget konnte nicht erstellt werden: " .. tostring(err)
    end
    local args = table.pack(...)
    local result = table.pack(pcall(function()
        return widget[fnName](widget, table.unpack(args, 1, args.n))
    end))
    if not result[1] then
        M.log("ERROR in cheat " .. fnName .. ": " .. tostring(result[2]))
        return false, tostring(result[2])
    end
    return true, table.unpack(result, 2, result.n)
end

------------------------------------------------------------------------------------------
-- Files
------------------------------------------------------------------------------------------

-- The mod's own folder, from this script's path, so files land next to the mod no
-- matter what the process working directory is.
local function modDir()
    local info = debug.getinfo(1, "S")
    local src = info and info.source or ""
    src = src:gsub("^@", ""):gsub("\\", "/")
    local dir = src:match("^(.*)/Scripts/[^/]+$")
    if dir ~= nil then
        return dir .. "/"
    end
    return "ue4ss/Mods/Warden/"
end
M.DIR = modDir()

function M.readLines(name)
    local f = io.open(M.DIR .. name, "r")
    if f == nil then
        return {}
    end
    local lines = {}
    for line in f:lines() do
        lines[#lines + 1] = line
    end
    f:close()
    return lines
end

function M.writeLines(name, lines)
    local f, err = io.open(M.DIR .. name, "w")
    if f == nil then
        M.log("could not write " .. name .. ": " .. tostring(err))
        return false
    end
    for _, line in ipairs(lines) do
        f:write(line, "\n")
    end
    f:close()
    return true
end

-- Simple key=value settings. Values are kept as strings; callers convert.
M.settings = {}

function M.loadSettings()
    M.settings = {}
    for _, line in ipairs(M.readLines("settings.ini")) do
        local k, v = line:match("^%s*([%w_%.]+)%s*=%s*(.-)%s*$")
        if k ~= nil then
            M.settings[k] = v
        end
    end
end

function M.saveSettings()
    local keys = {}
    for k in pairs(M.settings) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    local lines = { "; Warden settings - written by the mod, safe to delete" }
    for _, k in ipairs(keys) do
        lines[#lines + 1] = k .. " = " .. tostring(M.settings[k])
    end
    M.writeLines("settings.ini", lines)
end

function M.setting(key, default)
    local v = M.settings[key]
    if v == nil then
        return default
    end
    if type(default) == "boolean" then
        return v == "true" or v == "1"
    end
    if type(default) == "number" then
        return tonumber(v) or default
    end
    return v
end

function M.setSetting(key, value)
    M.settings[key] = tostring(value)
    M.saveSettings()
end

return M
