package catalog

import (
	"path/filepath"
	"reflect"
	"testing"

	"github.com/alienxp03/raptor/internal/paths"
	"github.com/alienxp03/raptor/internal/rex"
)

func TestLauncherExactFolderNamesLeadFullPathMatches(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	var dirs []Directory
	for _, relative := range []string{
		"workspace/projects/VoiceInk", "workspace/webmono/projects/frontier/ios/App",
		".pi", ".dotfiles/pi", "workspace/piza", ".pi/agent",
		"workspace/performance-review", ".pi/agent/extensions",
	} {
		p := filepath.Join(home, relative)
		dirs = append(dirs, Directory{Path: p, Label: paths.HomeRelative(p)})
	}
	hostDirs := map[string][]Directory{rex.LocalHostLabel: dirs}
	compose := func(query string) []LauncherItem {
		return LauncherItems(nil, []string{rex.LocalHostLabel}, hostDirs, query, nil, "Mac")
	}
	base := compose("")
	for _, query := range []string{"pi", "PI", ".pi"} {
		for _, result := range [][]LauncherItem{compose(query), FilterLauncherItems(base, query, "")} {
			if len(result) < 2 || result[0].Path != filepath.Join(home, ".pi") {
				t.Fatalf("query %q: exact hidden folder must lead: %+v", query, result)
			}
			if query != ".pi" && result[1].Path != filepath.Join(home, ".dotfiles/pi") {
				t.Fatalf("query %q: exact basename must precede partial/path matches: %+v", query, result)
			}
		}
	}
	if got := FilterLauncherItems(base, "", ""); !reflect.DeepEqual(got, base) {
		t.Fatal("empty search changed the source order")
	}
	for i, item := range base {
		if item.Path != dirs[i].Path {
			t.Fatal("search mutated the cached source order")
		}
	}
}

func TestLauncherExactNamesPreserveTiesAndCurrentSession(t *testing.T) {
	items := []LauncherItem{
		{Kind: "session", Label: "pi", SessionID: "session:recent"},
		{Kind: "session", Label: "pi", SessionID: "session:older"},
	}
	got := FilterLauncherItems(items, "pi", "")
	if !reflect.DeepEqual(got, items) {
		t.Fatal("equal exact matches lost their existing recency order")
	}
	items = append(items, LauncherItem{Kind: "session", Label: "p--i", SessionID: "session:origin", Active: true})
	got = FilterLauncherItems(items, "pi", "session:origin")
	if len(got) != 3 || got[0].SessionID != "session:recent" || got[2].SessionID != "session:origin" {
		t.Fatal("current session must remain available without overriding query rank")
	}
}
