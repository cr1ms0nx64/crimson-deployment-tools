Crimson Native Deployer v12 WPF

Fixes:
- PowerShell ParserError bei Remote SCP Pfad behoben.
- $user@$hostName:/tmp/$fileName wurde auf ${user}@${hostName}:/tmp/${fileName} korrigiert.
- Start-Debug.cmd und Wrapper Logs bleiben enthalten.

Start:
1. Kompletten Ordner entpacken.
2. Crimson Native Deployer.exe starten.
3. Falls Windows blockt, Start-Debug.cmd starten und logs Ordner prüfen.
