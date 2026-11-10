package rexconfig

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestApplyCreatesAndStaysIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rex", "init.lua")
	created, err := Apply(path, "/opt/r/share/raptor/init.lua", DefaultOptions(), false)
	if err != nil || !created {
		t.Fatalf("%v", err)
	}
	text, _ := os.ReadFile(path)
	for _, want := range []string{beginMarker, `dofile("/opt/r/share/raptor/init.lua")`, `rex.bind("shift+cmd+o", "raptor")`, endMarker} {
		if !strings.Contains(string(text), want) {
			t.Fatalf("missing %q in %s", want, text)
		}
	}
	created, err = Apply(path, "/opt/r/share/raptor/init.lua", DefaultOptions(), false)
	if err != nil || created {
		t.Fatalf("reapply must edit in place: created=%v err=%v", created, err)
	}
	text2, _ := os.ReadFile(path)
	if string(text) != string(text2) {
		t.Fatal("idempotent rerun changed the file")
	}
}

func TestApplyReplacesManagedBlockAndTrailingContent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "init.lua")
	write(t, path, "rex.bind(\"cmd+k\", \"pane.send_key\")\n"+beginMarker+"\nold-stuff\nrequire(\"raptor\").setup{}\n"+endMarker+"\nrex.bind(\"cmd+b\", \"client.sidebar.toggle\")\n")
	if _, err := Apply(path, "/new/plugin.lua", Options{}, false); err != nil {
		t.Fatal(err)
	}
	text, _ := os.ReadFile(path)
	if strings.Contains(string(text), "old-stuff") {
		t.Fatalf("managed block not replaced: %s", text)
	}
	if !strings.Contains(string(text), "cmd+k") || !strings.Contains(string(text), "cmd+b") || !strings.Contains(string(text), "/new/plugin.lua") {
		t.Fatalf("surrounding config damaged: %s", text)
	}
}

func TestApplyRefusesForeignRaptorConfig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "init.lua")
	write(t, path, "rex.bind(\"shift+cmd+o\", function() rex.invoke(\"raptor\") end)\n")
	if _, err := Apply(path, "", DefaultOptions(), false); err == nil {
		t.Fatal("foreign raptor wiring must be refused")
	}
	text, _ := os.ReadFile(path)
	if strings.Contains(string(text), beginMarker) {
		t.Fatal("refused run must not modify the file")
	}
	if _, err := Apply(path, "", DefaultOptions(), true); err != nil {
		t.Fatal(err)
	}
	text, _ = os.ReadFile(path)
	if strings.Count(string(text), "invoke(\"raptor\")") != 1 || !strings.Contains(string(text), beginMarker) {
		t.Fatalf("force merge damaged the config: %s", text)
	}
}

func TestApplyTruncatedMarkersFailClosed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "init.lua")
	write(t, path, beginMarker+"\nbroken\n")
	if _, err := Apply(path, "", DefaultOptions(), true); err == nil {
		t.Fatal("truncated markers must fail closed")
	}
}

func TestApplyRequireFallbackAndCommentsIgnored(t *testing.T) {
	path := filepath.Join(t.TempDir(), "init.lua")
	write(t, path, "-- raptor bindings live in the managed block below\n")
	if _, err := Apply(path, "", DefaultOptions(), false); err != nil {
		t.Fatal(err)
	}
	text, _ := os.ReadFile(path)
	if !strings.Contains(string(text), `require("raptor")`) {
		t.Fatalf("missing plugin fallback: %s", text)
	}
}

func TestConfigPathEnv(t *testing.T) {
	t.Setenv("REX_CONFIG", "/custom/rex.lua")
	if got := ConfigPath(); got != "/custom/rex.lua" {
		t.Fatal(got)
	}
	os.Unsetenv("REX_CONFIG")
	t.Setenv("XDG_CONFIG_HOME", "/xdg")
	if got := ConfigPath(); got != filepath.Join("/xdg", "rex", "init.lua") {
		t.Fatal(got)
	}
}

func TestLocatePluginFindsAppBundle(t *testing.T) {
	root := t.TempDir()
	app := filepath.Join(root, "Applications", "Raptor.app")
	write(t, filepath.Join(app, "Contents", "MacOS", "Raptor"), "binary")
	write(t, filepath.Join(app, "Contents", "Resources", "rex", "init.lua"), "-- plugin")
	t.Setenv("HOME", root)
	t.Setenv("HOMEBREW_PREFIX", "")
	t.Setenv("REX_CONFIG", filepath.Join(root, "rex.lua"))
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(root, "config"))
	if got := LocatePlugin(); got != filepath.Join(app, "Contents", "Resources", "rex", "init.lua") {
		t.Fatalf("got %q", got)
	}
}
