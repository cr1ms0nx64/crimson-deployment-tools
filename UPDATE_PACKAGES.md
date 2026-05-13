# Crimson Deploy Tool Update Pakete

1.0.0 Stable nutzt Semantic Versioning.
Config, Logs und Backups bleiben bei Updates erhalten.

# Crimson Update Pakete

Ab v22 kann die App über ein Update Paket gepatcht werden.

Ablauf:
1. Update Paket als ZIP herunterladen.
2. App öffnen.
3. Links unten App Update verwenden.
4. Update Paket wählen.
5. Installieren und neu starten klicken.

Struktur eines gültigen Update Pakets:

```text
update.json
app/
  Crimson Native Deployer.exe
  Crimson Updater.exe
  assets/
  runtime/
  src-wpf/
  src-updater/
  config/
```

`config/servers.json`, `logs/` und `backups/` werden beim Patchen geschützt und nicht überschrieben.

Bei jedem Update wird automatisch ein Backup unter `backups/app-backup-YYYYMMDD-HHMMSS` erstellt.
