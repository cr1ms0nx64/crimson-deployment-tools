package main

import (
	"archive/zip"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestArchivePaths(t *testing.T) {
	for _, name := range []string{"../outside", "app/../../outside", "C:/outside", "C:outside", "app/payload:stream", "/absolute", `\\server\share`, "app/CON.txt", "app/nul", "app/LPT1.log", "app/trailing.", "app/trailing ", "app//double", "app/./file", ""} {
		t.Run(name, func(t *testing.T) {
			if !isUnsafeZipPath(name) {
				t.Fatalf("accepted unsafe path %q", name)
			}
		})
	}
	for _, name := range []string{"update.json", "app/Crimson Deploy Tool.exe", "app/app/assets/logo.png", "app/app/", "app/app/de-DE/messages.json"} {
		t.Run(name, func(t *testing.T) {
			if isUnsafeZipPath(name) {
				t.Fatalf("rejected safe path %q", name)
			}
		})
	}
}
func archive(t *testing.T, entries [][2]string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "package.zip")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	for _, entry := range entries {
		w, err := writer.Create(entry[0])
		if err != nil {
			t.Fatal(err)
		}
		if _, err = w.Write([]byte(entry[1])); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}
func TestManifest(t *testing.T) {
	for _, tc := range []struct {
		name, restart string
		min           int
		entry         string
		valid         bool
	}{
		{"valid", "Crimson Deploy Tool.exe", 3, "app/Crimson Deploy Tool.exe", true},
		{"restart traversal", "../outside.exe", 3, "app/payload", false},
		{"missing executable", "Crimson Deploy Tool.exe", 3, "app/payload", false},
		{"new updater required", "Crimson Deploy Tool.exe", 99, "app/Crimson Deploy Tool.exe", false},
		{"ADS", "Crimson Deploy Tool.exe", 3, "app/payload:stream", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			manifest, _ := json.Marshal(Manifest{Version: "1.0.2", Restart: tc.restart, MinUpdaterVersion: tc.min, LayoutVersion: 2})
			_, err := readManifest(archive(t, [][2]string{{"update.json", string(manifest)}, {tc.entry, "synthetic executable"}}))
			if (err == nil) != tc.valid {
				t.Fatalf("valid=%v err=%v", tc.valid, err)
			}
		})
	}
}
func TestDuplicateAndSymlink(t *testing.T) {
	manifest := `{"version":"1.0.2","restart":"Crimson Deploy Tool.exe"}`
	_, err := readManifest(archive(t, [][2]string{{"update.json", manifest}, {"app/Crimson Deploy Tool.exe", "one"}, {"APP/CRIMSON DEPLOY TOOL.EXE", "two"}}))
	if err == nil {
		t.Fatal("duplicate Windows path accepted")
	}
	path := filepath.Join(t.TempDir(), "symlink.zip")
	file, _ := os.Create(path)
	w := zip.NewWriter(file)
	header := &zip.FileHeader{Name: "app/link"}
	header.SetMode(os.ModeSymlink | 0777)
	entry, _ := w.CreateHeader(header)
	entry.Write([]byte("outside"))
	w.Close()
	file.Close()
	if _, err := readManifest(path); err == nil {
		t.Fatal("symlink accepted")
	}
}
func TestPreservation(t *testing.T) {
	for _, path := range []string{"config/servers.json", "app/config/servers.json", "APP/CONFIG/APP-SETTINGS.JSON", "app/logs/deploy.log", "app/backups/existing.zip"} {
		if !shouldPreserve(path, nil) {
			t.Errorf("unprotected %s", path)
		}
	}
	if shouldPreserve("app/assets/logo.png", nil) {
		t.Fatal("application asset incorrectly preserved")
	}
}
func TestCopyKeepsPersonalSettings(t *testing.T) {
	src, dst := t.TempDir(), t.TempDir()
	for _, root := range []string{src, dst} {
		os.MkdirAll(filepath.Join(root, "app", "config"), 0755)
	}
	os.WriteFile(filepath.Join(src, "app", "config", "servers.json"), []byte("replacement"), 0600)
	os.WriteFile(filepath.Join(dst, "app", "config", "servers.json"), []byte("original"), 0600)
	os.WriteFile(filepath.Join(src, "Crimson Deploy Tool.exe"), []byte("synthetic executable"), 0600)
	if err := copyTree(src, dst, nil, true); err != nil {
		t.Fatal(err)
	}
	value, _ := os.ReadFile(filepath.Join(dst, "app", "config", "servers.json"))
	if string(value) != "original" {
		t.Fatal("personal settings overwritten")
	}
	if _, err := os.Stat(filepath.Join(dst, "Crimson Deploy Tool.exe")); err != nil {
		t.Fatal(err)
	}
}
func TestDataRoot(t *testing.T) {
	root := t.TempDir()
	if dataRoot(root) != root {
		t.Fatal("legacy layout not recognized")
	}
	os.Mkdir(filepath.Join(root, "app"), 0755)
	os.WriteFile(filepath.Join(root, "app", "layout.json"), []byte(`{"layoutVersion":2}`), 0600)
	if dataRoot(root) != filepath.Join(root, "app") {
		t.Fatal("clean layout not recognized")
	}
}
