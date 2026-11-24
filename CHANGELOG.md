# Änderungen

## 1.0.4 — Reparaturanzeige und Wetterauswahl, 2026-11-20

- Veröffentlicht am 2026-11-24 auf Nexus Mods, GitHub und GitLab. Enthält alle Änderungen
  der nur lokal gebauten Kandidaten 1.0.1 bis 1.0.3.
- Umkreis- und Bootsreparatur aktualisieren die Schadensdarstellung unterstützter Bauteile auch bei voller Haltbarkeit.
- Unter Welt lassen sich sieben Wettervorlagen für die Spielsitzung auswählen. Der natürliche Wetterverlauf kann jederzeit fortgesetzt werden.

## 1.0.3 — Absturz bei Umkreisreparatur, 2026-11-20

- `core.unwrap` ruft `get()` nur noch bei tatsächlichen Parameter-Wrappern auf.
  Das Speicherabbild des 10-m-Absturzes zeigt einen ungültigen UObject-Zugriff
  während der reflektierten Suche nach `get`. Die vorherige Hilfsfunktion konnte
  diese Suche bereits vor der Gültigkeitsprüfung eines Objekts auslösen.
- Die globale Suche nach Schadenskomponenten entfällt. Räumliche Abfragen
  untersuchen jeweils höchstens eine 50×50-m-Spalte im gewählten Umkreis;
  dichte Trefferlisten werden weiter unterteilt. Standardradius jetzt 10 m.
- Zwischen Verarbeitungsschritten werden ausschließlich Pfade, Kennungen und
  Zahlen gespeichert. Objekte werden vor Benutzung neu aufgelöst; Entladen,
  Wiederverwenden von Adressen und Spieler-/Weltwechsel werden berücksichtigt.
- Höchstens eine tatsächliche Gesundheitsänderung pro Tick, damit native Mesh-,
  Kollisions- und Spielereignisse nicht gleichzeitig in großen Serien anlaufen.
  Fortschritt und Abbruch bleiben verfügbar. Einzelne Reparaturen werden geloggt.
- Die Umgebungssuche umfasst geladene Objekte mit abfragbarer Kollision auf den
  Standard-Objektkanälen. Nicht initialisierte Komponenten werden übersprungen.
  Übersprungene oder zu dichte Bereiche werden im Ergebnis berücksichtigt.
- Neue Regressionen für den ungültigen `get`-Zugriff, Objektentladung bei gleichem
  Spieler, Parameterlebensdauer, 250-m-Bereiche, dichte Zellen und Abbruch.
  Das Spiel wurde nicht gestartet; native Laufzeit-/FPS-Bestätigung bleibt offen.

## 1.0.2 — Inventar, Reparaturen und Lazarus-Paket, 2026-11-20

- Der Katalog und jede Inventarausgabe prüfen jetzt die Bau-Routen des Items und
  die Annahmeregeln des Zielinventars. Reine Bauobjekte wie große Tanks, Batterien
  und Generatoren werden ausgeschlossen. Auch im Fabrikator herstellbare
  Nixie-Röhren sowie Stoff, Materialien und normale Bauteile bleiben verfügbar.
- Alle 923 mitgelieferten Item-Pfade anhand ihrer Asset-Eigenschaften und
  Klassenvorgaben geprüft. 116 reine Bauobjekte hätten den alten Filter passiert.
  Der Live-Katalog prüft dieselben Regeln auch für zusätzliche Mod-Items.
- Bootsreparatur setzt die Gesundheit am tatsächlichen Schadensbauteil, wie die
  direkte Reparatur im ursprünglichen Entwickler-Widget. Bootseigene Module
  ohne Szenenanbau werden über aktuelle native Mitgliedschaft berücksichtigt;
  Teile fremder Boote und falsche Schadensreferenzen werden ausgeschlossen.
- Welt: „Alles im Umkreis reparieren“, Radius 10/25/50/100/250 m, Status und
  Abbruch. Fester Mittelpunkt beim Start, eine Suche pro Auftrag, begrenzte
  Verarbeitungsschritte. Keine laufende Hintergrundsuche im Leerlauf.
- Pakete: „Lazarus-Paket“ mit Menschensaat, Nahrung, Nährstoffen,
  Erinnerungsobjekten und ihren tatsächlichen Rezeptzutaten. Mengenwahl pro Art,
  standardmäßig 50. Bauobjekte werden auch aus diesem Paket ausgeschlossen.
- Beide Menüsprachen ergänzt. Offline-Tests ersetzen keinen Test im laufenden
  Spiel; das Spiel wurde für diese Änderung nicht gestartet.

## 1.0.1 — Bootsausrüstung, 2026-11-20

- Motorzylinder verwenden jetzt direkt `SpawnActorForItem`, wie die im alten
  Admin-Menü aufgerufene Spielfunktion `SetBoatEnginesLevel`. Der fehlgeschlagene
  Versuch, einen `BP_Module_Crafter` am Motor zu befestigen, entfällt.
- Originalstufen Basis, Booster, Super-Booster und Cheat-Booster für Diesel und
  Elektro; echte Item-Assets statt der abweichenden Crafter-Enum-Auswahl.
- Originalberechnung von Position, Skalierung, Drehung und Geschwindigkeitsversatz,
  einschließlich des Höhenversatzes für elektrische Zylinder.
- Vor einem Austausch werden Item und native Softreferenz geladen und geprüft.
  Rumpf, Motoren und unbekannte Verbindungen werden nicht entfernt. Erfolg setzt
  voraus, dass genau der erzeugte Zylinder am vorgesehenen Anschluss eingerastet ist.
- Prüfung mit Lua-/UE4SS-Attrappen und dem Reflection-Dump. Kein Spielstart und
  keine Bestätigung des tatsächlichen physikalischen Einrastens durch diese Tests.

## 1.0.0 — Vollständige Standardkonfiguration, 2026-10-31

- Fehlende `settings.ini` im Release-ZIP ergänzt. Der Paketierer verwendet eine
  neutrale Vorlage mit Sprache, Menütaste, Fensterposition, Lauf-, Klick- und
  Diagnoseeinstellung, niemals eine private Benutzerkonfiguration.
- Eine fehlende INI wird beim Laden automatisch angelegt. Vorhandene oder nicht
  lesbare Konfigurationen werden dabei nicht überschrieben; UTF-8-BOM wird erkannt.
- Neue Prüfung direkt aus dem entpackten ZIP, ohne vorbereitete Einstellungen oder
  Lua-Module aus der Entwicklungsinstallation. Pflichtdateien und Lua-Abhängigkeiten
  werden unabhängig vom Manifest geprüft; der offizielle UE4SS-Loader bleibt Voraussetzung.
- Installationshinweise unterscheiden Warden- und UE4SS-Konfiguration ausdrücklich.
  Version und Release-Tag bleiben 1.0.0. Kein Spielstart für die Paketprüfung.

## 1.0.0 — Sprachauswahl, 2026-10-27

- Deutsch und Englisch über `language = de` / `language = en` in `settings.ini`.
  Auswahl vor dem Laden der Seiten; ein Sprachwechsel benötigt einen Spielneustart.
- 553 Übersetzungen für alle neun Tabs, Bedienelemente, Hilfetexte, die 66 bekannten
  Module sowie Status-, Fehler- und Aktionsmeldungen. Zahlen-Gruppierung folgt der Sprache.
- Lokale Tabellenzugriffe; keine zusätzlichen Unreal-Aufrufe oder Polling-Schleifen.
  Spielsprache, Asset-Pfade und selbst gespeicherte Namen bleiben unverändert.
- Englische Ersatznamen für Materialien bei fehlenden Spieltexten; deutsche/englische
  Suchbegriffe bleiben nutzbar. Texte anderer Mods bleiben deren Verantwortung.
- Beide Sprachen offline mit neun Seiten und 211 Buttons geprüft. Sprachtests prüfen
  alle Übersetzungsaufrufe, Format-Platzhalter, Einstellungen und Inventar-Ausgabe.
  Kein Spielstart; die öffentliche Version bleibt 1.0.0.

## 1.0.0 — 2026-10-24

Erster öffentlicher Release. Eigenständiges Adminmenü mit F1, Gegenstands-/Modulkatalog, Spieler-, Teleport-, Boots- und Weltfunktionen. UE4SS erforderlich und separat zu installieren.

Öffentliche Versionsnummer: 1.0.0. Frühere Entwicklungsbezeichnungen sind keine öffentlichen Releases.
