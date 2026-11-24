# Warden Admin Menu 1.0.4

Published on 24 November 2026 on Nexus Mods, GitHub and GitLab. Contains all changes of the locally built candidates 1.0.1 to 1.0.3. / Veröffentlicht am 24. November 2026 auf Nexus Mods, GitHub und GitLab. Enthält alle Änderungen der nur lokal gebauten Kandidaten 1.0.1 bis 1.0.3.

## English

- World: seven weather presets for the current session and a switch back to natural weather.
- World: "Repair everything nearby" within 10, 25, 50, 100 or 250 m, with progress and cancel; repairs also refresh the damage visuals of supported objects.
- Boat repair targets the actual damaged part; only modules of your own boat are included.
- Boat engines: cylinders are fitted with the game's own method (Basic, Booster, Super Booster and Cheat Booster for diesel and electric engines).
- Items: the catalog and all spawning skip build-only objects such as large tanks, batteries and generators; new Lazarus package with human seeds, food, nutrients and memory objects.
- Fixes a crash during area repair caused by access to an expired object.

Close the game and merge the ZIP's **Voyage** folder into the game installation. UE4SS v3.0.1-1125-g527a483b is required. Keep your existing settings.ini and saved locations.

Validation: 156 offline tests (UE4SS stand-ins) and a clean-install check of the actual ZIP passed; the archive's SHA-256 matches SHA256SUMS.txt and the manifest of the Nexus upload. The author uses this build in the game; native stability and frame times are not covered by the offline tests.

## Deutsch

- Welt: sieben Wettervorlagen für die laufende Sitzung und Rückkehr zum natürlichen Wetter.
- Welt: „Alles im Umkreis reparieren“ mit 10, 25, 50, 100 oder 250 m, Fortschritt und Abbruch; Reparaturen aktualisieren auch die Schadensanzeige unterstützter Objekte.
- Bootsreparatur setzt am tatsächlich beschädigten Bauteil an; nur Module des eigenen Boots werden berücksichtigt.
- Bootsmotoren: Zylinder werden mit der Methode des Spiels ausgerüstet (Basis, Booster, Super-Booster und Cheat-Booster für Diesel und Elektro).
- Gegenstände: Katalog und Ausgabe überspringen reine Bauobjekte wie große Tanks, Batterien und Generatoren; neues Lazarus-Paket mit Menschensaat, Nahrung, Nährstoffen und Erinnerungsobjekten.
- Behebt einen Absturz bei der Umkreisreparatur durch Zugriff auf ein abgelaufenes Objekt.

Spiel schließen und den **Voyage**-Ordner aus der ZIP ins Spielverzeichnis kopieren. UE4SS v3.0.1-1125-g527a483b wird benötigt. Vorhandene settings.ini und gespeicherte Orte behalten.

Prüfung: 156 Offline-Tests (UE4SS-Attrappen) und eine Neuinstallationsprüfung des tatsächlichen ZIPs bestanden; die SHA-256 des Archivs stimmt mit SHA256SUMS.txt und dem Manifest des Nexus-Uploads überein. Der Autor nutzt diesen Stand im Spiel; native Stabilität und Frametimes decken die Offline-Tests nicht ab.

Credits: C1yHAX / c0d1ngf1eber (mod). Original developer-menu access: [TLC-AdminMenuMod by Nerfus](https://github.com/Nerfus-TLC/TLC-AdminMenuMod).

# Earlier local candidate 1.0.3

## English

Fixes unsafe object handling during area repair. The previous unwrapping helper could look up `get` on an expired UObject; the crash dump contains that reflected lookup on an invalid pointer. The helper now distinguishes actual parameter wrappers before accessing their contents.

Area repair uses small spatial queries instead of a global component snapshot. It retains only paths and identifiers between ticks, resolves targets before use, subdivides dense areas and applies at most one health change per tick. Progress and cancellation remain available. The default radius is now 10 m; 25/50/100/250 m remain selectable. The query covers loaded objects with collision on the standard object channels. Objects without queryable collision and unresolved dense areas are not silently reported as repaired.

Retains the inventory filter, Lazarus package, boat repair and native cylinder outfitting changes. German and English included.

Close the game and merge the ZIP's **Voyage** folder into the game installation. UE4SS is required. Preserve existing settings and saved destinations.

Validation: 156 offline tests passed, one optional UE4SS source-file check skipped. Includes same-world unloading, address reuse, userdata lifetime, dense cells, cancellation and a simulated 250 m workload. The old/new helper comparison reproduces the unsafe lookup only in 1.0.2. Both languages exercised nine pages and 218 buttons without Lua errors. The actual ZIP passed clean-install checks and complete file/hash verification. No game was launched. Native stability and frame times remain unverified in-game. This candidate has not been published.

## Deutsch

Behebt unsichere Objektzugriffe bei der Umkreisreparatur. Die vorherige Entpack-Hilfsfunktion konnte auf einem nicht mehr gültigen UObject nach `get` suchen; das Speicherabbild enthält genau diese reflektierte Suche auf einem ungültigen Zeiger. Die Hilfsfunktion erkennt jetzt zuerst tatsächliche Parameter-Wrapper.

Die Umkreisreparatur verwendet kleine räumliche Abfragen statt einer globalen Komponentenliste. Zwischen Verarbeitungsschritten bleiben nur Pfade und Kennungen erhalten; Ziele werden vor Verwendung neu aufgelöst. Dichte Bereiche werden unterteilt, höchstens eine Gesundheit wird pro Tick geändert. Fortschritt und Abbruch bleiben verfügbar. Standardradius jetzt 10 m; 25/50/100/250 m bleiben wählbar. Die Suche umfasst geladene Objekte mit Kollision auf den Standard-Objektkanälen. Nicht abfragbare Objekte und unvollständig bearbeitete dichte Bereiche werden nicht als repariert ausgegeben.

Enthält weiterhin Inventarfilter, Lazarus-Paket, Bootsreparatur und native Motorzylinder-Ausrüstung. Deutsch und Englisch enthalten.

Spiel schließen und den **Voyage**-Ordner aus der ZIP ins Spielverzeichnis kopieren. UE4SS wird benötigt. Einstellungen und Reiseziele behalten.

Prüfung: 156 Offline-Tests bestanden, eine optionale UE4SS-Quelldateiprüfung übersprungen. Enthält Entladen innerhalb derselben Welt, Adresswiederverwendung, Wrapper-Lebensdauer, dichte Bereiche, Abbruch und eine simulierte 250-m-Last. Der Vergleich mit 1.0.2 reproduziert den unsicheren Zugriff nur mit der alten Hilfsfunktion. Neun Seiten und 218 Schaltflächen in beiden Sprachen ohne Lua-Fehler geprüft. Tatsächliches ZIP als Neuinstallation samt vollständiger Dateiliste und Hashes geprüft. Kein Spielstart. Native Stabilität und Frametimes sind noch nicht im Spiel bestätigt. Noch nicht veröffentlicht.

Credits: C1yHAX / c0d1ngf1eber (mod). Original developer-menu access: [TLC-AdminMenuMod by Nerfus](https://github.com/Nerfus-TLC/TLC-AdminMenuMod).
