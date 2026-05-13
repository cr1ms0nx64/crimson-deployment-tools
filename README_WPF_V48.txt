Crimson Deploy Tool v48

Neu:
- Subwindows verwenden nun das Crimson App Icon und die dunkle System Titlebar.
- Server Verwaltung wurde optisch angepasst: dunkle Inputs, bessere Abstände, saubere Button Farben.
- Cloud Backup kann lokal oder direkt über MinIO erfolgen.
- MinIO Settings: Endpoint, Bucket, Prefix, Access Key, Secret Key, Region, HTTPS.
- Config Backup erstellt weiterhin ein lokales ZIP und lädt es bei MinIO Modus in den Bucket hoch.

Hinweis MinIO:
- Bucket vorher in MinIO anlegen.
- Endpoint ohne oder mit Schema eintragen, z.B. https://s3.example.tld oder 10.0.0.5:9000.
- Prefix ist optional, z.B. crimson-deploy-tool/config-backups.
