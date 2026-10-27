# Warden — Adminmenü für The Last Caretaker

**Version 1.0.0 — öffentlicher Erstrelease.** Warden ergänzt *The Last Caretaker* um ein auf Deutsch oder Englisch bedienbares Adminmenü mit Gegenstands- und Modulkatalog, Spieleroptionen, Teleport, Bootswerkzeugen und Diagnose. **F1** öffnet und schließt das Menü; **Strg + F1** schließt es im Notfall und gibt die Eingabe an das Spiel zurück.

[Download auf GitHub](https://github.com/C1yHAX/caretaker-warden/releases/tag/v1.0.0) · [Download auf GitLab](https://gitlab.com/c0d1ngf1eber/caretaker-warden/-/releases/v1.0.0)

## Funktionen

| Bereich | Möglichkeiten |
|---|---|
| Spieler | Gottmodus, Sauerstoff, Ausdauer und Anzug-Energie; Hunger/Durst und Umwelteinflüsse; Level, EXP und Skillpunkte; Fliegen, Noclip, Tempo und Sprungkraft |
| Herstellung | Free Crafting, Instant Craft und Instant Build; unbegrenztes Inventargewicht und Superstärke |
| Waffen | Munition, Waffenressourcen, Überhitzung und Nachladen konfigurieren |
| Freischalten | Skills und Baupläne, Enhancer, Proben, Karteneinträge und Questfortschritt bearbeiten |
| Spawnen | Deutsche/englische Gegenstandssuche, dynamischer Mod-Katalog, Mengenwahl und Materialpakete; Module werden über den nativen Crafter angelegt |
| Teleport | Zum Boot, zur letzten Position und zu bekannten Spielorten; eigene Punkte speichern |
| Boot | Zielboot auswählen, reparieren, Tanks/Batterien auffüllen, Tempo, Anker, Aufrichten und Steuerung; Motoranschlüsse prüfen und passende Zylinder ausrüsten |
| Welt | Tageszeit, Wetter zurücksetzen, Produktions- und Spieltempo, Bauauftragsdiagnose und Trägerroboter |
| System und Log | Fensterposition, Tastenbelegung, UI-Diagnose und die letzten 200 Sitzungsmeldungen |

Die einzelnen Optionen werden im Menü bedient. Warden nutzt vorhandene Spielobjekte und native Funktionen; es bringt keine neuen Gegenstands- oder Maschinenassets mit. Die Seiten werden bei Bedarf aufgebaut, Widgets wiederverwendet und längere Listen in Seiten aufgeteilt. Es gibt keine pauschale FPS-Zusage.

**Free Crafting** hebt Materialanforderungen und Materialverbrauch beim Herstellen auf. Strom, Platzierung, Freischaltungen und Herstellungszeit bleiben davon unberührt; für Zeitverkürzung gibt es separate Optionen. Die native Hilfs-DLL aktiviert ihre Eingriffe nur beim exakt unterstützten Spiel-EXE-Hash. Andere Builds werden für diese Funktion abgelehnt.

## Voraussetzungen

- Windows, *The Last Caretaker* **0.10.0.653173 / Steam-Build 25982825**, Unreal Engine 5.8.
- **UE4SS v3.0.1-1125-g527a483b**, separat installieren: [offizieller Download](https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental/UE4SS_v3.0.1-1125-g527a483b.zip). Andere UE4SS-Builds sind nicht bestätigt.
- Warden benötigt `LoopInGameThreadWithDelay` und `RegisterKeyBind`. Fehlen diese Funktionen, bleibt es mit einer Meldung im Log inaktiv.
- Weder Caretaker Energy, Wireless noch AssetBridge sind erforderlich. UE4SS wird **nicht** im Warden-Download mitgeliefert.

Geprüfter UE4SS-DLL-Hash (SHA-256): `91d5444f41d19d0bb502f0fbdc15d76421e20359e898caa39e41e134c8f87958`.

## Installation

1. Spiel und Modmanager schließen. Vor Adminänderungen eine Sicherung des Spielstands anlegen; Freischaltungen, Gegenstände und Queständerungen können gespeichert werden.
2. Falls nötig, den oben verlinkten UE4SS-Build nach `<Spielordner>/Voyage/Binaries/Win64/` installieren. Bei bestehender Installation eigene Einstellungen und andere Mods erhalten.
3. Den Release-Anhang **`Warden-1.0.0.zip`** herunterladen und vollständig entpacken. Die automatisch erzeugten Quellcodearchive sind nicht der empfohlene Installationsdownload.
4. Den enthaltenen **`Voyage`**-Ordner in den Spielinstallationsordner kopieren. Anschließend muss diese Struktur vorhanden sein:

   ```text
   <Spielordner>/Voyage/Binaries/Win64/ue4ss/Mods/Warden/
       enabled.txt
       Scripts/main.lua
       Scripts/core.lua
       Scripts/features/...
       Scripts/native/warden_crafting.dll
   ```

5. Einen Spielstand laden und **F1** drücken. `enabled.txt` aktiviert die Mod; ein zusätzlicher `mods.txt`-Eintrag ist nicht nötig.

**Update:** Nur `Scripts` und `enabled.txt` durch die neuen Dateien ersetzen. Eigene `settings.ini`, `hotspots.tsv` und `destinations.tsv` erhalten. Diese benutzerspezifischen Dateien werden vom Release nicht mitgeliefert; Warden verwendet anfangs seine Standardwerte und legt eigene Daten beim Benutzen an.

Das vollständige Caretaker-Modpack 1.0.0 enthält Warden bereits. Keine zweite Kopie unter anderem Ordnernamen laden. Das Menü nicht gleichzeitig mit TLC-AdminMenuMod auf F1 belegen. Für eine andere Taste in der erzeugten `settings.ini` zum Beispiel `toggleKey = F2` setzen und das Spiel neu starten.

## Sprache / Language

Die Sprache wird in `<Spielordner>/Voyage/Binaries/Win64/ue4ss/Mods/Warden/settings.ini`
festgelegt. Die Datei bei Bedarf als Textdatei anlegen; vorhandene Einstellungen erhalten.
Für Englisch diese Zeile eintragen oder ändern und das Spiel neu starten:

```ini
language = en
```

Mit `language = de` zurück zu Deutsch. Ohne Eintrag bleibt Deutsch der Standard.
Die Auswahl gilt für alle neun Tabs, Schaltflächen, Beschreibungen, die 66 bekannten
Modulnamen, Paket-/Statusmeldungen und Warden-Protokolltexte. Die Übersetzungen werden
einmal geladen; es gibt keine zusätzlichen Engine-Abfragen oder Hintergrundsuche.
Warden verändert weder die Spielsprache noch eigene Namen gespeicherter Teleportpunkte.
Gegenstandsnamen aus dem Spiel und anderen Mods verwenden weiterhin deren Texte in der
Spiel-Sprache; Warden-eigene Material-Ersatznamen folgen der Menü-Sprache.

**English:** Set `language = en` in the `settings.ini` file next to Warden's `enabled.txt`,
preserve the other settings, and restart the game. Set `language = de` to return to German.
All Warden tabs, controls, help text, built-in module labels and status/log messages support
English. Item names supplied by the game or other mods keep their own localization.
The menu language does not change the game's language or your saved location names.

## Bedienung und Grenzen

- **F1:** öffnen/schließen. **Strg + F1:** Notfallschließen. Bei geänderter Menütaste gilt Strg plus diese Taste.
- Bei geöffnetem Menü bedient die Maus die Oberfläche. Bewegung per WASD kann im System-Tab erlaubt werden; die Kamera bleibt während der Menübedienung stehen.
- **Boot ausrüsten** benötigt ein ausgewähltes Boot und erkannte passende Motoranschlüsse. „Motoranschlüsse prüfen“ liefert eine Diagnose, ohne umzubauen. Fehlgeschlagene oder unbestätigte Anschlüsse werden im Log gemeldet.
- Teleportziele werden aus bekannten Spielorten und selbst gespeicherten Punkten aufgebaut. Ein frisches Profil enthält keine aus einer fremden Sitzung übernommenen Reiseziele.
- Free Crafting bis zum Abschluss der betreffenden Warteschlangenaufträge eingeschaltet lassen. Abschalten stellt die normale Materialprüfung wieder her.
- Fehler erscheinen unter `[Warden]` in `Voyage/Binaries/Win64/ue4ss/UE4SS.log`. Der Versionshinweis lautet `v1.0.0 loaded`; die interne Build-Kennung lautet `20261027-language`.

## Prüfung

Die Lua-Dateien enthalten den aktuellen Gegenstandskatalog aus der installierten Modpack-Fassung. Suchbegriffe wie „Stoff“, „Fabric“ und „Cloth“ finden denselben Gegenstand. Neue Suchbegriffe setzen einen vorherigen Kategorienfilter zurück. Fehlgeschlagene Asset-Ladungen werden begrenzt erneut versucht; registrierte neue Mod-Gegenstände können nachträglich in den Katalog aufgenommen werden. Falls der reguläre Loader ein bekanntes Item nicht liefert, wird der native Loader anhand seiner überprüften PrimaryAssetId verwendet. Fertige Katalogeinträge werden wiederverwendet. Die native Hilfs-DLL bleibt unverändert; Version **1.0.0** bleibt erhalten. Persönliche Konfigurationen und entdeckte Teleportziele wurden aus dem Download ausgeschlossen. Die Lizenztexte von Nerfus und MinHook bleiben im Repository erhalten; sie gehören nicht zum Mod-ZIP.

Die enthaltenen Offline-Tests prüfen zusätzlich Gegenstandssuche, fehlende und später registrierte Assets, begrenzte Wiederholungen, native Lade-Rückgaben und die Ausgabe in Materialpakete. Außerdem werden UI-Aufbau, Klickhandler, wiederholtes Öffnen/Schließen sowie verpackte UE4SS-Rückgabewerte bei der Bootssuche geprüft. Sie verwenden Attrappen und ersetzen keinen nativen Unreal-Spieltest. Darstellung/FPS, echtes Einrasten von Motorzylindern und vollständige Herstellungsabläufe sind für diese Veröffentlichung nicht abschließend bestätigt. **Für die Veröffentlichung wurde das Spiel nicht gestartet.** Siehe [Prüfbericht](verification/release.json).

## Entfernen

Spiel schließen und den Ordner `Warden` aus `ue4ss/Mods` herausnehmen. Eigene Einstellungen und Teleportpunkte vorher sichern. Bereits gespeicherte Fortschrittsänderungen oder ausgegebene Gegenstände werden durch Deinstallation nicht rückgängig gemacht.

## Quellcode und Paketierung

Lua-Quellen liegen unter `Warden/Scripts`. `native/` enthält den C-Quellcode der Free-Crafting-Hilfs-DLL einschließlich MinHook. [BUILDING.md](BUILDING.md) erklärt Paketierung, Offline-Tests und optionalen DLL-Build. Der Release enthält die fertige DLL.

Warden-Code: MIT, siehe [LICENSE](LICENSE). Der Wetter-Reset und der Modul-Crafter-Ansatz basieren auf [TLC-AdminMenuMod von Nerfus](https://github.com/Nerfus-TLC/TLC-AdminMenuMod). MinHook behält seine eigene Lizenz. [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) nennt die Abhängigkeiten. Inoffizielles Community-Projekt; nicht von Channel37 herausgegeben.

## English

Warden is a German/English admin menu for The Last Caretaker. Set **`language = en`** in Warden's `settings.ini` and restart the game to use English. Press **F1** to open/close; **Ctrl+F1** is the emergency close shortcut. Includes player options, crafting controls, item/module spawning, unlocks, teleport, boat maintenance/outfitting, world controls and a session log. Requires game 0.10.0.653173 / Steam build 25982825 and separately installed UE4SS v3.0.1-1125-g527a483b. Close the game and merge the release ZIP's `Voyage` folder into the game directory. Preserve your existing settings and saved teleport files during updates. First public release **1.0.0**; runtime validation remains limited, and offline mock tests do not prove native engine compatibility. The included Free Crafting DLL checks the supported game executable hash before enabling its hooks. No personal settings or discovered destinations are distributed.

## Inhalt des Mod-Downloads

Das Release-ZIP enthält ausschließlich die zum Betrieb benötigten Moddateien in der `Voyage`-Ordnerstruktur. Anleitung, Änderungslisten, Lizenztexte, Drittanbieterhinweise, Entwicklungswerkzeuge und Prüfberichte bleiben im Repository bzw. auf der Release-Seite. Sie werden nicht mit ins Mod-ZIP gepackt. Die Prüfsumme ist ein separater Download. Version bleibt **1.0.0**.
