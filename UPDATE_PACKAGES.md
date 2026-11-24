# Update-Pakete

Nach `build.ps1` erzeugt `tools/Create-UpdatePackage.ps1 -Version 1.0.2` ein ZIP:

```text
update.json
app/
  Crimson Deploy Tool.exe
  app/
    layout.json
    update.json
    Crimson Updater.exe
    assets/
    config/*.example.json
```

Die äußere Ebene `app/` ist der Paketinhalt für den Installationsordner; der innere Ordner enthält die Laufzeitdateien. Version und Manifest müssen zum gebauten Programm passen.

Das neue Layout benötigt **Updater 3**. Ältere Installationen einmalig manuell auf das vollständige Programmpaket umstellen. Der normale Updateweg prüft Layout, Mindestversion, doppelte Dateipfade und die enthaltene Neustartdatei. Persönliche Profile, Einstellungen, Zustand, Logs und Backups sind geschützt und werden nicht in Pakete aufgenommen.

Die Anwendung ersetzt ihre gerade laufende Updater-EXE nicht selbst. Änderungen am Updater über das vollständige Programmpaket bei geschlossener App übernehmen.

Die Paketierung startet weder Updater noch Deployment und erstellt keine Sicherungen. Der bestehende Updater legt beim tatsächlichen Installieren weiterhin eine Anwendungssicherung an. Format- und Versionsprüfung ersetzen keine Signaturprüfung.
