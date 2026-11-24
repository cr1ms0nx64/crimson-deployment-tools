# Crimson Deployment Tools

Windows-Werkzeug für SSH-basierte Deployments der Hub- und ACP-Anwendungen. Die Oberfläche nutzt **PowerShell/WPF**; Launcher und lokaler App-Updater sind in **Go** geschrieben.

## Funktionen

- Serverprofile, Verbindungsprüfung und Deployment-Preflight.
- ZIP-Pakete mit Versionsprüfung, Upload per SCP und Ausführung per SSH.
- Deployment-Verlauf, Livefeed und Rollback-Auswahl.
- Lokale Konfigurationssicherungen und Update-Pakete für das Tool selbst.

## Starten

Benötigt werden Windows, Windows PowerShell mit WPF sowie OpenSSH-Client (`ssh.exe`, `scp.exe`).

```powershell
.\Start-Debug.cmd
```

Server im Dialog anlegen oder `config/servers.example.json` als Vorlage für `config/servers.json` verwenden. Die Vorlage enthält ausschließlich Beispieladressen. Private SSH-Schlüssel bleiben außerhalb des Repositorys.

App-Einstellungen entstehen beim ersten Start lokal; `config/app-settings.example.json` dokumentiert die Standardwerte.

## Bauen

Mit **Go ab 1.23**:

```powershell
.\build.ps1
```

Erzeugt `Crimson Deploy Tool.exe`, den kompatiblen Launcher-Namen `Crimson Native Deployer.exe` und `Crimson Updater.exe` für Windows x64. Die EXEs sind Build-Ausgaben und werden nicht versioniert. Die `.syso`-Dateien enthalten die benötigten Windows-Iconressourcen.

Update-Paket erstellen:

```powershell
.\tools\Create-UpdatePackage.ps1 -Version 1.0.1
```

Details: [Update-Pakete](UPDATE_PACKAGES.md) · [Änderungen](CHANGELOG.md) · [manuelle Abnahme](TESTPLAN.md).

Log- und Support-Export-Maskierung isoliert testen: `.\tests\Redaction.Tests.ps1`. Dabei werden weder Oberfläche noch SSH-Aktionen gestartet.

## Daten und Grenzen

Persönliche Serverprofile, Deployment-Zustand, Logs, Laufzeitdateien und Sicherungen werden lokal gespeichert und nicht eingecheckt. Update-Pakete enthalten nur ausdrücklich freigegebene Dateien.

Deployments sind auf die vorhandenen Hub-/ACP-Verzeichnisse und Dienste zugeschnitten; das Tool ist kein allgemeiner Deployer. Die bestehenden Abläufe können Sicherungen anlegen, ältere Sicherungen entfernen und Dienste neu starten. Vor produktiven Aktionen Ziel und erzeugtes Skript prüfen. Die Paketprüfung ersetzt keine kryptografische Signaturprüfung.
