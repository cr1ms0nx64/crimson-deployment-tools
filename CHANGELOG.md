# Änderungen

## 1.0.1

- Versionsanzeige korrigiert.
- Rekonstruktion des Deployment-Verlaufs gegen leere oder beschädigte Logs abgesichert.
- Online-Status zeigt die geprüften Server statt interner Schlüssel.

## 1.0.0

- Semantic Versioning, Deployment-Zustand und erweiterte Preflight-Prüfung.
- Serververwaltung, Rollback-Auswahl, Livefeed und Update-Vorschau.
- Lokale Konfigurationssicherungen; MinIO-Anbindung entfernt.

## Repository-Bereinigung

- Versionsbezogene Einzel-READMEs zusammengeführt; ältere Notizen bleiben in der Git-Historie.
- Kompilierte EXEs aus dem Quellbaum entfernt und Build-Skript ergänzt.
- Debugstarter verwendet relative Pfade.
- Update-Paketierung übernimmt nur festgelegte Dateien und keine persönliche Laufzeitkonfiguration.
- Log- und Support-Export-Maskierung für Header und JSON korrigiert; unredigierten Fehler-Fallback entfernt.
- Paketmanifest wird auch unter Windows PowerShell ohne UTF-8-BOM geschrieben.
