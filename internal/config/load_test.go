package config

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestLoadQuotedTargetsWithSpaces(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	dir := filepath.Join(home, ".config", "raptor")
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	for _, value := range []string{
		`["tab", "session", "here", "pane_right", "pane_below"]`,
		`['tab', 'session', 'here', 'pane_right', 'pane_below']`,
	} {
		if err := os.WriteFile(filepath.Join(dir, "config.toml"), []byte("targets = "+value+"\n"), 0600); err != nil {
			t.Fatal(err)
		}
		want := []string{"tab", "session", "here", "pane_right", "pane_below"}
		if got := Load().Targets; !reflect.DeepEqual(got, want) {
			t.Fatalf("%s: got %#v, want %#v", value, got, want)
		}
	}
}
