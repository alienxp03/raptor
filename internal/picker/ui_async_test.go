package picker

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func pickerRexLog(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	t.Setenv("PICKER_REX_LOG", log)
	t.Setenv("PATH", dir)
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$PICKER_REX_LOG\"\nif [ \"$1\" = ls ]; then\n  printf '%s\\n' '{\"sessions\":[]}'\nelse\n  printf '%s\\n' '{}'\nfi\n"
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return log
}

func TestPickerResumeRestartsPendingLoads(t *testing.T) {
	m := &dirModel{}
	m.loadLauncherSessions(false)
	before := m.launcherSessionsRequest
	if m.Init() == nil || m.launcherSessionsRequest <= before {
		t.Fatal("resume must restart interrupted session loads")
	}
}

func TestLauncherStartupIsAsync(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	log := pickerRexLog(t)
	m := newDirModel(rex.Ctx{}, config.Default(), false, 0)
	if m.viewMode != 0 || m.launcherSessionsLoading {
		t.Fatal("startup must select launcher")
	}
	m.Update(tea.WindowSizeMsg{Width: 80, Height: 10})
	if m.Init() == nil {
		t.Fatal("missing async loads")
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatal("startup blocked on Rex")
	}
}

func TestLauncherRefreshPreservesManualSelection(t *testing.T) {
	m := &dirModel{hostDirs: map[string][]catalog.Directory{rex.LocalHostLabel: {{Label: "a", Path: "/a"}, {Label: "b", Path: "/b"}}}, hostOrder: []string{rex.LocalHostLabel}}
	m.applyLauncher()
	m.Update(tea.KeyMsg{Type: tea.KeyDown})
	m.loadLauncherSessions(false)
	request := m.launcherSessionsRequest
	m.Update(launcherSessionsMsg{request: request + 1})
	if !m.launcherSessionsLoading {
		t.Fatal("accepted stale sessions")
	}
	m.Update(launcherSessionsMsg{request: request, groups: []rex.HostGroup{{Label: rex.LocalHostLabel, Local: true, Reachable: true, Entries: []rex.SessionEntry{{Kind: "session", ID: "s", Label: "work"}}}}})
	if r := m.selectedLauncher(); r == nil || r.dir == nil || r.dir.Path != "/b" {
		t.Fatalf("manual selection moved: %+v", r)
	}
	m.launcherDirsPending = map[string]uint64{rex.LocalHostLabel: 1}
	m.Update(launcherDirsMsg{host: rex.LocalHostLabel, request: 1, items: []catalog.Directory{{Label: "new", Path: "/new"}, {Label: "b", Path: "/b"}}})
	if r := m.selectedLauncher(); r == nil || r.dir == nil || r.dir.Path != "/b" {
		t.Fatalf("directory refresh moved selection: %+v", r)
	}
}

func TestLauncherNoPillsOrRemovedFooterActions(t *testing.T) {
	m := &dirModel{width: 100, height: 12, target: "tab", hostDirs: map[string][]catalog.Directory{}}
	seedLauncher(m, []launcherRow{{dir: &catalog.Directory{Label: "demo", Path: "/demo"}, host: rex.LocalHostLabel}})
	view := ansi.Strip(m.View())
	for _, gone := range []string{"Agents", "Sessions ·", "agents", "^t", "⇥"} {
		if strings.Contains(view, gone) {
			t.Fatalf("removed UI %q in %q", gone, view)
		}
	}
	if !strings.Contains(view, "new worktree") {
		t.Fatal("missing create shortcut")
	}
}
