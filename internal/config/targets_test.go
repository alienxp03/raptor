package config

import (
	"reflect"
	"testing"
)

func TestAvailableTargets(t *testing.T) {
	all := []string{"session", "tab", "here", "pane_right", "pane_below"}
	for _, cfg := range []Config{Default(), {}} {
		if got := cfg.AvailableTargets(true); !reflect.DeepEqual(got, all) {
			t.Fatalf("shared target order: %v", got)
		}
		if got := cfg.AvailableTargets(false); !reflect.DeepEqual(got, []string{"session", "tab"}) {
			t.Fatalf("targets without origin pane: %v", got)
		}
	}
	custom := Config{Targets: []string{"session", "pane_below", "tab", "session"}}
	if got := custom.AvailableTargets(true); !reflect.DeepEqual(got, []string{"session", "pane_below", "tab"}) {
		t.Fatalf("custom order must be preserved without adding extra targets: %v", got)
	}
}
