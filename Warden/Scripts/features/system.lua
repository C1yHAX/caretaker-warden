local tr = require("i18n").t
--[[
    features/system.lua - menu settings and status.
--]]

local core = require("core")

local M = {}

local POSITIONS = { "left", "center", "right" }
local POSITION_DE = { left = tr("Links"), center = tr("Mitte"), right = tr("Rechts") }

function M.page(ui, hooks)
    local page = ui.newPage("System")

    local menu = ui.card(page.left, tr("Menü"))
    ui.infoRow(page, menu, tr("Sprache"), function()
        return require("i18n").getLanguage()=="en" and "English" or "Deutsch"
    end)
    ui.add(menu, ui.paragraph(tr("Sprache in settings.ini: language = en oder de. Danach das Spiel neu starten.")),
        { pad = { 2, 0, 2, 6 } })
    ui.stepperRow(page, menu, tr("Fensterposition"), {
        values = POSITIONS, wrap = true,
        format = function(v) return POSITION_DE[v] end,
        index = function()
            local cur = core.setting("position", "left")
            for i, p in ipairs(POSITIONS) do
                if p == cur then
                    return i
                end
            end
            return 1
        end,
        set = function(i)
            core.setSetting("position", POSITIONS[i])
            ui.applyPosition(POSITIONS[i])
        end,
    })
    ui.toggleRow(page, menu, tr("Laufen bei offenem Menü"), function() return core.setting("walk", true) end,
        function(on)
            core.setSetting("walk", on)
            ui.walkWhileOpen = on
            ui.releaseInput()
            ui.show()
        end, tr("WASD bewegt die Figur, die Maus bedient das Menü"))
    ui.toggleRow(page, menu, tr("Klicks neben dem Menü blocken"), function() return core.setting("block", true) end,
        function(on)
            core.setSetting("block", on)
            ui.setBlocker(on)
        end, tr("Verhindert Werkzeug- und Waffeneinsatz beim Danebenklicken"))
    ui.button(menu, tr("Menü neu aufbauen"), "action", function()
        hooks.rebuild()
    end, { slot = { pad = { 0, 6, 0, 0 } } })

    local keys = ui.card(page.left, tr("Tasten"))
    ui.infoRow(page, keys, tr("Menü öffnen / schließen"), function() return hooks.keyName() end)
    ui.infoRow(page, keys, tr("Eingabe freigeben (Notfall)"), function() return tr("Strg + ") .. hooks.keyName() end)
    ui.add(keys, ui.paragraph(tr("Die Taste lässt sich in settings.ini im Mod-Ordner ändern (toggleKey = F1, ")
        .. "INS, F2, ...)."), { pad = { 2, 4, 2, 0 } })

    local info = ui.card(page.right, "Status")
    local buildVersion="-"
    pcall(function() buildVersion=core.str(core.lib("voyage"):GetBuildVersionText(true)) or "-" end)
    ui.infoRow(page, info, "Warden", function() return "v" .. core.VERSION end)
    ui.infoRow(page, info, tr("Anzeige-Aktualisierung"),function()
        return string.format(tr("%.2f ms (Maximum %.2f)"),ui.metrics.refreshMs,ui.metrics.refreshMaxMs)
    end)
    ui.infoRow(page, info, tr("Letzter Seitenaufbau"),function() return string.format("%.1f ms",ui.metrics.buildMs) end)
    ui.infoRow(page, info, tr("Spielversion"), function()
        return buildVersion
    end)
    ui.infoRow(page, info, tr("Im Spiel"), function() return core.inGame() and tr("ja") or tr("nein") end)
    ui.infoRow(page, info, tr("Modul-Crafter"), function()
        return core.find("/Game/Blueprints/Tests/Eric/BP_Module_Crafter.BP_Module_Crafter_C") and tr("bereit") or tr("lädt bei Bedarf")
    end)
    ui.infoRow(page, info, tr("Spiel-Cheatfunktionen"), function()
        return core.find(core.CHEAT_WIDGET) and tr("bereit") or tr("lädt bei Bedarf")
    end)

    local about = ui.card(page.right, tr("Über"))
    ui.add(about, ui.paragraph(tr("Warden ist ein Admin-Menü für The Last Caretaker. Es nutzt die ")
        .. tr("eingebauten Funktionen des Spiels – Crafter, Teleport, Cheat-Funktionen des ")
        .. tr("Entwickler-Menüs – und bringt keine eigenen Spieldateien mit. Ein Spiel-Update ")
        .. tr("macht deshalb selten etwas kaputt.")), { pad = { 2, 0, 2, 6 } })
    ui.add(about, ui.paragraph(tr("Wetter-Reset und Crafter-Ansatz: TLC-AdminMenuMod von Nerfus (MIT).")),
        { pad = { 2, 0 } })

    return page
end

return M
