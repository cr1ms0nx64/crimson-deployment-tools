package main

import (
	"archive/zip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const updaterVersion = 2

const (
	synchronize = 0x00100000
	waitObject0 = 0x00000000
	waitTimeout = 0x00000102
)

var resultLog string
var updaterLog string

type Manifest struct {
	Name              string   `json:"name"`
	Version           string   `json:"version"`
	Build             string   `json:"build"`
	MinUpdaterVersion int      `json:"minUpdaterVersion"`
	Preserve          []string `json:"preserve"`
	Restart           string   `json:"restart"`
}

func messageBox(title, text string, flags uintptr) {
	if runtime.GOOS != "windows" {
		fmt.Println(title + ": " + text)
		return
	}
	user32 := syscall.NewLazyDLL("user32.dll")
	proc := user32.NewProc("MessageBoxW")
	t, _ := syscall.UTF16PtrFromString(title)
	m, _ := syscall.UTF16PtrFromString(text)
	proc.Call(0, uintptr(unsafe.Pointer(m)), uintptr(unsafe.Pointer(t)), flags)
}

func logLine(format string, args ...any) {
	line := fmt.Sprintf(format, args...)
	stamped := fmt.Sprintf("[%s] %s\r\n", time.Now().Format("2006-01-02 15:04:05.000"), line)
	if updaterLog != "" {
		_ = os.MkdirAll(filepath.Dir(updaterLog), 0755)
		f, err := os.OpenFile(updaterLog, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
		if err == nil {
			_, _ = f.WriteString(stamped)
			_ = f.Close()
		}
	}
}

func writeResult(lines ...string) {
	if resultLog == "" {
		return
	}
	_ = os.MkdirAll(filepath.Dir(resultLog), 0755)
	text := strings.Join(lines, "\r\n") + "\r\n"
	_ = os.WriteFile(resultLog, []byte(text), 0644)
}

func argValue(name string) string {
	for i, a := range os.Args {
		if a == name && i+1 < len(os.Args) {
			return os.Args[i+1]
		}
		prefix := name + "="
		if strings.HasPrefix(a, prefix) {
			return strings.TrimPrefix(a, prefix)
		}
	}
	return ""
}

func cleanSlash(p string) string {
	return strings.ReplaceAll(p, "\\", "/")
}

func isUnsafeZipPath(name string) bool {
	n := cleanSlash(name)
	if n == "" || strings.HasPrefix(n, "/") || strings.Contains(n, "\x00") {
		return true
	}
	if len(n) >= 3 && ((n[1] == ':' && n[2] == '/') || (n[1] == ':' && n[2] == '\\')) {
		return true
	}
	parts := strings.Split(n, "/")
	for _, part := range parts {
		if part == ".." {
			return true
		}
	}
	return false
}

func readManifest(zipPath string) (Manifest, error) {
	zr, err := zip.OpenReader(zipPath)
	if err != nil {
		return Manifest{}, err
	}
	defer zr.Close()
	var manifest Manifest
	var foundManifest, foundApp bool
	for _, f := range zr.File {
		name := cleanSlash(f.Name)
		if isUnsafeZipPath(name) {
			return Manifest{}, fmt.Errorf("unsicherer Pfad im Update Paket: %s", name)
		}
		if name == "update.json" {
			foundManifest = true
			rc, err := f.Open()
			if err != nil {
				return Manifest{}, err
			}
			data, err := io.ReadAll(rc)
			_ = rc.Close()
			if err != nil {
				return Manifest{}, err
			}
			if err := json.Unmarshal(data, &manifest); err != nil {
				return Manifest{}, err
			}
		}
		if strings.HasPrefix(name, "app/") && !strings.HasSuffix(name, "/") {
			foundApp = true
		}
	}
	if !foundManifest {
		return Manifest{}, errors.New("update.json fehlt")
	}
	if !foundApp {
		return Manifest{}, errors.New("app Ordner fehlt")
	}
	if manifest.Version == "" {
		return Manifest{}, errors.New("version fehlt in update.json")
	}
	if manifest.Restart == "" {
		return Manifest{}, errors.New("restart fehlt in update.json")
	}
	if manifest.MinUpdaterVersion > updaterVersion {
		return Manifest{}, fmt.Errorf("Updater ist zu alt. Benötigt: %d, vorhanden: %d", manifest.MinUpdaterVersion, updaterVersion)
	}
	return manifest, nil
}

func extractZipApp(zipPath, dest string) error {
	zr, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer zr.Close()
	for _, f := range zr.File {
		name := cleanSlash(f.Name)
		if isUnsafeZipPath(name) {
			return fmt.Errorf("unsicherer Pfad im Update Paket: %s", name)
		}
		if !strings.HasPrefix(name, "app/") {
			continue
		}
		rel := strings.TrimPrefix(name, "app/")
		if rel == "" {
			continue
		}
		target := filepath.Join(dest, filepath.FromSlash(rel))
		if !strings.HasPrefix(filepath.Clean(target)+string(os.PathSeparator), filepath.Clean(dest)+string(os.PathSeparator)) && filepath.Clean(target) != filepath.Clean(dest) {
			return fmt.Errorf("Pfad außerhalb des Zielordners: %s", rel)
		}
		if strings.HasSuffix(name, "/") {
			if err := os.MkdirAll(target, 0755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return err
		}
		rc, err := f.Open()
		if err != nil {
			return err
		}
		out, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, f.Mode())
		if err != nil {
			_ = rc.Close()
			return err
		}
		_, copyErr := io.Copy(out, rc)
		closeErr := out.Close()
		_ = rc.Close()
		if copyErr != nil {
			return copyErr
		}
		if closeErr != nil {
			return closeErr
		}
	}
	return nil
}

func shouldPreserve(rel string, preserve []string) bool {
	r := strings.Trim(cleanSlash(rel), "/")
	defaults := []string{"config/servers.json", "logs", "logs/", "backups", "backups/"}
	all := append(defaults, preserve...)
	for _, p := range all {
		pp := strings.Trim(cleanSlash(p), "/")
		if pp == "" {
			continue
		}
		if strings.HasSuffix(cleanSlash(p), "/") || pp == "logs" || pp == "backups" {
			if r == pp || strings.HasPrefix(r, pp+"/") {
				return true
			}
		} else if r == pp {
			return true
		}
	}
	return false
}

func copyFile(src, dst string, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, in)
	closeErr := out.Close()
	if err != nil {
		return err
	}
	return closeErr
}

func copyTree(src, dst string, preserve []string, usePreserve bool) error {
	return filepath.WalkDir(src, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		relSlash := cleanSlash(rel)
		if usePreserve && shouldPreserve(relSlash, preserve) {
			if d.IsDir() {
				return filepath.SkipDir
			}
			logLine("Behalte vorhandene Datei: %s", relSlash)
			return nil
		}
		target := filepath.Join(dst, rel)
		info, err := d.Info()
		if err != nil {
			return err
		}
		if d.IsDir() {
			return os.MkdirAll(target, info.Mode())
		}
		return copyFile(path, target, info.Mode())
	})
}

func backupCurrent(root string) (string, error) {
	backups := filepath.Join(root, "backups")
	if err := os.MkdirAll(backups, 0755); err != nil {
		return "", err
	}
	backup := filepath.Join(backups, "app-backup-"+time.Now().Format("20060102-150405"))
	preserve := []string{"logs/", "backups/"}
	if err := copyTree(root, backup, preserve, true); err != nil {
		return "", err
	}
	return backup, nil
}

func restoreBackup(backup, root string) error {
	preserve := []string{"logs/", "backups/", "config/servers.json"}
	return copyTree(backup, root, preserve, true)
}

func waitPID(pidString string, timeout time.Duration) error {
	if pidString == "" {
		return nil
	}
	pid, err := strconv.Atoi(pidString)
	if err != nil || pid <= 0 {
		return nil
	}
	logLine("Warte auf Prozess PID %d", pid)
	if runtime.GOOS != "windows" {
		deadline := time.Now().Add(timeout)
		for time.Now().Before(deadline) {
			if p, err := os.FindProcess(pid); err != nil || p == nil {
				return nil
			}
			time.Sleep(350 * time.Millisecond)
		}
		return fmt.Errorf("Prozess PID %d wurde nicht innerhalb von %s beendet", pid, timeout)
	}
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	openProcess := kernel32.NewProc("OpenProcess")
	waitForSingleObject := kernel32.NewProc("WaitForSingleObject")
	closeHandle := kernel32.NewProc("CloseHandle")

	handle, _, _ := openProcess.Call(uintptr(synchronize), 0, uintptr(pid))
	if handle == 0 {
		logLine("Prozess PID %d ist bereits beendet", pid)
		return nil
	}
	defer closeHandle.Call(handle)
	waitMs := uintptr(timeout / time.Millisecond)
	result, _, _ := waitForSingleObject.Call(handle, waitMs)
	if result == waitObject0 {
		logLine("Prozess PID %d beendet", pid)
		return nil
	}
	if result == waitTimeout {
		return fmt.Errorf("Prozess PID %d wurde nicht innerhalb von %s beendet", pid, timeout)
	}
	return fmt.Errorf("Warten auf Prozess PID %d fehlgeschlagen, Code: %d", pid, result)
}

func waitExeUnlocked(path string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	tmp := path + ".unlocktest"
	var lastErr error
	for time.Now().Before(deadline) {
		err := os.Rename(path, tmp)
		if err == nil {
			_ = os.Rename(tmp, path)
			logLine("EXE ist frei: %s", path)
			return nil
		}
		lastErr = err
		time.Sleep(350 * time.Millisecond)
	}
	if lastErr != nil {
		return fmt.Errorf("EXE blieb gesperrt: %s (%w)", path, lastErr)
	}
	return fmt.Errorf("EXE blieb gesperrt: %s", path)
}

func launchApp(root, mainName string) (*exec.Cmd, error) {
	exe := filepath.Join(root, mainName)
	cmd := exec.Command(exe)
	cmd.Dir = root
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x00000010}
	return cmd, cmd.Start()
}

func run() error {
	root := argValue("--root")
	pkg := argValue("--package")
	mainName := argValue("--main")
	pid := argValue("--pid")
	psPID := argValue("--pspid")
	if root == "" || pkg == "" {
		return errors.New("Updater Argumente fehlen")
	}
	if mainName == "" {
		mainName = "Crimson Deploy Tool.exe"
	}
	rootAbs, _ := filepath.Abs(root)
	root = rootAbs
	logs := filepath.Join(root, "logs")
	updaterLog = filepath.Join(logs, "crimson-updater-"+time.Now().Format("20060102-150405")+".log")
	resultLog = filepath.Join(logs, "last-update-result.log")
	logLine("Crimson Updater v2 gestartet")
	logLine("Root: %s", root)
	logLine("Package: %s", pkg)

	manifest, err := readManifest(pkg)
	if err != nil {
		return fmt.Errorf("Update Paket ungültig: %w", err)
	}
	logLine("Update Version: %s", manifest.Version)
	if err := waitPID(psPID, 60*time.Second); err != nil {
		return fmt.Errorf("PowerShell Oberfläche wurde nicht sauber beendet: %w", err)
	}
	if err := waitPID(pid, 60*time.Second); err != nil {
		return fmt.Errorf("Launcher wurde nicht sauber beendet: %w", err)
	}
	if err := waitExeUnlocked(filepath.Join(root, mainName), 90*time.Second); err != nil {
		return fmt.Errorf("App Datei ist noch gesperrt. Update wurde nicht angewendet: %w", err)
	}

	backup, err := backupCurrent(root)
	if err != nil {
		return fmt.Errorf("Backup fehlgeschlagen: %w", err)
	}
	logLine("Backup erstellt: %s", backup)

	temp, err := os.MkdirTemp("", "crimson-update-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temp)
	appTemp := filepath.Join(temp, "app")
	if err := os.MkdirAll(appTemp, 0755); err != nil {
		return err
	}
	if err := extractZipApp(pkg, appTemp); err != nil {
		return fmt.Errorf("Entpacken fehlgeschlagen: %w", err)
	}
	logLine("Update entpackt")

	updatePreserve := append([]string{}, manifest.Preserve...)
	updatePreserve = append(updatePreserve, "Crimson Updater.exe")
	if err := copyTree(appTemp, root, updatePreserve, true); err != nil {
		logLine("Kopieren fehlgeschlagen, starte Rollback: %s", err)
		_ = restoreBackup(backup, root)
		return fmt.Errorf("Update fehlgeschlagen und Rollback ausgeführt: %w", err)
	}
	logLine("Dateien ersetzt")
	writeResult(
		"App Update erfolgreich installiert.",
		"Version: "+manifest.Version,
		"Backup: "+backup,
	)

	cmd, err := launchApp(root, manifest.Restart)
	if err != nil {
		logLine("Neustart fehlgeschlagen, starte Rollback: %s", err)
		_ = restoreBackup(backup, root)
		_, _ = launchApp(root, mainName)
		return fmt.Errorf("Neue App konnte nicht gestartet werden. Rollback ausgeführt: %w", err)
	}
	logLine("App neu gestartet, PID: %d", cmd.Process.Pid)
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		logLine("Neue App wurde sehr schnell beendet: %v", err)
		_ = restoreBackup(backup, root)
		writeResult("Update wurde zurückgerollt, weil die neue App direkt beendet wurde.", "Backup: "+backup)
		_, _ = launchApp(root, mainName)
		return errors.New("neue App wurde direkt beendet, Rollback ausgeführt")
	case <-time.After(5 * time.Second):
		logLine("Update erfolgreich abgeschlossen")
		return nil
	}
}

func main() {
	if err := run(); err != nil {
		logLine("FEHLER: %s", err)
		writeResult("App Update fehlgeschlagen.", "Fehler: "+err.Error())
		messageBox("Crimson Updater", "Update fehlgeschlagen. Details stehen im logs Ordner.\n\n"+err.Error(), 0x00000010)
		os.Exit(1)
	}
}
