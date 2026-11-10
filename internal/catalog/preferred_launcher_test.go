package catalog

import "testing"

func TestPreferredLauncherID(t *testing.T) {
	current := LauncherItem{Kind: "session", ID: "current", Active: true}
	recent := LauncherItem{Kind: "session", ID: "recent"}
	older := LauncherItem{Kind: "session", ID: "older"}
	dir := LauncherItem{Kind: "dir", ID: "/repo"}
	for _, tc := range []struct {
		name        string
		items       []LauncherItem
		query, want string
	}{
		{"MRU alternative", []LauncherItem{current, recent, older, dir}, "", "recent"},
		{"no history keeps incoming order", []LauncherItem{older, recent}, "", "older"},
		{"current and directory", []LauncherItem{current, dir}, "", "/repo"},
		{"directories only", []LauncherItem{dir}, "", "/repo"},
		{"only current", []LauncherItem{current}, "", "current"},
		{"empty", nil, "", ""},
		{"search prefers rank even current", []LauncherItem{current, recent}, "cur", "current"},
		{"search prefers directory rank", []LauncherItem{dir, recent}, "repo", "/repo"},
		{"no query matches", nil, "missing", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := PreferredLauncherID(tc.items, tc.query); got != tc.want {
				t.Fatalf("got %q want %q", got, tc.want)
			}
		})
	}
}

func TestPreferredLauncherFilteredResults(t *testing.T) {
	items := []LauncherItem{{Kind: "session", ID: "current", Label: "r--e--p--o", Active: true}, {Kind: "dir", ID: "/repo", Label: "repo", Path: "/repo"}}
	filtered := FilterLauncherItems(items, "repo", "current")
	if got := PreferredLauncherID(filtered, "repo"); got != "/repo" {
		t.Fatalf("rank overridden: %q", got)
	}
	if len(filtered) != 2 || !filtered[1].Active {
		t.Fatal("current session must stay available")
	}
}
