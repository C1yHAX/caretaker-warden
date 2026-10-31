# Paketierung und Entwicklung

## Release-ZIP

Python 3 installieren und im Repository `python tools/package_release.py` ausführen. Das Werkzeug prüft alle Laufzeitdateien gegen `Dateien.json` und erzeugt `dist/Warden-1.0.0.zip` sowie `dist/SHA256SUMS.txt`. Laufzeitcode liegt im Repository unter `Warden/`, im ZIP unter `Voyage/Binaries/Win64/ue4ss/Mods/Warden/`. Die neutrale Standardkonfiguration aus `config/settings.ini` wird als `Warden/settings.ini` mitgeliefert. Eine lokale `Warden/settings.ini` und gespeicherte Reiseziele werden niemals als Paketquelle verwendet.

Der Paketierer prüft Pflichtdateien und sämtliche statischen Lua-Abhängigkeiten zusätzlich zum Dateikatalog. Änderungen an Laufzeitdateien oder der Standardvorlage müssen in `Dateien.json` nachgezogen werden. Die vollständige ZIP-Dateiliste und alle Dateihashes werden nach dem Packen erneut geprüft.

## Offline-Tests

`python -m pip install lupa` und anschließend:

```text
python tools/smoke_test.py
python tools/smoke_test.py --language en
python tools/test_release_100_reopen_boat.py
python -m unittest discover -s tools -p "test_release_package.py" -v
python -m unittest discover -s tools -p "test_*.py"
```

Die Gegenstandsprüfungen verwenden die enthaltenen Metadaten unter `verification/item-identities.json`. Für zusätzliche ABI-Prüfungen kann `WARDEN_JMAP` auf einen vertrauenswürdigen lokalen Reflection-Dump des unterstützten Spielbuilds zeigen. Ohne diesen optionalen Dump wird nur diese Prüfgruppe ausdrücklich übersprungen; die Lua-Tests laufen trotzdem.

Die Attrappen unter `tools/mock/` bilden nur die benötigten API-Oberflächen nach. Kein Test startet das Spiel. Native Grafik, Physik und ABI-Kompatibilität werden damit nicht bestätigt. Historische Testdateinamen kennzeichnen interne Entwicklungsstände, keine zusätzlichen öffentlichen Releases.

`test_release_package.py` entpackt das tatsächliche ZIP in einen leeren temporären
Installationsordner. Es prüft Standardkonfiguration, alle neun Seiten, Öffnen/Schließen,
Englisch/F2 aus einer vorhandenen Konfiguration, Wiederherstellung einer fehlenden INI,
Erhalt vorhandener Einstellungen, UTF-8-BOM und unter Windows das Laden der enthaltenen
DLL samt Exporten. Lua-Modulsuche und Konfigurationszugriffe bleiben auf die entpackte
Installation beschränkt. Fehlende INI, DLL oder Lua-Module müssen die Paketprüfung
scheitern lassen. `WARDEN_RELEASE_ZIP` kann auf einen erneut heruntergeladenen Anhang
zeigen; `WARDEN_UE4SS_ZIP` auf den offiziellen UE4SS-Download, um dessen echtes
UEHelpers-Modul zusätzlich zu den simulierten Engine-Funktionen zu verwenden.

Menütexte werden am Entstehungsort mit `require("i18n").t` übersetzt, bevor Formatwerte
eingesetzt werden. Die deutschen Ausgangstexte stehen in den Lua-Modulen, die englischen
Entsprechungen in `Warden/Scripts/locales/en.lua`. Keine Engine-Pfade, Konsolenbefehle,
Such-Aliase oder benutzereigenen Namen übersetzen. `tools/test_i18n.py` prüft Vollständigkeit
der verwendeten Schlüssel, Platzhalter und den Start in beiden Sprachen. Die Sprachwahl
wird vor den Feature-Modulen geladen, damit zwischengespeicherte Beschriftungen stimmen.

## Native Hilfs-DLL optional neu bauen

Benötigt Windows x64, PowerShell und Zig **0.13.0**, separat installiert. Die passende MinHook-Quelle ist enthalten.

```powershell
pwsh -File tools/build_crafting.ps1 -Zig '<Pfad zu zig.exe>'
```

Das Skript baut die DLL und ein isoliertes natives Testprogramm, führt dieses aus und kopiert die neue DLL nach `Warden/Scripts/native/warden_crafting.dll`. Es startet das Spiel nicht. Nach einer eigenen Änderung stimmen die veröffentlichten Dateihashes nicht mehr; für einen eigenen Build muss der Dateikatalog bewusst neu erzeugt werden. Der ausgelieferte Erstrelease enthält die bereits vorhandene Hilfs-DLL, keinen für diese Veröffentlichung neu kompilierten Binärstand.
