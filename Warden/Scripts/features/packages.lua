local tr = require("i18n").t
-- Inventory packages use real assets + AddItem counts, not the obsolete cheat
-- widget's GiveParts/GiveTrash arrays. No UObject survives a world transition.
local core = require("core")
local M = {}
local job, status = nil, tr("Bereit")
local function pathOf(o)
    return core.fullName(o):match("^%S+%s+(/.+)$")
end
local function field(o, p)
    local ok, v = pcall(function() return o[p] end)
    return ok and v or nil
end
local function each(array, fn)
    if type(array) == "table" then for _, v in ipairs(array) do fn(type(v)=="userdata" and core.unwrap(v) or v) end
    elseif array ~= nil then pcall(function() array:ForEach(function(_, v) fn(core.unwrap(v)) end) end) end
end
function M.eligible(item, target)
    if field(item, "bSupportInventory") ~= true then return false end
    if field(item, "bOnlyAllowDesiredInventory") == true then
        local desired = field(item, "DesiredInventory")
        if (desired == 1 and target ~= 2) or (desired == 0 and target ~= 1) then return false end
    end
    local blocked = false
    each(field(item, "BlockedInventoryTypes"), function(v) if v == target then blocked = true end end)
    return not blocked
end
local function loadById(path)
    local ok,types=pcall(require,"data.item_types")
    local kind=require("item_registry").assetType(path) or (ok and types[path])
    if not kind or not FName then return nil end
    local lib=core.lib("blueprintUI")
    if not lib then return nil end
    local objects=core.outList("item primary asset loader",function()
        return lib:LoadDataAssetsById({{
            PrimaryAssetType={Name=FName(kind,1)},
            PrimaryAssetName=FName(path:match("%.([^%.]+)$"),1),
        }})
    end)
    for _,object in ipairs(objects) do
        if core.isValid(object) and pathOf(object)==path then return object end
    end
    return core.find(path)
end
function M.load(path)
    local item = core.find(path)
    local detail
    if item == nil and LoadAsset then
        local ok, loaded, found, didLoad = pcall(LoadAsset, path)
        item = ok and core.isValid(loaded) and loaded or core.find(path)
        if not item then detail=ok and (tr("Registry: gefunden=")..tostring(found)..tr(", geladen=")..tostring(didLoad)) or tostring(loaded) end
    end
    -- UE4SS LoadAsset depends on its registry bridge. The game's own loader
    -- resolves the verified PrimaryAssetId and loads its path natively (32-byte
    -- parameter block). No Lua SoftObjectPtr marshalling or invented asset types.
    if not core.isValid(item) then item=loadById(path) end
    if not core.isValid(item) then return nil, "load", detail or tr("Kein Asset geladen") end
    local cls = core.find("/Script/Voyage.VoyageItem")
    local ok, isItem = pcall(function() return item:IsA(cls) end)
    if ok and isItem == true then return item end
    return nil, "type", tr("VoyageItem-Typ nicht bestaetigt")
end
function M.give(item, amount, target)
    target = target or 1
    if not M.eligible(item, target) then return 0, tr("nicht inventarfähig") end
    local inv = core.inventory(target)
    if not inv then return 0, tr("Inventar fehlt") end
    amount = math.max(1, math.min(500, math.floor(amount)))
    local okBefore, before = pcall(function() return inv:GetNumItems(item) end)
    local ok, added = pcall(function()
        return inv:AddItem(item, { ItemCount = amount, Timestamp = os.time(), Flags = 0, Version = 0 }, true, true)
    end)
    if not ok then return 0, tostring(added) end
    local okAfter, after = pcall(function() return inv:GetNumItems(item) end)
    -- A successful ProcessEvent alone is not proof of an inventory change.
    if okBefore and okAfter and type(before) == "number" and type(after) == "number" then
        added = math.max(0, after - before)
    end
    if type(added) ~= "number" then return 0, tr("Ausgabe nicht bestätigt") end
    added = math.min(amount, math.max(0, math.floor(added)))
    if added==amount then return added end
    return added,tr("Inventar voll oder Mengenlimit erreicht")
end
function M.paths()
    local paths, seen = {}, {}
    local function add(p)
        if type(p) == "string" and p:sub(1, 1) == "/" and not p:find("Default__", 1, true) and not seen[p] then
            seen[p] = true; paths[#paths + 1] = p
        end
    end
    for _,p in ipairs(require("item_registry").paths()) do add(p) end
    -- Shipped package list from the installed game also covers assets not yet
    -- loaded by a save, and the legacy UE4SS build's incomplete registry exposure.
    local ok, manifest = pcall(require, "data.item_paths")
    if ok then for _, p in ipairs(manifest) do add(p) end end
    local lib = core.lib("gameplayV")
    if lib then
        for _, o in ipairs(core.outList("package patterns", function(h) return lib:GetAllPatterns(h) end, "OutPatterns")) do add(pathOf(o)) end
    end
    for _, cls in ipairs({ "VoyageItem", "VoyageItemPart", "VoyageItemMaterial", "VoyageItemEquipment", "VoyageItemAmmo", "VoyageItemConsumable" }) do
        local foundOK, found = pcall(FindAllOf, cls)
        if foundOK then for _, o in ipairs(found or {}) do add(pathOf(o)) end end
    end
    table.sort(paths)
    return paths
end
function M.start(kind, amount, notify)
    if job then return false, tr("Ein Paket wird bereits ausgegeben") end
    if not core.inventory(1) then return false, tr("Kein Spielerinventar") end
    if kind ~= "all" and kind ~= "parts" and kind ~= "trash" then return false, tr("Unbekanntes Paket") end
    job = { kind = kind, amount = math.max(1, math.min(500, math.floor(amount))), index = 1,
        phase = "catalog", candidates = {}, components = {}, selected = {}, seen = {}, given = 0, units = 0, partial = 0,
        failures = 0, unloaded = 0, pc = core.address(core.pc()), inventory = core.address(core.inventory(1)), notify = notify }
    require("features.catalog").start(false,true,true)
    status = tr("Katalog wird geprüft …")
    return true, status
end
function M.tick()
    local j = job
    if not j then return end
    if not core.pc() or core.address(core.pc()) ~= j.pc or not core.inventory(1) or core.address(core.inventory(1)) ~= j.inventory then
        M.cancel(tr("Paket wegen Spielerwechsel abgebrochen")); return
    end
    if j.phase=="catalog" then
        local catalogue=require("features.catalog")
        catalogue.tick()
        local rows,components,ready,_,text,unloaded=catalogue.snapshot()
        status=text
        if not ready then return end
        j.unloaded=unloaded or 0
        for _,entry in ipairs(rows) do
            if entry.player and (j.kind=="all" or (j.kind=="trash" and entry.cat==28)
                or (j.kind=="parts" and (entry.cat==19 or entry.cat==22 or entry.path:find("/Parts/",1,true) or components[entry.path]))) then
                j.selected[#j.selected+1]=entry
            end
        end
        j.phase="give"
    end
    local started=os.clock()
    for _ = 1, 8 do
            local entry = j.selected[j.index]
            if not entry then
                status = string.format(tr("%d / %d Arten, %d Stück; %d unvollständig, %d fehlgeschlagen"), j.given, #j.selected, j.units, j.partial, j.failures)
                if j.unloaded > 0 then status = status .. string.format(tr("; %d Assets nicht geladen"), j.unloaded) end
                core.log("package " .. j.kind .. ": " .. status)
                job = nil
                if j.notify then j.notify(status, j.given > 0 and j.partial == 0 and j.failures == 0 and j.unloaded == 0) end
                return
            end
            local item = M.load(entry.path)
            local added, reason = 0, tr("Asset nicht geladen")
            if item then added, reason = M.give(item, j.amount, 1) end
            if added > 0 then j.given = j.given + 1; j.units = j.units + added end
            if added == 0 then j.failures = j.failures + 1
            elseif added < j.amount then j.partial = j.partial + 1 end
            if reason then core.log("package " .. entry.path .. ": " .. added .. "/" .. j.amount .. " " .. reason) end
            j.index = j.index + 1
            status = string.format(tr("Ausgabe: %d / %d Arten (%d Stück)"), j.index - 1, #j.selected, j.units)
        if os.clock()-started>=0.003 then break end
    end
end
function M.cancel(reason)
    if job then
        status = (reason or tr("Abgebrochen")) .. string.format(tr(" (%d Stück bereits ausgegeben)"), job.units)
        job = nil
    end
end
function M.status() return status end
function M.busy() return job ~= nil end
function M.onWorldChanged() M.cancel(tr("Spielstand gewechselt")) end
return M
