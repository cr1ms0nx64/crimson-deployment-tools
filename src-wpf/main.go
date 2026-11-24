package main

import (
	"embed"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

//go:embed app.ps1
var embedded embed.FS

const createNoWindow = 0x08000000

func messageBox(title, text string) {
	user32 := syscall.NewLazyDLL("user32.dll")
	proc := user32.NewProc("MessageBoxW")
	t, _ := syscall.UTF16PtrFromString(title)
	m, _ := syscall.UTF16PtrFromString(text)
	proc.Call(0, uintptr(unsafe.Pointer(m)), uintptr(unsafe.Pointer(t)), 0x00000010)
}

func writeLog(path string, lines ...string) {
	_ = os.MkdirAll(filepath.Dir(path), 0755)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	for _, line := range lines {
		_, _ = fmt.Fprintf(f, "[%s] %s\r\n", time.Now().Format("2006-01-02 15:04:05.000"), line)
	}
}

func findPowerShell() string {
	candidates := []string{
		filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
		filepath.Join(os.Getenv("WINDIR"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
		"powershell.exe",
		"pwsh.exe",
	}
	for _, c := range candidates {
		if strings.Contains(c, string(os.PathSeparator)) {
			if st, err := os.Stat(c); err == nil && !st.IsDir() {
				return c
			}
			continue
		}
		if p, err := exec.LookPath(c); err == nil {
			return p
		}
	}
	return "powershell.exe"
}

func main() {
	exe, err := os.Executable()
	if err != nil {
		messageBox("Crimson Deploy Tool", "Startfehler: Pfad der EXE konnte nicht ermittelt werden.")
		return
	}
	root := filepath.Dir(exe)
	appRoot := root
	if _, err := os.Stat(filepath.Join(root, "app", "layout.json")); err == nil {
		appRoot = filepath.Join(root, "app")
	}
	runtimeDir := filepath.Join(appRoot, "runtime")
	logsDir := filepath.Join(appRoot, "logs")
	_ = os.MkdirAll(runtimeDir, 0755)
	_ = os.MkdirAll(logsDir, 0755)
	wrapperLog := filepath.Join(logsDir, "crimson-deployer-wrapper.log")
	psOutputLog := filepath.Join(logsDir, "crimson-deployer-powershell-output.log")

	writeLog(wrapperLog, "Launcher gestartet", "Root: "+root)

	scriptBytes, err := embedded.ReadFile("app.ps1")
	if err != nil {
		writeLog(wrapperLog, "Embedded app.ps1 konnte nicht gelesen werden: "+err.Error())
		messageBox("Crimson Deploy Tool", "Startfehler: app.ps1 konnte nicht gelesen werden. Details im logs Ordner.")
		return
	}
	scriptPath := filepath.Join(runtimeDir, "crimson-deployer-wpf-1.0.2.ps1")
	if len(scriptBytes) < 3 || !(scriptBytes[0] == 0xEF && scriptBytes[1] == 0xBB && scriptBytes[2] == 0xBF) {
		scriptBytes = append([]byte{0xEF, 0xBB, 0xBF}, scriptBytes...)
	}
	if err := os.WriteFile(scriptPath, scriptBytes, 0644); err != nil {
		writeLog(wrapperLog, "app.ps1 konnte nicht geschrieben werden: "+err.Error())
		messageBox("Crimson Deploy Tool", "Startfehler: Runtime Script konnte nicht geschrieben werden. Details im logs Ordner.")
		return
	}

	debugCmd := filepath.Join(appRoot, "Start-Debug.cmd")
	debugBody := "@echo off\r\nset \"CRIMSON_DEPLOYER_ROOT=%~dp0\"\r\nset \"CRIMSON_SCRIPT=%~dp0src-wpf\\app.ps1\"\r\nif not exist \"%CRIMSON_SCRIPT%\" set \"CRIMSON_SCRIPT=%~dp0runtime\\crimson-deployer-wpf-1.0.1.ps1\"\r\necho Starte Crimson Deploy Tool Debug...\r\n\"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File \"%CRIMSON_SCRIPT%\"\r\necho.\r\necho Exit Code: %ERRORLEVEL%\r\npause\r\n"
	if _, statErr := os.Stat(debugCmd); appRoot == root && os.IsNotExist(statErr) {
		_ = os.WriteFile(debugCmd, []byte(debugBody), 0644)
	}

	ps := findPowerShell()
	writeLog(wrapperLog, "PowerShell: "+ps, "Script: "+scriptPath)

	out, _ := os.OpenFile(psOutputLog, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if out != nil {
		defer out.Close()
	}

	cmd := exec.Command(ps, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", scriptPath)
	cmd.Dir = root
	cmd.Env = append(os.Environ(), fmt.Sprintf("CRIMSON_DEPLOYER_ROOT=%s", root), fmt.Sprintf("CRIMSON_DEPLOYER_APP_ROOT=%s", appRoot), fmt.Sprintf("CRIMSON_DEPLOYER_LAUNCHER_PID=%d", os.Getpid()))
	if out != nil {
		cmd.Stdout = out
		cmd.Stderr = out
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow}

	err = cmd.Run()
	if err != nil {
		writeLog(wrapperLog, "PowerShell beendet mit Fehler: "+err.Error())
		messageBox("Crimson Deploy Tool Startfehler", "Die WPF Oberfläche konnte nicht gestartet werden.\n\nDetails stehen im logs Ordner.\n\nFalls nötig, starte Start-Debug.cmd im gleichen Ordner.")
		return
	}
	writeLog(wrapperLog, "PowerShell sauber beendet")
}
