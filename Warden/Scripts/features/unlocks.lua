local tr = require("i18n").t
--[[
    features/unlocks.lua - skills, patterns, enhancers, samples, map and quests.

    Skills, patterns, enhancers and samples go straight to the game's native functions
    (VoyageGameplayBlueprintFunctionLibrary, VoyagePlayerState). Those take and return
    hard object pointers, which UE4SS handles without trouble.

    Map and quest unlocks use the game's own admin functions (ShowAllLocations,
    CompleteTrackedQuests, ...) through core.cheat, exactly as its admin menu does.
--]]

local core = require("core")

local M = {}

local function lib()
    return core.lib("gameplayV")
end

local function allSkills()
    local l = lib()
    if l == nil then
        return {}
    end
    return core.outList("GetAllSkills", function(h) return l:GetAllSkills(h, false) end, "OutSkills")
end

local function hasSkill(skill, pc)
    local ok, has = pcall(function() return lib():HasPlayerSkill(skill, pc) end)
    return ok and has == true
end

function M.skillCount()
    local pc = core.pc()
    local skills = allSkills()
    if pc == nil or #skills == 0 then
        return nil
    end
    local owned = 0
    for _, s in ipairs(skills) do
        if hasSkill(s, pc) then
            owned = owned + 1
        end
    end
    return owned, #skills
end

function M.unlockSkills()
    local l, pc, ps = lib(), core.pc(), core.playerState()
    if l == nil or pc == nil then
        return false, tr("Kein Spieler")
    end
    local skills = allSkills()
    if #skills == 0 then
        return false, tr("Keine Skills gefunden")
    end
    local added = 0
    -- Child skills need their parents, so a few passes pick up whole branches.
    for _ = 1, 5 do
        local progress = false
        for _, s in ipairs(skills) do
            if not hasSkill(s, pc) then
                pcall(function() l:UnlockPlayerSkill(s, pc) end)
                if not hasSkill(s, pc) and ps ~= nil then
                    pcall(function() ps:AddSkill(s, false) end)
                end
                if hasSkill(s, pc) then
                    added = added + 1
                    progress = true
                end
            end
        end
        if not progress then
            break
        end
    end
    -- Skills unlock items into the vault; make sure that happened for added ones.
    pcall(function() l:ReUnlockSkillItemsToVault(pc) end)
    local owned, total = M.skillCount()
    return true, string.format(tr("%d Skills freigeschaltet (%s/%s)"), added, tostring(owned), tostring(total))
end

local function allPatterns()
    local l = lib()
    if l == nil then
        return {}
    end
    return core.outList("GetAllPatterns", function(h) return l:GetAllPatterns(h) end, "OutPatterns")
end

local function playerPatterns(pc)
    local l = lib()
    if l == nil then
        return {}
    end
    return core.outList("GetAllPlayerPatterns", function(h) return l:GetAllPlayerPatterns(pc, h) end, "OutPatterns")
end

function M.patternCount()
    local pc = core.pc()
    if pc == nil then
        return nil
    end
    local all = allPatterns()
    if #all == 0 then
        return nil
    end
    return #playerPatterns(pc), #all
end

function M.unlockPatterns()
    local l, pc = lib(), core.pc()
    if l == nil or pc == nil then
        return false, tr("Kein Spieler")
    end
    local all = allPatterns()
    if #all == 0 then
        return false, tr("Keine Baupläne gefunden")
    end
    local have = {}
    for _, item in ipairs(playerPatterns(pc)) do
        have[core.fullName(item)] = true
    end
    local before = 0
    for _ in pairs(have) do
        before = before + 1
    end
    local marked = 0
    for _, item in ipairs(all) do
        if not have[core.fullName(item)] then
            if pcall(function() l:MarkItemScanned(pc, item, false) end) then
                marked = marked + 1
            end
        end
    end
    local okVault, toVault = pcall(function() return l:ReUnlockScannedItemsToVault(pc) end)
    local after = #playerPatterns(pc)
    local msg = string.format(tr("Baupläne: %d \u{2192} %d von %d"), before, after, #all)
    if okVault and type(toVault) == "number" and toVault > 0 then
        msg = msg .. string.format(tr("  \u{2022}  %d ins Lager"), toVault)
    end
    core.log(string.format("patterns: marked %d as scanned", marked))
    return after > before or marked > 0, msg
end

function M.maxEnhancers()
    local l, ps = lib(), core.playerState()
    if l == nil or ps == nil then
        return false, tr("Kein Spieler")
    end
    local list = core.outList("GetAllEnhancers", function(h) return l:GetAllEnhancers(h) end, "OutAllEnhancers")
    if #list == 0 then
        return false, tr("Keine Enhancer gefunden")
    end
    local done, protected = 0, 0
    for _, e in ipairs(list) do
        local okMax, maxPoints = pcall(function() return e.MaxPoints end)
        local points = (okMax and type(maxPoints) == "number" and maxPoints > 0) and maxPoints or 10
        -- AddEnhancer ADDS points and clamps only to the asset's MaxPoints.
        -- Consumption optimization is linear (1 - sum(points * factor)); a
        -- modded factor of .015 at 100 points produces -0.5 and stalls builds.
        -- Leave these enhancers alone, including on repeated button presses.
        -- Unknown/unreadable maps are also protected. Never change shared assets.
        local optimization = false
        local readable = pcall(function()
            local values = e.CharacterModuleConsumptionOptimization
            if type(values)=="table" then
                for _,v in pairs(values) do if type(v)=="number" and v>0 then optimization=true end end
            else
                values:ForEach(function(_,v)
                    v=core.unwrap(v)
                    if type(v)~="number" or v>0 then optimization=true end
                end)
            end
        end)
        if not readable or optimization then
            protected=protected+1
        else
            local ok, added=pcall(function() return ps:AddEnhancer(e, points) end)
            if ok and added==true then done=done+1 end
        end
    end
    return true, string.format(tr("%d Enhancer erhoeht; %d Verbrauchs-Enhancer unveraendert"),done,protected)
end

function M.collectSamples()
    local l, ps = lib(), core.playerState()
    if l == nil or ps == nil then
        return false, tr("Kein Spieler")
    end
    local list = core.outList("GetAllSampleDatas", function(h) return l:GetAllSampleDatas(h) end, "OutSampleDatas")
    if #list == 0 then
        return false, tr("Keine Proben gefunden")
    end
    local done = 0
    for _, s in ipairs(list) do
        local a = pcall(function() ps:MarkedSampleCollected(s) end)
        local b = pcall(function() ps:MarkedSampleSent(s) end)
        if a or b then
            done = done + 1
        end
    end
    return done > 0, string.format(tr("%d Proben gesammelt und gesendet"), done)
end

function M.tier()
    local l, pc = lib(), core.pc()
    if l == nil or pc == nil then
        return nil
    end
    local ok, t = pcall(function() return l:GetUnlockedTier(pc) end)
    return ok and t or nil
end

------------------------------------------------------------------------------------------
-- Page
------------------------------------------------------------------------------------------

function M.page(ui)
    local page = ui.newPage(tr("Freischalten"))

    local counts = { skills = "-", patterns = "-" }
    local function recount()
        local o, t = M.skillCount()
        counts.skills = o and string.format("%d / %d", o, t) or "-"
        local po, pt = M.patternCount()
        counts.patterns = po and string.format("%d / %d", po, pt) or "-"
    end
    page.onShow = recount

    local function run(fn)
        return function()
            local ok, msg = fn()
            ui.toast(msg, ok and "good" or "warn")
            recount()
            ui.refreshActive()
        end
    end

    local prog = ui.card(page.left, tr("Fortschritt"))
    ui.infoRow(page, prog, "Skills", function() return counts.skills end)
    ui.infoRow(page, prog, tr("Baupläne"), function() return counts.patterns end)
    ui.infoRow(page, prog, tr("Freigeschaltete Stufe"), function()
        local t = M.tier()
        return t and ("Tier " .. t) or "-"
    end)
    ui.button(prog, tr("Alle Skills freischalten"), "primary", run(M.unlockSkills), { slot = { pad = { 0, 6, 0, 2 } } })
    ui.button(prog, tr("Alle Baupläne freischalten"), "action", run(M.unlockPatterns))
    ui.button(prog, tr("Enhancer sicher maximieren"), "action", run(M.maxEnhancers))
    ui.add(prog,ui.paragraph(tr("Verbrauchs-Enhancer wie Power Management werden ausgelassen: zu hohe Werte koennen das Bauen blockieren.")))
    ui.button(prog, tr("Alle Proben sammeln & senden"), "action", run(M.collectSamples))

    local function cheat(fn, done)
        return function()
            local ok, err = core.cheat(fn)
            ui.toast(ok and done or (tr("Fehlgeschlagen: ") .. tostring(err)), ok and "good" or "bad")
        end
    end

    local map = ui.card(page.right, tr("Karte & Orte"))
    ui.button(map, tr("Alle Orte auf der Karte zeigen"), "action",
        cheat("ShowAllLocations", tr("Alle Orte sind jetzt auf der Karte sichtbar")))
    ui.button(map, tr("Alle Orte als besucht markieren"), "action",
        cheat("MarkAllLocationsVisited", tr("Alle Orte als besucht markiert")))

    local quests = ui.card(page.right, "Quests")
    ui.button(quests, tr("Verfolgte Quests abschließen"), "action",
        cheat("CompleteTrackedQuests", tr("Verfolgte Quests abgeschlossen")))
    ui.button(quests, tr("Nächste Aufgabe abschließen"), "action",
        cheat("CompleteNextTrackedActiveTasks", tr("Nächste Aufgabe abgeschlossen")))

    local hint = ui.card(page.right, tr("Hinweis"))
    ui.add(hint, ui.paragraph(tr("Freischaltungen werden mit dem Spielstand gespeichert und lassen ")
        .. tr("sich nicht rückgängig machen. Vorher speichern lohnt sich.")), { pad = { 2, 0 } })

    return page
end

return M
