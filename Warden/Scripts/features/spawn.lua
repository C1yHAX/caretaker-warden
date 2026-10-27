local tr = require("i18n").t
--[[
    features/spawn.lua - modules, items and starter packages.

    Modules are built the way the game's own admin menu builds them: a BP_Module_Crafter
    is put down in front of the player and told what to build with
    StartCrafting(CraftableObjectList value). The crafter runs the game's own pipeline -
    build animation, correct initialisation, correct starting charge. Spawning a module
    actor directly leaves it half initialised (wrong gauges, and in testing a crash in
    the module's own BeginPlay), so that route is never used.
    Approach and the crafter details come from TLC-AdminMenuMod by Nerfus (MIT).

    Items are VoyageItem data assets. The catalogue is collected from what is loaded
    (all patterns plus every live VoyageItem object) and handed out with the inventory
    component's own AddItem.
--]]

local core = require("core")
local packages = require("features.packages")
local names = require("item_names")

local M = {}

local CRAFTER = "/Game/Blueprints/Tests/Eric/BP_Module_Crafter.BP_Module_Crafter_C"
local CRAFT_ENUM = "/Game/Blueprints/Tests/Eric/CraftableObjectList.CraftableObjectList"

-- Localized Warden labels for the craftable list. Unknown entries use the game's name.
local MODULE_DE = {
    ["Small Battery"] = tr("Kleine Batterie"),
    ["Medium Battery"] = tr("Mittlere Batterie"),
    ["Large Battery"] = tr("Große Batterie"),
    ["Petrol Barrel"] = tr("Benzinfass"),
    ["Petrol Tank"] = tr("Benzintank"),
    ["Oil Barrel"] = tr("Ölfass"),
    ["Oil Tank"] = tr("Öltank"),
    ["Water Barrel"] = tr("Wasserfass"),
    ["Water Tank"] = tr("Wassertank"),
    ["Methane Canister"] = tr("Methankanister"),
    ["Methane Tank"] = tr("Methantank"),
    ["Oxygen Canister"] = tr("Sauerstoffkanister"),
    ["Oxygen Tank"] = tr("Sauerstofftank"),
    ["Electric Generator Small"] = tr("Stromgenerator klein"),
    ["Electric Generator"] = tr("Stromgenerator"),
    ["Distillation Tower"] = tr("Destillationsturm"),
    ["Water Purifier"] = tr("Wasseraufbereiter"),
    ["Water Pump Large"] = tr("Wasserpumpe groß"),
    ["Solar Panel Ground"] = tr("Solarpanel (Boden)"),
    ["Solar Panel Standing"] = tr("Solarpanel (stehend)"),
    ["Wind Turbine"] = tr("Windturbine"),
    ["Steam Turbine"] = tr("Dampfturbine"),
    ["Gas Boiler"] = tr("Gasboiler"),
    ["Nuclear Reactor"] = tr("Kernreaktor"),
    ["Farming Module"] = tr("Farm-Modul"),
    ["Soil Manufacturer"] = tr("Erdproduktion"),
    ["Petrol Manufacturer Small"] = tr("Benzinproduktion klein"),
    ["Raw Oil Manufacturer"] = tr("Rohölproduktion"),
    ["Oxygen Manufacturer Small"] = tr("Sauerstoffproduktion klein"),
    ["Sabatier Reactor"] = tr("Sabatier-Reaktor"),
    ["Small Container"] = tr("Kleiner Container"),
    ["Medium Container"] = tr("Mittlerer Container"),
    ["Crafting Container"] = tr("Crafting-Container"),
    ["Shipping Container"] = tr("Schiffscontainer"),
    ["Crane"] = tr("Kran"),
    ["Electric Engine"] = tr("Elektromotor"),
    ["Petrol Engine"] = tr("Benzinmotor"),
    ["Diesel Engine Cylinder"] = tr("Dieselmotor-Zylinder"),
    ["Standing Light"] = tr("Stehlampe"),
    ["Ground Light"] = tr("Bodenlampe"),
    ["Small Boat"] = tr("Kleines Boot"),
    ["Fabricator"] = tr("Fabrikator"),
    ["Recycler"] = "Recycler",
    ["Fill Station"] = tr("Füllstation"),
    ["Portable Farming Pod"] = tr("Tragbare Farm-Kapsel"),
    ["Player Container"] = tr("Spieler-Container"),
    ["Electric Engine Cylinder"] = tr("Elektromotor-Zylinder"),
    ["Lazarus Pod"] = tr("Lazarus-Kapsel"),
    ["Human Seed"] = tr("Menschensamen"),
    ["Carbon Dioxide Canister"] = tr("CO\u{2082}-Kanister"),
    ["Carbon Dioxide Tank"] = tr("CO\u{2082}-Tank"),
    ["Salt Water Barrel"] = tr("Salzwasserfass"),
    ["Salt Water Tank"] = tr("Salzwassertank"),
    ["Diesel Barrel"] = tr("Dieselfass"),
    ["Diesel Tank"] = tr("Dieseltank"),
    ["Single Use Battery"] = tr("Einweg-Batterie"),
    ["Single Use Diesel Tank"] = tr("Einweg-Dieseltank"),
    ["Single Use Petrol Tank"] = tr("Einweg-Benzintank"),
    ["Single Use Fresh Water Tank"] = tr("Einweg-Frischwassertank"),
    ["Single Use Oxygen Tank"] = tr("Einweg-Sauerstofftank"),
    ["Diesel Engine Cylinder Booster"] = tr("Dieselzylinder Booster"),
    ["Diesel Engine Cylinder Eco"] = tr("Dieselzylinder Eco"),
    ["Diesel Engine Cylinder Super Booster"] = tr("Dieselzylinder Super-Booster"),
    ["Electric Engine Cylinder Booster"] = tr("Elektrozylinder Booster"),
    ["Electric Engine Cylinder Eco"] = tr("Elektrozylinder Eco"),
    ["Electric Engine Cylinder Super Booster"] = tr("Elektrozylinder Super-Booster"),
}

-- Module groups by craftable name, for the filter row.
local function moduleGroup(name)
    local n = name:lower()
    if n:find("battery") or n:find("generator") or n:find("solar") or n:find("turbine")
        or n:find("reactor") or n:find("boiler") then
        return 2   -- Energie
    end
    if n:find("barrel") or n:find("tank") or n:find("canister") or n:find("container") then
        return 3   -- Lager
    end
    if n:find("engine") or n:find("boat") or n:find("crane") then
        return 4   -- Boot
    end
    return 5       -- Produktion & Sonstiges
end

------------------------------------------------------------------------------------------
-- Modules
------------------------------------------------------------------------------------------

local modules = nil   -- { {value, name, label, group} }

local function loadModules()
    if modules ~= nil and #modules > 0 then
        return modules
    end
    modules = {}
    local enum = core.find(CRAFT_ENUM)
    if enum == nil and LoadAsset ~= nil then
        pcall(LoadAsset, CRAFT_ENUM)
        enum = core.find(CRAFT_ENUM)
    end
    local helper = core.lib("nodes")
    if enum == nil or helper == nil then
        core.log("craftable list not available")
        return modules
    end
    for value = 0, 160 do
        local ok, name = pcall(function() return helper:GetEnumeratorUserFriendlyName(enum, value) end)
        name = ok and core.str(name) or nil
        if name ~= nil and name ~= "" and not name:find("_MAX") then
            modules[#modules + 1] = {
                value = value, name = name, label = MODULE_DE[name] or name, group = moduleGroup(name),
            }
        end
    end
    table.sort(modules, function(a, b) return a.label < b.label end)
    core.log(string.format("%d craftable modules", #modules))
    return modules
end

local spawnDistance = 3   -- index into DISTANCES
local DISTANCES = { 200, 300, 450, 650, 900 }

-- In front of the player, at the height the player stands on. The capsule bottom is
-- the real surface; the game's own ground point sits about 1.6 m above it.
local function spawnTransform()
    local pawn = core.pawn()
    local km = core.lib("math")
    if pawn == nil or km == nil then
        return nil
    end
    local x, y, z = core.location(pawn)
    if x == nil then
        return nil
    end
    local yaw = core.yaw(pawn)
    local feet = z
    pcall(function()
        local half = pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
        if type(half) == "number" then
            feet = z - half
        end
    end)
    local d = DISTANCES[spawnDistance]
    local rad = math.rad(yaw)
    local loc = core.vec(x + math.cos(rad) * d, y + math.sin(rad) * d, feet)
    local ok, t = pcall(function()
        return km:MakeTransform(loc, core.rot(0, yaw, 0), core.vec(1, 1, 1))
    end)
    return ok and t or nil
end

function M.craft(mod, atTransform, parent)
    local pc = core.pc()
    local gs = core.lib("gameplay")
    if pc == nil or gs == nil then
        return false, tr("Kein Spieler")
    end
    local crafter = core.loadClass(CRAFTER)
    if crafter == nil then
        return false, tr("Crafter des Spiels nicht verfügbar")
    end
    local transform = atTransform or spawnTransform()
    if transform == nil then
        return false, tr("Position vor dem Spieler nicht bestimmbar")
    end
    local actor
    local ok, err = pcall(function()
        -- 1 = AlwaysSpawn, 1 = MultiplyWithRoot
        actor = gs:BeginDeferredActorSpawnFromClass(pc, crafter, transform, 1, nil, 1)
    end)
    if not ok or not core.isValid(actor) then
        return false, tr("Crafter konnte nicht platziert werden: ") .. tostring(err)
    end
    -- A half spawned actor is worse than none, so this always runs.
    local finished=pcall(function() gs:FinishSpawningActor(actor, transform, 1) end)
    if not finished then return false,tr("Crafter konnte nicht initialisiert werden") end
    if parent then
        local attached,yes=pcall(function() return actor:K2_AttachToActor(parent,FName("None"),1,1,1,false) end)
        if not attached or yes~=true then
            pcall(function() actor:K2_DestroyActor() end)
            return false,tr("Crafter konnte dem Motor nicht zugeordnet werden")
        end
    end
    ok, err = pcall(function() actor:StartCrafting(mod.value) end)
    if not ok then
        return false, tr("StartCrafting fehlgeschlagen: ") .. tostring(err)
    end
    return true, mod.label .. tr(" wird gebaut"),actor
end

------------------------------------------------------------------------------------------
-- Items
------------------------------------------------------------------------------------------

local ITEM_CLASSES = {
    "VoyageItem", "VoyageItemMaterial", "VoyageItemPart", "VoyageItemConsumable", "VoyageItemEquipment",
    "VoyageItemHandEquipment", "VoyageItemBaseEquipment", "VoyageItemBallisticEquipment", "VoyageItemAmmo",
    "VoyageItemWeaponMagazine", "VoyageItemWeaponAttachment", "VoyageItemEquipmentAttachment",
    "VoyageItemCassetteAttachment", "VoyageItemCable", "VoyageItemSeed", "VoyagePaintItem",
    "VoyageCartridgeItem", "VoyageLogItem",
}

-- EVoyageItemCategory -> filter group
local CATEGORY_GROUP = {
    [22] = 2,                      -- Material
    [19] = 3, [13] = 3,            -- Part, Cable
    [20] = 4, [12] = 4, [15] = 4, [23] = 4,   -- Equipment, Armor, Backpack, InventoryContainer
    [2] = 5, [9] = 5, [17] = 5, [21] = 5, [11] = 5,   -- Weapon, Ammo, Magazine, Attachment, Grenade
    [24] = 6, [6] = 6, [5] = 6, [14] = 6, [1] = 6,    -- Food, FoodMaterial, Organic, Consumable, Seed
    [18] = 7,                      -- Module
}
local CATEGORY_NAME = {
    [1] = tr("Samen"), [2] = tr("Waffe"), [5] = tr("Organisch"), [6] = tr("Zutat"), [9] = tr("Munition"), [11] = tr("Granate"),
    [12] = tr("Rüstung"), [13] = tr("Kabel"), [14] = tr("Verbrauch"), [15] = tr("Rucksack"), [16] = tr("Gegenstand"),
    [17] = tr("Magazin"), [18] = tr("Modul"), [19] = tr("Teil"), [20] = tr("Ausrüstung"), [21] = tr("Aufsatz"),
    [22] = "Material", [23] = tr("Behälter"), [24] = tr("Nahrung"), [25] = tr("Erinnerung"), [26] = tr("Farbe"),
    [27] = tr("Deko"), [28] = tr("Schrott"), [29] = tr("Kassette"), [30] = "Quest",
}

local items = nil

-- "VoyageItemMaterial /Game/Data/Assets/Materials/DA_Material_Iron.DA_Material_Iron"
local function objectPath(full)
    return full:match("^%S+%s+(.+)$") or full
end

local catalog=require("features.catalog")
function M.collectItems(force)
    catalog.start(force)
    local rows= catalog.snapshot()
    items={}
    for _,entry in ipairs(rows) do
        entry.group=CATEGORY_GROUP[entry.cat] or 8
        items[#items+1]=entry
    end
    return items
end

local AMOUNTS = { 1, 5, 10, 25, 50, 100, 250, 500 }
local amountIdx = 3
local target = 1   -- 1 = inventory, 2 = vault

function M.give(entry, amount)
    local item = packages.load(entry.path)
    if not item then return false, entry.name .. tr(": Asset nicht geladen") end
    local added, reason = packages.give(item, amount, target)
    local msg = string.format("%d / %d × %s → %s", added, amount, entry.name, target == 2 and tr("Lager") or tr("Inventar"))
    return added == amount, msg .. (reason and (" – " .. reason) or "")
end
M.tick=packages.tick
function M.onWorldChanged()
    packages.onWorldChanged()
    catalog.reset()
    items=nil
end

------------------------------------------------------------------------------------------
-- Page
------------------------------------------------------------------------------------------

local PAGE_SIZE = 12

function M.page(ui)
    local page = ui.newPage(tr("Spawnen"), 1)

    local sections = {}
    local section=1
    local tabs = ui.segmented(page.left, { tr("Module"), tr("Gegenstände"), tr("Pakete") }, function(i)
        section=i
        if i==2 then catalog.refresh();M.collectItems();M.refreshItems(true) end
        for j, s in ipairs(sections) do
            ui.setVisible(s, j == i)
        end
    end)

    --- Modules -------------------------------------------------------------------------
    local modWrap = ui.vbox()
    ui.add(page.left, modWrap, { pad = { 0, 6, 0, 0 } })
    sections[1] = modWrap
    local modCard = ui.card(modWrap, tr("Module bauen"), tr("über den Crafter des Spiels"))
    ui.stepperRow(page, modCard, tr("Abstand vor dir"), {
        values = DISTANCES,
        format = function(v) return string.format("%.1f m", v / 100) end,
        index = function() return spawnDistance end,
        set = function(i) spawnDistance = i end,
    })
    local modSearch = ui.searchBox(modCard, tr("Modul suchen ..."))
    local modGroup = 1
    ui.segmented(modCard, { tr("Alle"), tr("Energie"), tr("Lager"), tr("Boot"), tr("Produktion") }, function(i)
        modGroup = i
        M.refreshModules()
    end).set(1)
    local modPage=1
    local modCount=ui.text("",ui.F.small,ui.C.text2)
    ui.add(modCard,modCount)
    ui.buttonGrid(modCard,2,{
        {tr("Module zurueck"),function() modPage=math.max(1,modPage-1);M.refreshModules() end},
        {tr("Module weiter"),function() modPage=modPage+1;M.refreshModules() end},
    })
    local modPool = ui.listPool(modCard, PAGE_SIZE, false)
    local lastModQuery = nil

    function M.refreshModules()
        local q = modSearch.get():lower()
        if lastModQuery~=q then modPage=1 end
        lastModQuery = q
        local shown = {}
        for _, m in ipairs(loadModules()) do
            if (modGroup == 1 or m.group == modGroup)
                and (q == "" or m.label:lower():find(q, 1, true) or m.name:lower():find(q, 1, true)) then
                shown[#shown + 1] = {
                    name = m.label,
                    meta = (m.label ~= m.name) and m.name or "",
                    onClick = function()
                        local ok, msg = M.craft(m)
                        ui.toast(msg, ok and "good" or "bad")
                    end,
                }
            end
        end
        local pages=math.max(1,math.ceil(#shown/PAGE_SIZE))
        modPage=math.min(modPage,pages)
        local visible={}
        for n=(modPage-1)*PAGE_SIZE+1,math.min(#shown,modPage*PAGE_SIZE) do visible[#visible+1]=shown[n] end
        modPool.set(visible)
        ui.setText(modCount,string.format(tr("%d Module | Seite %d / %d"),#shown,modPage,pages))
    end

    --- Items ---------------------------------------------------------------------------
    local itemWrap = ui.vbox()
    ui.add(page.left, itemWrap, { pad = { 0, 6, 0, 0 } })
    sections[2] = itemWrap
    local itemCard = ui.card(itemWrap, tr("Gegenstände"), tr("Klick = hinzufügen"))
    local controls = ui.hbox()
    ui.add(itemCard, controls)
    local leftCtl = ui.vbox()
    local rightCtl = ui.vbox()
    ui.add(controls, leftCtl, { fill = true, pad = { 0, 0, 8, 0 } })
    ui.add(controls, rightCtl, { fill = true, pad = { 8, 0, 0, 0 } })
    ui.stepperRow(page, leftCtl, tr("Menge"), {
        values = AMOUNTS,
        format = function(v) return v .. "\u{00D7}" end,
        index = function() return amountIdx end,
        set = function(i) amountIdx = i end,
    })
    ui.segmented(rightCtl, { tr("Inventar"), tr("Lager") }, function(i) target = i;M.refreshItems(true) end).set(1)
    local itemSearch = ui.searchBox(itemCard, tr("Gegenstand suchen ..."))
    local itemGroup = 1
    local itemFilters=ui.segmented(itemCard, { tr("Alle"), "Material", tr("Teile"), tr("Ausrüstung"), tr("Waffen"), tr("Nahrung"), tr("Module"), tr("Sonst.") },
        function(i)
            itemGroup = i
            M.refreshItems(true)
        end, 8)
    itemFilters.set(1)
    local pager = ui.hbox()
    ui.add(itemCard, pager, { pad = { 0, 4 } })
    local pageInfo = ui.text("", ui.F.small, ui.C.text2)
    local pageNo = 1
    local filtered = {}
    ui.add(pager, pageInfo, { fill = true, v = ui.CENTER, pad = { 6, 0 } })
    ui.button(pager, tr("\u{2039} Zurück"), "chip", function()
        pageNo = math.max(1, pageNo - 1)
        M.refreshItems(false)
    end, { pad = { 8, 3 }, slot = { v = ui.CENTER, pad = { 0, 0, 4, 0 } } })
    ui.button(pager, tr("Weiter \u{203A}"), "chip", function()
        pageNo = pageNo + 1
        M.refreshItems(false)
    end, { pad = { 8, 3 }, slot = { v = ui.CENTER } })
    ui.button(pager, "\u{21BB}", "chip", function()
        M.collectItems(true)
        M.refreshItems(true)
        ui.toast(tr("Katalog wird im Hintergrund geladen"), "good")
    end, { pad = { 8, 3 }, slot = { v = ui.CENTER, pad = { 4, 0, 0, 0 } } })
    local itemPool = ui.listPool(itemCard, PAGE_SIZE, true)
    local lastItemQuery = nil
    local catalogRevision=-1
    local catalogueStatus=ui.text("",ui.F.small,ui.C.text2)
    ui.add(itemCard,catalogueStatus)

    function M.refreshItems(resetPage)
        if items == nil then
            M.collectItems()
        end
        local q = names.normalize(itemSearch.get())
        -- Starting a new search must not hide materials behind the previously
        -- selected weapon/part category. Explicit filter clicks still narrow it.
        if q~="" and q~=lastItemQuery then itemGroup=1;itemFilters.set(1) end
        lastItemQuery = q
        if resetPage then
            pageNo = 1
        end
        filtered = {}
        for _, it in ipairs(items) do
            if ((target==1 and it.player) or (target==2 and it.vault)) and (itemGroup == 1 or it.group == itemGroup)
                and names.matches(it,q) then
                filtered[#filtered + 1] = it
            end
        end
        local pages = math.max(1, math.ceil(#filtered / PAGE_SIZE))
        pageNo = math.max(1, math.min(pageNo, pages))
        local shown = {}
        for i = (pageNo - 1) * PAGE_SIZE + 1, math.min(#filtered, pageNo * PAGE_SIZE) do
            local it = filtered[i]
            local live = core.find(it.path)
            local icon = nil
            if live ~= nil then
                pcall(function() icon = live.Icon end)
            end
            shown[#shown + 1] = {
                name = it.name,
                meta = CATEGORY_NAME[it.cat] or "",
                icon = icon,
                onClick = function()
                    local ok, msg = M.give(it, AMOUNTS[amountIdx])
                    ui.toast(msg, ok and "good" or "bad")
                end,
            }
        end
        itemPool.set(shown)
        ui.setText(pageInfo, string.format(tr("%d Treffer  \u{2022}  Seite %d / %d"), #filtered, pageNo, pages))
    end

    --- Packages ------------------------------------------------------------------------
    local packWrap = ui.vbox()
    ui.add(page.left, packWrap, { pad = { 0, 6, 0, 0 } })
    sections[3] = packWrap
    local packCard = ui.card(packWrap, tr("Pakete"), tr("Direkt ins Spielerinventar; Ausgabe mit Fortschritt"))
    local function cheat(fn, done)
        return function()
            local ok, err = core.cheat(fn)
            ui.toast(ok and done or (tr("Fehlgeschlagen: ") .. tostring(err)), ok and "good" or "bad")
        end
    end
    ui.button(packCard, tr("Grundausstattung (Werkzeuge, Kabel, Waffen, Material)"), "primary",
        cheat("GiveEssentials", tr("Grundausstattung erhalten")))
    local function packageRow(label, kind, defaultIndex)
        local row, amount = ui.hbox(), defaultIndex
        ui.add(packCard, row, { pad = { 0, 4 } })
        local button = ui.button(nil, label, "action", function()
            local ok, msg = packages.start(kind, AMOUNTS[amount], function(done, success)
                ui.toast(done, success and "good" or "warn")
            end)
            ui.toast(msg, ok and "good" or "warn")
        end)
        ui.add(row, button, { fill = true, v = ui.CENTER })
        local control = ui.vbox()
        ui.add(row, control, { pad = { 10, 0, 0, 0 }, v = ui.CENTER })
        ui.stepperRow(page, control, tr("je Art"), { values = AMOUNTS, width = 48,
            index = function() return amount end, set = function(i) amount = i end })
    end
    packageRow(tr("Alle Gegenstände"), "all", 1)
    packageRow(tr("Alle Bauteile"), "parts", 5)
    packageRow(tr("Schrott-Paket"), "trash", 5)
    ui.add(packCard, ui.paragraph(tr("Alle Bauteile enthält Teile, Materialien und Zutaten aus Herstellungsrezepten. ")
        .. tr("Der Katalog wird beim Start des Pakets geprüft. Bei großen Paketen zuerst unbegrenztes Inventargewicht aktivieren.")), { pad = { 2, 5 } })
    ui.infoRow(page, packCard, tr("Fortschritt"), packages.status)
    ui.button(packCard, tr("Paket abbrechen"), "action", function()
        packages.cancel()
        ui.toast(packages.status(), "warn")
    end)

    -- Live search: re-filter when the text changes, checked by the page refresher.
    ui.addRefresher(page, function()
        local mq = modSearch.get():lower()
        if section==1 and mq ~= lastModQuery then
            M.refreshModules()
        end
        if section==2 then
            local _,_,complete,revision,state=catalog.snapshot()
            ui.setText(catalogueStatus,state)
            if revision~=catalogRevision then
                catalogRevision=revision
                M.collectItems()
                M.refreshItems(false)
            end
            local iq = names.normalize(itemSearch.get())
            if iq ~= lastItemQuery then
                M.refreshItems(true)
            end
        end
    end)

    page.onShow = function()
        if modules == nil or #modules == 0 then
            M.refreshModules()
        end
        if section==2 then
            catalog.refresh()
            if items == nil then M.refreshItems(true) end
        end
    end

    tabs.set(1)
    ui.setVisible(itemWrap, false)
    ui.setVisible(packWrap, false)
    return page
end

return M
