# Manuelle Abnahme · 1.0.1

Diese Schritte sind nicht automatisiert und benötigen eine geeignete Testumgebung. Produktive Deployments und Sicherungen nur nach ausdrücklicher Freigabe ausführen.

1. Update von 1.0.0 auf 1.0.1 installieren.
2. App starten und prüfen, dass im Log Crimson Deploy Tool WPF 1.0.1 gestartet steht.
3. Prüfen, dass keine Warnung zur Rekonstruktion des Deploy Verlaufs erscheint.
4. Online-Status und Zusammenfassung gegen die tatsächlich konfigurierten Server prüfen.
5. Optional nach ausdrücklicher Freigabe: lokale Konfigurationssicherung prüfen.
6. Preflight Hub prüfen.
7. Preflight ACP prüfen.
8. ACP Deploy mit SemVer Paket testen.
9. App neu starten und Deploy State prüfen.
