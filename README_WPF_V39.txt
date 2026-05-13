Crimson Deploy Tool v39

Fixes:
- TCP Vorprüfung blockiert Deploy nicht mehr hart.
- TCP Timeout wird nur noch als Warnung geloggt.
- SCP/SSH Upload wird trotz unklarem TCP Probe Ergebnis gestartet.
- TCP Probe Timeout auf 15 Sekunden erhöht.
- SSH ConnectTimeout auf 20 Sekunden erhöht.
- V38 UI Anpassungen bleiben enthalten.

Hinweis:
Wenn SCP/SSH danach trotzdem fehlschlägt, wird der echte Fehler von scp.exe oder ssh.exe geloggt.
