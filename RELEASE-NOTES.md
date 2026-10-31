# Warden 1.0.0 — Erstrelease

Eigenständiges Adminmenü mit F1, Gegenstands-/Modulkatalog, Spieler-, Teleport-, Boots- und Weltfunktionen. UE4SS erforderlich und separat zu installieren.

Für The Last Caretaker **0.10.0.653173 / Steam-Build 25982825** unter Windows.

**Paketkorrektur vom 31.10.2026, weiterhin Version 1.0.0:** Das ZIP enthält jetzt
die zuvor fehlende `Mods/Warden/settings.ini` mit allen sechs Menüeinstellungen.
Eine fehlende Datei wird zusätzlich beim Laden automatisch angelegt. Eine vorhandene
INI beim Aktualisieren behalten/überspringen; nur `Scripts` und `enabled.txt` ersetzen.
Der Download wurde aus einer leeren Installation offline geprüft, einschließlich
Lua-Abhängigkeiten, Konfigurationszugriff und Laden der enthaltenen Hilfs-DLL.

**Package fix, 2026-10-31 (still 1.0.0):** The ZIP now includes the missing default
`Warden/settings.ini`. Missing settings are also created on startup. Keep your existing
INI when updating. UE4SS remains a separate prerequisite: install its complete official
archive, including `dwmapi.dll`, `ue4ss/UE4SS.dll`, `ue4ss/UE4SS-settings.ini` and
`ue4ss/Mods/shared/UEHelpers/UEHelpers.lua`. See the README for the supported loader
and engine-version settings. An offline package test does not replace a native game test.

**Deutsch / English:** Alle Warden-Menütexte sind auch auf Englisch verfügbar.
In `Voyage/Binaries/Win64/ue4ss/Mods/Warden/settings.ini` die Zeile `language = en`
setzen und das Spiel neu starten. `language = de` aktiviert Deutsch (Standard).
Spiel- und Mod-Gegenstandsnamen behalten ihre eigene Lokalisierung.

Set **`language = en`** in Warden's `settings.ini` and restart the game for an English
menu. All tabs, controls, built-in module labels and Warden status/log text are translated.
The game's language and saved location names are unchanged. Version remains **1.0.0**.

## Download und Installation

Den benannten Mod-ZIP-Anhang herunterladen, vollständig entpacken und bei geschlossenem Spiel den enthaltenen **Voyage**-Ordner in das Spielinstallationsverzeichnis kopieren. Die komplette Anleitung, Voraussetzungen, Bedienung und bekannte Grenzen stehen in der **README.md** im Projekt. `SHA256SUMS.txt` ermöglicht die Prüfung des Downloads. Das vollständige Caretaker-Modpack enthält diese Mod bereits.

Warden benötigt den in der Anleitung verlinkten UE4SS-Build. F1 öffnet das Menü. Eigene Einstellungen und Teleportpunkte beim Aktualisieren behalten. Die enthaltene native Hilfs-DLL bleibt gegenüber der Modpack-Fassung unverändert; die Versionsanzeige lautet nun 1.0.0. Keine persönlichen Dateien enthalten. Offline-Tests ersetzen keinen nativen Spieltest.

Enthält die korrigierte deutsche/englische Gegenstandssuche, das Nachladen zunächst fehlender Gegenstände, die Erkennung neuer registrierter Mod-Items und den nativen Item-Loader. Die drei dafür benötigten Lua-Module sind vollständig im Download enthalten. Bestehende Einstellungen bleiben erhalten.

Für diese Veröffentlichung wurde das Spiel nicht gestartet.

## Inhalt des Mod-Downloads

Das Release-ZIP enthält ausschließlich die zum Betrieb benötigten Moddateien in der `Voyage`-Ordnerstruktur. Anleitung, Änderungslisten, Lizenztexte, Drittanbieterhinweise, Entwicklungswerkzeuge und Prüfberichte bleiben im Repository bzw. auf der Release-Seite. Sie werden nicht mit ins Mod-ZIP gepackt. Die Prüfsumme ist ein separater Download. Version bleibt **1.0.0**.
