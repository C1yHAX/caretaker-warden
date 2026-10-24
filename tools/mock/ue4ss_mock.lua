-- Minimal stand-in for the UE4SS Lua API, good enough to build the whole Warden window
-- and click every button outside the game. Objects are callable mocks: any member is
-- both a value and a method, and returns another mock unless RETURNS says otherwise.

local M = {}
M.calls, M.log, M.created, M.hooks, M.keybinds, M.loops, M.delayed = {}, {}, {}, {}, {}, {}, {}
M.spawned, M.timers, M.forbidden = {}, {}, {}
M.styleWrites, M.gameThreadDispatches = 0, 0

local function forbidden(what)
    M.forbidden[#M.forbidden + 1] = what
    error(what)
end

local Mock = {}
local nextAddr = 1000

local function newMock(name, props)
    nextAddr = nextAddr + 1
    local o = { __name = name, __props = props or {}, __addr = nextAddr }
    return setmetatable(o, Mock)
end
M.new = newMock

local function itemMock(n, cat)
    return newMock("Item" .. n, {
        Name = newMock("FText", { ToString = function() return "Item " .. n end }),
        Category = cat,
        Icon = newMock("Texture"),
    })
end

local RETURNS = {
    GetDerivedClassAssetData = function() return {} end,
    -- This is a fatal memory overwrite in the target UE4SS, not a catchable fallback.
    -- Record it independently of Lua errors so pcall cannot hide a test failure.
    SetStyle = function() forbidden("SetStyle exceeds UE4SS's 512-byte parameter buffer") end,
    SpawnObject = function(_, cls, outer)
        local w = newMock(rawget(cls, "__name"), { Outer = outer })
        M.spawned[#M.spawned + 1] = w
        return w
    end,
    SetContent = function(self, child)
        self.Content = child
        child.Parent = self
        return newMock("Slot")
    end,
    AddChild = function(self, child)
        child.Parent = self
        return newMock("Slot")
    end,
    AddChildToCanvas = function(self, child)
        child.Parent = self
        return newMock("CanvasSlot")
    end,
    SetBackgroundColor = function(self, color) self.BackgroundColor = color end,
    SetVisibility = function(self, visibility) self.Visibility = visibility end,
    IsValid = true,
    GetAddress = function(self) return rawget(self, "__addr") end,
    GetFullName = function(self)
        local n = tostring(rawget(self, "__name"))
        if n:find("^Item") then
            return "VoyageItem /Game/Data/" .. n .. "." .. n
        end
        return "Mock /Game/Mock." .. n
    end,
    GetOuter = function() return newMock("Outer") end,
    Create = function()
        local w = newMock("MenuButton", { Button = newMock("Button"), WidgetTree = newMock("WidgetTree") })
        M.created[#M.created + 1] = w
        return w
    end,
    GetText = function() return newMock("FText", { ToString = function() return "" end }) end,
    Conv_StringToText = function(_, s) return newMock("FText", { ToString = function() return s end }) end,
    GetEnumeratorUserFriendlyName = function(_, enum, v)
        local names = { [0] = "Small Battery", "Large Battery", "Crane", "Water Tank", "Recycler" }
        return names[v] or "Enum_MAX"
    end,
    GetLevelFromController = 5,
    GetLevelCap = 100,
    GetTotalExpRequired = 5000,
    GetAvailableSkillPoints = 3,
    GetUnlockedTier = 2,
    ReUnlockScannedItemsToVault = 3,
    GetConsoleVariableFloatValue = 1.0,
    GetConsoleVariableIntValue = 1,
    GetGlobalTimeDilation = 1.0,
    K2_GetActorLocation = function() return { X = 1000.0, Y = 2000.0, Z = 300.0 } end,
    K2_GetActorRotation = function() return { Pitch = 0.0, Yaw = 90.0, Roll = 0.0 } end,
    GetScaledCapsuleHalfHeight = 90.0,
    IsInViewport = true,
    IsInputKeyDown = false,
    HasPlayerSkill = false,
    AddItem = 5,
    GainPlayerExp = true,
    GetAllSkills = function(_, h) h[1] = newMock("Skill1") h[2] = newMock("Skill2") end,
    GetAllPatterns = function(_, h) for i = 1, 30 do h[i] = itemMock(i, (i % 7) + 18) end end,
    GetAllPlayerPatterns = function(_, pc, h) h[1] = itemMock(1, 19) end,
    GetAllEnhancers = function(_, h) h[1] = newMock("Enh", { MaxPoints = 5 }) end,
    GetAllSampleDatas = function(_, h) h[1] = newMock("Sample") end,
    GetAllActorsOfClass = function(_, pc, cls, h)
        h[1] = newMock("Dest1", { LocationName = "Dock A", LocationCategory = 1 })
        h[2] = newMock("Dest2", { LocationName = "Cave B", LocationCategory = 13 })
    end,
    GetAttribute = function(_, t, h) h.OutValue = { Value = 10.0, MaxValue = 100.0, MinValue = 0.0 } end,
    GetBuildVersionText = function()
        return newMock("FText", { ToString = function() return "0.10.0.653173" end })
    end,
}
M.RETURNS = RETURNS

Mock.__index = function(self, k)
    local props = rawget(self, "__props")
    if props[k] ~= nil then
        return props[k]
    end
    local r = RETURNS[k]
    if r ~= nil and type(r) ~= "function" then
        return function() return r end
    end
    -- A member that is both a value (indexable mock) and a method (callable).
    local member = newMock(k)
    rawset(member, "__call_impl", function(this, ...)
        M.calls[#M.calls + 1] = tostring(rawget(self, "__name")) .. ":" .. k
        if type(r) == "function" then
            return r(this, ...)
        end
        return newMock(k)
    end)
    return member
end
Mock.__call = function(self, this, ...)
    local impl = rawget(self, "__call_impl")
    if impl then
        return impl(this, ...)
    end
    return newMock("call")
end
Mock.__newindex = function(self, k, v)
    if k == "WidgetStyle" then
        if M.rejectStyle then error("simulated unsupported property assignment") end
        M.styleWrites = M.styleWrites + 1
    end
    rawget(self, "__props")[k] = v
end
Mock.__tostring = function(self) return "Mock<" .. tostring(rawget(self, "__name")) .. ">" end

-- Globals --------------------------------------------------------------------------------
_G.print = function(s) M.log[#M.log + 1] = (tostring(s):gsub("\n$", "")) end
_G.FName = function(s) return newMock("FName", { ToString = function() return s end }) end
_G.FText = function(s) return newMock("FText", { ToString = function() return s end }) end
_G.StaticFindObject = function(path) return newMock(path) end
_G.StaticConstructObject = function(cls, outer, name)
    local n = name and name:ToString() or "obj"
    return newMock(n)
end
_G.FindAllOf = function() return {} end
_G.FindFirstOf = function(c)
    if c == "Ultra_Dynamic_Sky_C" then
        return newMock("UDS", { ["Time of Day"] = 1234.5 })
    end
    if c == "BP_PersistentWorldTime_C" then
        return newMock("WT", { TimeOffset = 100.0 })
    end
    return newMock(c)
end
_G.LoadAsset = function() end
_G.RegisterHook = function(path, fn) M.hooks[path] = fn return 1, 2 end
_G.ExecuteInGameThread = function(fn)
    M.gameThreadDispatches = M.gameThreadDispatches + 1
    fn()
end
_G.ExecuteInGameThreadWithDelay = function(ms, fn) M.delayed[#M.delayed + 1] = fn return #M.delayed end
_G.LoopInGameThreadWithDelay = function(ms, fn)
    M.loops[#M.loops + 1] = fn
    M.timers[ms] = fn
    return #M.loops
end
_G.LoopInGameThreadAfterFrames = function(n, fn) M.loops[#M.loops + 1] = fn return #M.loops end
_G.CancelDelayedAction = function() return true end
_G.LoopAsync = function() end
_G.IsKeyBindRegistered = function() return false end
_G.RegisterKeyBindAsync = function(key, mods, fn)
    forbidden("Async key registration reintroduces concurrent Lua access")
end
_G.RegisterKeyBind = function(key, mods, fn)
    M.keybinds[#M.keybinds + 1] = { key = key, mods = mods, fn = fn }
end
_G.Key = setmetatable({}, { __index = function(_, k) return k end })
_G.ModifierKey = { CONTROL = "CTRL", SHIFT = "SHIFT", ALT = "ALT" }

-- UI tests use a stand-in for the native boundary. Actual DLL loading and its
-- process guard are covered separately by test_crafting.py, not by this mock.
package.loadlib = function(path, symbol)
    assert(path:find("/native/warden_crafting.dll", 1, true))
    return function(value, ...)
        assert(value == true and select('#', ...) == 0)
        if symbol == "warden_crafting_enable" then M.craftingActive = true; return true end
        if symbol == "warden_crafting_disable" then M.craftingActive = false; return true end
        if symbol == "warden_crafting_status" then return M.craftingActive or nil end
        error("unexpected native symbol")
    end
end

package.preload["UEHelpers"] = function()
    local cmc = newMock("CMC", { MaxWalkSpeed = 600.0, JumpZVelocity = 420.0, MaxFlySpeed = 600.0, MovementMode = 1 })
    local pawn = newMock("Pawn", { CharacterMovement = cmc })
    local pc = newMock("PC", { Pawn = pawn })
    return { GetPlayerController = function() return pc end }
end

return M
