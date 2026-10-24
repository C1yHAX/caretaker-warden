-- Free Crafting: only per-call fabricator cost results are changed in the native
-- helper. Shared recipes, inventories and recycling/dismantling stay untouched.
-- Exact executable SHA256 and hook prologues are checked before activation.
-- The helper does no Lua work in its native callbacks and never edits game files.
local core = require("core")
local M = {}
local native, enabled = nil, false
local message = "Aus"

local function report(text)
    message = text
    core.logOnce("crafting:" .. text, text)
end

local function load()
    local source = debug.getinfo(1, "S").source
    local scripts = source:match("^@(.*)[/\\]features[/\\][^/\\]+$")
    if not scripts then report("Free Crafting: Modulpfad nicht gefunden"); return end
    local path = scripts .. "/native/warden_crafting.dll"
    local bindings = {}
    for _, name in ipairs({"enable", "disable", "status"}) do
        local ok, fn = pcall(package.loadlib, path, "warden_crafting_" .. name)
        if not ok or type(fn) ~= "function" then
            report("Free Crafting: Herstellungsmodul konnte nicht geladen werden"); return
        end
        bindings[name] = fn
    end
    -- Exactly one true argument is part of this helper's Lua C ABI. Each entry
    -- point returns that value on success, no results (nil) on failure.
    bindings.disable(true) -- reset a pinned helper on UE4SS Lua-mod reload too
    native = bindings
end

function M.setEnabled(on)
    if not on then
        if native then native.disable(true) end
        enabled = false
        message = "Aus"
        return true
    end
    if not native then return false end
    if not core.isValid(core.pc()) then report("Free Crafting: Warte auf Spielwelt"); return false end
    enabled = native.enable(true) == true
    if not enabled then
        report("Free Crafting nicht verfügbar: Spielversion oder Herstellungsanbindung prüfen")
        return false
    end
    message = "Aktiv – nur Materialkosten beim Herstellen"
    return true
end

function M.status()
    if enabled and native.status(true) ~= true then
        enabled = false
        report("Free Crafting wurde wegen unerwarteter Spieldaten abgeschaltet")
    end
    return { enabled = enabled, available = native ~= nil, message = message }
end

load()
return M
