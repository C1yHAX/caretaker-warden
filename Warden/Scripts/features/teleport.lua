local tr = require("i18n").t
--[[
    features/teleport.lua - the game's teleport destinations, saved positions and
    quick jumps.

    Destinations are the BP_TeleportDestination_Actor_C actors the level designers
    placed (name + category). Only the ones in loaded parts of the world exist at any
    time, so every destination seen is written to destinations.tsv and kept. The list
    grows as the world is explored and survives restarts.

    Teleports go through VoyageTeleportAsyncAction:TeleportPlayerWhenLoaded, the game's
    own streaming aware teleport: it waits for the destination to load before moving
    the player, so a long jump does not drop the player through unloaded ground.
--]]

local core = require("core")

local M = {}

local DEST_CLASS = "/Game/Blueprints/BP_TeleportDestination_Actor.BP_TeleportDestination_Actor_C"
local CAT_ENUM = "/Game/Blueprints/TeleportLocationCategory.TeleportLocationCategory"
local BOAT_CLASS = "/Script/Voyage.VoyageBoatPawn"

local CATEGORIES = {
    [0] = tr("Ohne Kategorie"), "Sanctuary Docks", "Lazarus Complex", "Seed Vaults", "Exodus Station",
    "Navigational Beacons", "Refuel Stations", "Helios Reserves", "Black Vein Stations", "Sectors",
    "Underwater Ruins", "Slums", "Seed Reserve", "Caves", "Growth Containers", "Quarantine Stacks",
    "Mazes", "Star Child", "Robot Factory", "Shark Bays", "Statue Spire", "Gyrocopter Platforms",
    "Silos", "Ghost Scenes", "Eden Platforms", "Aron Station", "Bastion", "Portals",
    "Outposts - Snow Biome",
}

local destinations = {}   -- key -> {name, cat, x, y, z, yaw}
local hotspots = {}       -- {name, x, y, z, yaw}
local back = nil          -- position before the last teleport

------------------------------------------------------------------------------------------
-- Files
------------------------------------------------------------------------------------------

local function loadFiles()
    destinations = {}
    for _, line in ipairs(core.readLines("destinations.tsv")) do
        local name, cat, x, y, z, yaw = line:match("^(.-)\t(%d+)\t(%S+)\t(%S+)\t(%S+)\t(%S+)$")
        if name ~= nil then
            destinations[name .. "|" .. cat] = {
                name = name, cat = tonumber(cat), x = tonumber(x), y = tonumber(y), z = tonumber(z), yaw = tonumber(yaw),
            }
        end
    end
    hotspots = {}
    for _, line in ipairs(core.readLines("hotspots.tsv")) do
        local name, x, y, z, yaw = line:match("^(.-)\t(%S+)\t(%S+)\t(%S+)\t(%S+)$")
        if name ~= nil then
            hotspots[#hotspots + 1] = { name = name, x = tonumber(x), y = tonumber(y), z = tonumber(z), yaw = tonumber(yaw) }
        end
    end
end

local function saveDestinations()
    local keys = {}
    for k in pairs(destinations) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    local lines = {}
    for _, k in ipairs(keys) do
        local d = destinations[k]
        lines[#lines + 1] = string.format("%s\t%d\t%.1f\t%.1f\t%.1f\t%.1f", d.name, d.cat, d.x, d.y, d.z, d.yaw)
    end
    core.writeLines("destinations.tsv", lines)
end

local function saveHotspots()
    local lines = {}
    for _, h in ipairs(hotspots) do
        lines[#lines + 1] = string.format("%s\t%.1f\t%.1f\t%.1f\t%.1f", h.name, h.x, h.y, h.z, h.yaw)
    end
    core.writeLines("hotspots.tsv", lines)
end

------------------------------------------------------------------------------------------
-- Teleporting
------------------------------------------------------------------------------------------

function M.teleport(x, y, z, yaw, label)
    local pc, pawn = core.pc(), core.pawn()
    if pc == nil or pawn == nil then
        return false, tr("Kein Spieler")
    end
    local bx, by, bz = core.location(pawn)
    if bx ~= nil then
        back = { x = bx, y = by, z = bz, yaw = core.yaw(pawn) }
    end
    local loc, rot = core.vec(x, y, z), core.rot(0, yaw or 0, 0)
    local lib = core.lib("teleport")
    local started = false
    if lib ~= nil then
        local ok, action = pcall(function() return lib:TeleportPlayerWhenLoaded(pc, loc, rot, 15.0, true) end)
        if ok and core.isValid(action) then
            started = pcall(function() action:Activate() end)
        end
    end
    if not started then
        local ok = pcall(function() pawn:K2_TeleportTo(loc, rot) end)
        if not ok then
            return false, tr("Teleport fehlgeschlagen")
        end
    end
    pcall(function() pc:SetControlRotation(rot) end)
    return true, "Teleport: " .. (label or string.format("%d / %d / %d", x // 100, y // 100, z // 100))
end

-- Reads every destination actor that is loaded right now into the cache.
function M.scan()
    core.loadClass(DEST_CLASS)
    local found, added = 0, 0
    for _, actor in ipairs(core.actorsOf(DEST_CLASS)) do
        local okName, name = pcall(function() return core.str(actor.LocationName) end)
        local okCat, cat = pcall(function() return actor.LocationCategory end)
        local x, y, z = core.location(actor)
        if okName and name ~= nil and name ~= "" and x ~= nil then
            cat = (okCat and type(cat) == "number") and cat or 0
            local key = name .. "|" .. cat
            if destinations[key] == nil then
                added = added + 1
            end
            destinations[key] = { name = name, cat = cat, x = x, y = y, z = z, yaw = core.yaw(actor) }
            found = found + 1
        end
    end
    if added > 0 then
        saveDestinations()
    end
    return found, added
end

local function loadCategoryNames()
    local enum = core.find(CAT_ENUM)
    local helper = core.lib("nodes")
    if enum == nil or helper == nil then
        return
    end
    for v = 1, 60 do
        local ok, name = pcall(function() return helper:GetEnumeratorUserFriendlyName(enum, v) end)
        name = ok and core.str(name) or nil
        if name == nil or name == "" or name:find("_MAX") then
            break
        end
        CATEGORIES[v] = name
    end
end

function M.toBoat()
    local pawn = core.pawn()
    local px, py, pz = core.location(pawn)
    local best, bestD = nil, math.huge
    for _, boat in ipairs(core.actorsOf(BOAT_CLASS)) do
        local x, y, z = core.location(boat)
        if x ~= nil then
            local d = px and ((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2) or 0
            if d < bestD then
                best, bestD = { x = x, y = y, z = z, yaw = core.yaw(boat) }, d
            end
        end
    end
    if best == nil then
        return false, tr("Kein Boot in der geladenen Welt gefunden")
    end
    return M.teleport(best.x, best.y, best.z + 350, best.yaw, tr("Boot"))
end

function M.relative(forward, up)
    local pawn = core.pawn()
    local x, y, z = core.location(pawn)
    if x == nil then
        return false, tr("Kein Spieler")
    end
    local yaw = core.yaw(pawn)
    local r = math.rad(yaw)
    return M.teleport(x + math.cos(r) * forward, y + math.sin(r) * forward, z + up, yaw,
        forward ~= 0 and string.format(tr("%d m vorwärts"), forward // 100) or string.format(tr("%d m hoch"), up // 100))
end

function M.goBack()
    if back == nil then
        return false, tr("Noch keine vorherige Position")
    end
    local b = back
    return M.teleport(b.x, b.y, b.z, b.yaw, tr("zurück"))
end

function M.saveHere()
    local pawn = core.pawn()
    local x, y, z = core.location(pawn)
    if x == nil then
        return false, tr("Kein Spieler")
    end
    local name = string.format(tr("Punkt %d"), #hotspots + 1)
    hotspots[#hotspots + 1] = { name = name, x = x, y = y, z = z, yaw = core.yaw(pawn) }
    saveHotspots()
    return true, name .. tr(" gespeichert")
end

------------------------------------------------------------------------------------------
-- Page
------------------------------------------------------------------------------------------

function M.page(ui)
    loadFiles()
    pcall(loadCategoryNames)
    local page = ui.newPage("Teleport")

    local function run(fn, ...)
        local args = table.pack(...)
        return function()
            local ok, msg = fn(table.unpack(args, 1, args.n))
            ui.toast(msg, ok and "good" or "bad")
        end
    end

    local quick = ui.card(page.left, tr("Schnell"))
    ui.buttonGrid(quick, 2, {
        { tr("Zum Boot"), run(M.toBoat) },
        { tr("Zurück"), run(M.goBack) },
        { tr("10 m vorwärts"), run(M.relative, 1000, 0) },
        { tr("25 m hoch"), run(M.relative, 0, 2500) },
    })

    local saved = ui.card(page.left, tr("Gespeicherte Punkte"))
    local deleteMode = false
    local hotPool
    local function refreshHotspots()
        local shown = {}
        for i, h in ipairs(hotspots) do
            shown[#shown + 1] = {
                name = h.name,
                meta = string.format("%d / %d / %d", h.x // 100, h.y // 100, h.z // 100),
                color = deleteMode and ui.C.bad or nil,
                onClick = function()
                    if deleteMode then
                        table.remove(hotspots, i)
                        saveHotspots()
                        refreshHotspots()
                        ui.toast(h.name .. tr(" gelöscht"), "warn")
                    else
                        local ok, msg = M.teleport(h.x, h.y, h.z, h.yaw, h.name)
                        ui.toast(msg, ok and "good" or "bad")
                    end
                end,
            }
        end
        hotPool.set(shown)
    end
    ui.button(saved, tr("Aktuelle Position speichern"), "primary", function()
        local ok, msg = M.saveHere()
        ui.toast(msg, ok and "good" or "bad")
        refreshHotspots()
    end, { slot = { pad = { 0, 0, 0, 4 } } })
    ui.toggleRow(page, saved, tr("Löschmodus"), function() return deleteMode end, function(on)
        deleteMode = on
        refreshHotspots()
    end, tr("Klick auf einen Punkt löscht ihn"))
    hotPool = ui.listPool(saved, 16, false)
    refreshHotspots()

    local places = ui.card(page.right, tr("Orte"), tr("aus dem Spiel"))
    local catIndex = 1   -- 1 = all, n = category n-2 ... built below
    local catValues = { -1 }
    for v = 0, #CATEGORIES do
        catValues[#catValues + 1] = v
    end
    local destPool
    local destPage=1
    local countInfo = { text = "-" }
    local function refreshDestinations()
        local wanted = catValues[catIndex]
        local list = {}
        for _, d in pairs(destinations) do
            if wanted == -1 or d.cat == wanted then
                list[#list + 1] = d
            end
        end
        table.sort(list, function(a, b)
            if a.cat ~= b.cat then
                return a.cat < b.cat
            end
            return a.name < b.name
        end)
        local shown = {}
        local pageCount=math.max(1,math.ceil(#list/12))
        destPage=math.min(destPage,pageCount)
        for n=(destPage-1)*12+1,math.min(#list,destPage*12) do
            local d=list[n]
            shown[#shown + 1] = {
                name = d.name,
                meta = CATEGORIES[d.cat] or "",
                onClick = function()
                    local ok, msg = M.teleport(d.x, d.y, d.z + 50, d.yaw, d.name)
                    ui.toast(msg, ok and "good" or "bad")
                end,
            }
        end
        destPool.set(shown)
        countInfo.text = string.format(tr("Seite %d / %d | %d von %d"), destPage,pageCount,#list, (function()
            local n = 0
            for _ in pairs(destinations) do n = n + 1 end
            return n
        end)())
    end
    ui.stepperRow(page, places, tr("Kategorie"), {
        values = catValues, wrap = true, width = 150,
        format = function(v) return v == -1 and tr("Alle") or (CATEGORIES[v] or ("#" .. v)) end,
        index = function() return catIndex end,
        set = function(i)
            catIndex = i
            destPage=1
            refreshDestinations()
        end,
    })
    ui.infoRow(page, places, tr("Bekannte Orte"), function() return countInfo.text end)
    ui.button(places, tr("Geladene Welt nach Orten durchsuchen"), "action", function()
        local found, added = M.scan()
        refreshDestinations()
        ui.toast(string.format(tr("%d Orte geladen, %d neu"), found, added), added > 0 and "good" or nil)
    end, { slot = { pad = { 0, 2, 0, 6 } } })
    ui.buttonGrid(places,2,{
        {tr("Orte zurueck"),function() destPage=math.max(1,destPage-1);refreshDestinations() end},
        {tr("Orte weiter"),function() destPage=destPage+1;refreshDestinations() end},
    })
    destPool = ui.listPool(places, 12, false)

    local scanned=false
    page.onShow = function()
        if not scanned then M.scan();scanned=true end
        refreshDestinations()
    end
    refreshDestinations()
    return page
end

return M
