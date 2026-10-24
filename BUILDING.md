# Paketierung und Entwicklung

## Release-ZIP

Python 3 installieren und im Repository `python tools/package_release.py` ausführen. Das Werkzeug prüft alle Laufzeitdateien gegen `Dateien.json` und erzeugt `dist/Warden-1.0.0.zip` sowie `dist/SHA256SUMS.txt`. Laufzeitcode liegt im Repository unter `Warden/`, im ZIP unter `Voyage/Binaries/Win64/ue4ss/Mods/Warden/`. Persönliche Einstellungen und gespeicherte Reiseziele werden nie gepackt.

## Offline-Tests

`python -m pip install lupa` und anschließend:

```text
python tools/smoke_test.py
python tools/test_release_100_reopen_boat.py
```

Die Attrappen unter `tools/mock/` bilden nur die benötigten API-Oberflächen nach. Kein Test startet das Spiel. Native Grafik, Physik und ABI-Kompatibilität werden damit nicht bestätigt. Historische Testdateinamen kennzeichnen interne Entwicklungsstände, keine zusätzlichen öffentlichen Releases.

## Native Hilfs-DLL optional neu bauen

Benötigt Windows x64, PowerShell und Zig **0.13.0**, separat installiert. Die passende MinHook-Quelle ist enthalten.

```powershell
pwsh -File tools/build_crafting.ps1 -Zig '<Pfad zu zig.exe>'
```

Das Skript baut die DLL und ein isoliertes natives Testprogramm, führt dieses aus und kopiert die neue DLL nach `Warden/Scripts/native/warden_crafting.dll`. Es startet das Spiel nicht. Nach einer eigenen Änderung stimmen die veröffentlichten Dateihashes nicht mehr; für einen eigenen Build muss der Dateikatalog bewusst neu erzeugt werden. Der ausgelieferte Erstrelease enthält die bereits vorhandene Hilfs-DLL, keinen für diese Veröffentlichung neu kompilierten Binärstand.
