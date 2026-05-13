Crimson Native Deployer WPF v22

Fixes:
1. Updater wartet jetzt korrekt auf PowerShell und Launcher Prozess.
2. Update bricht sauber ab, wenn die Haupt EXE noch gesperrt ist.
3. Rollback greift nicht mehr auf laufende Dateien zu.
4. Crimson Updater.exe wird beim Patch nicht während der Laufzeit überschrieben.
5. Update Neustart wurde stabilisiert.

Hinweis:
v22 muss einmalig manuell entpackt werden, weil der Updater aus v21 genau den Datei Lock Fehler auslösen kann. Ab v22 sollten künftige Update Pakete direkt über die App installierbar sein.
