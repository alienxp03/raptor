package picker

import (
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
)

func pickerRecentID(n int) string {
	return fmt.Sprintf("session:00000000-0000-4000-8000-%012d", n)
}

func TestLauncherUsesFrozenSessionRecencyUntilNextPresentation(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	pickerRexLogSessions(t, `{"sessions":[]}`, "")
	now := time.Now()
	for i, n := range []int{2, 5} {
		if err := rex.RecordSessionVisit("", pickerRecentID(n), now.Add(time.Duration(i-5)*time.Minute), false); err != nil {
			t.Fatal(err)
		}
	}
	m := newDirModel(rex.Ctx{Session: pickerRecentID(1)}, config.Default(), false, 0)
	m.sessionRecency = rex.LoadSessionRecency()
	group := rex.HostGroup{Label: rex.LocalHostLabel, Local: true, Reachable: true}
	for n := 1; n <= 6; n++ {
		group.Entries = append(group.Entries, rex.SessionEntry{Kind: "session", ID: pickerRecentID(n), SessionID: pickerRecentID(n), Label: fmt.Sprintf("work%d", n), Host: rex.LocalHostLabel, Active: n == 1})
	}
	m.sessions = []rex.HostGroup{group}
	m.hostOrder = []string{rex.LocalHostLabel}
	m.hostDirs[rex.LocalHostLabel] = []catalog.Directory{{Path: "/folders/a", Label: "a"}, {Path: "/folders/b", Label: "b"}}
	m.applyLauncher()
	order := func() []string {
		ids := []string{}
		for _, match := range m.launcherView {
			if row := m.launcher[match.index]; row.session != nil {
				ids = append(ids, row.session.SessionID)
			}
		}
		return ids
	}
	want := []string{pickerRecentID(1), pickerRecentID(5), pickerRecentID(2), pickerRecentID(3), pickerRecentID(4), pickerRecentID(6)}
	if !reflect.DeepEqual(order(), want) {
		t.Fatalf("initial MRU order = %v", order())
	}
	if m.launcher[6].dir.Path != "/folders/a" || m.launcher[7].dir.Path != "/folders/b" {
		t.Fatal("recency changed directory order")
	}
	if err := rex.RecordSessionVisit("", pickerRecentID(6), now, false); err != nil {
		t.Fatal(err)
	}
	m.applyLauncher() // Status/catalog refresh, not a new presentation.
	if !reflect.DeepEqual(order(), want) {
		t.Fatal("background visit reordered an open picker")
	}
	m.sessionRecency = rex.LoadSessionRecency()
	m.applyLauncher()
	if got := order(); got[0] != pickerRecentID(1) || got[1] != pickerRecentID(6) {
		t.Fatalf("next presentation lost current/MRU priority: %v", got)
	}
	// Better fuzzy scores must not move the matching current session off top.
	m.sessions[0].Entries[0].Label = "work-with-a-long-current-name"
	m.sessions[0].Entries[1].Label = "work"
	m.filter = "work"
	m.applyLauncher()
	if got := order(); len(got) != 6 || got[0] != pickerRecentID(1) {
		t.Fatalf("search did not keep matching current session first: %v", got)
	}
}
