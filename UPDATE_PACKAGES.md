# Update-Pakete

Nach `build.ps1` erstellt `tools/Create-UpdatePackage.ps1` ein ZIP mit dieser Struktur:

```text
update.json
app/
  update.json
  Crimson Deploy Tool.exe
  Crimson Native Deployer.exe
  Crimson Updater.exe
  assets/
  src-wpf/
  src-updater/
  tools/
```

Das Manifest enthält Version, benötigte Updater-Version, Neustartdatei und die zu erhaltenden Pfade. Die Paketierung bricht bei fehlenden Pflichtdateien ab und überschreibt kein vorhandenes ZIP.

Persönliche Serverprofile, App-Einstellungen, Deployment-/Gesundheitszustand, `logs/`, `backups/` und `runtime/` werden nicht verpackt. Der Updater erhält die im Manifest angegebenen lokalen Daten. Er legt beim Anwenden eines Updates selbst eine lokale Anwendungssicherung an; die Paketierung startet weder Updater noch Deployment.

In der App **App Update → Paket wählen → Installieren und neu starten** verwenden. Nur vertrauenswürdige Pakete installieren: Format- und Versionsprüfung sind keine Signaturprüfung.
