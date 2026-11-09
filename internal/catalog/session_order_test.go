package catalog

import (
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/alienxp03/raptor/internal/rex"
)

func testRecentSessionID(n int) string {
	return fmt.Sprintf("session:00000000-0000-4000-8000-%012d", n)
}

func TestSessionRecencyOrderingIsScopedStableAndPresentationBound(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	now := time.Now()
	for i, visit := range []struct{ host, id string }{{"", testRecentSessionID(2)}, {"", testRecentSessionID(5)}, {"hades", testRecentSessionID(3)}} {
		if err := rex.RecordSessionVisit(visit.host, visit.id, now.Add(time.Duration(i-5)*time.Minute), false); err != nil {
			t.Fatal(err)
		}
	}
	ranks := rex.LoadSessionRecency()
	base := []LauncherItem{}
	for n := 1; n <= 6; n++ {
		base = append(base, LauncherItem{Kind: "session", SessionID: testRecentSessionID(n), Local: true, Host: "Mac", Label: "work"})
	}
	base = append(base,
		LauncherItem{Kind: "session", SessionID: testRecentSessionID(3), Host: "hades", Label: "remote"},
		LauncherItem{Kind: "dir", Path: "/folders/a", Local: true},
		LauncherItem{Kind: "dir", Path: "/folders/b", Host: "hades"},
	)
	ids := func(items []LauncherItem) []string {
		out := []string{}
		for _, item := range items {
			if item.Kind == "session" {
				host := "local"
				if !item.Local {
					host = item.Host
				}
				out = append(out, host+":"+item.SessionID)
			}
		}
		return out
	}
	items := append([]LauncherItem{}, base...)
	OrderLauncherSessionsByRecency(items, ranks)
	want := []string{"hades:" + testRecentSessionID(3), "local:" + testRecentSessionID(5), "local:" + testRecentSessionID(2), "local:" + testRecentSessionID(1), "local:" + testRecentSessionID(3), "local:" + testRecentSessionID(4), "local:" + testRecentSessionID(6)}
	if !reflect.DeepEqual(ids(items), want) {
		t.Fatalf("MRU order = %v, want %v", ids(items), want)
	}
	if !reflect.DeepEqual(items[7:], base[7:]) {
		t.Fatal("session recency changed folder order")
	}
	if err := rex.RecordSessionVisit("", testRecentSessionID(6), now, false); err != nil {
		t.Fatal(err)
	}
	items = append([]LauncherItem{}, base...)
	OrderLauncherSessionsByRecency(items, ranks)
	if !reflect.DeepEqual(ids(items), want) {
		t.Fatal("a new visit changed the captured presentation order")
	}
	OrderLauncherSessionsByRecency(items, rex.LoadSessionRecency())
	if items[0].SessionID != testRecentSessionID(6) || !items[0].Local {
		t.Fatal("next presentation did not use the latest visit")
	}
	for i := range items {
		items[i].Active = items[i].Local && items[i].SessionID == testRecentSessionID(1)
	}
	items = PinLauncherOrigin(items, "")
	if items[0].SessionID != testRecentSessionID(1) {
		t.Fatal("current session must still lead MRU order")
	}
}

func TestSessionRecencyIsFuzzySearchTieBreaker(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	if err := rex.RecordSessionVisit("", testRecentSessionID(2), time.Now(), false); err != nil {
		t.Fatal(err)
	}
	items := []LauncherItem{
		{Kind: "session", SessionID: testRecentSessionID(1), Label: "work", Host: "Mac", Local: true},
		{Kind: "session", SessionID: testRecentSessionID(2), Label: "work", Host: "Mac", Local: true},
	}
	OrderLauncherSessionsByRecency(items, rex.LoadSessionRecency())
	filtered := FilterLauncherItems(items, "work", "")
	if len(filtered) != 2 || filtered[0].SessionID != testRecentSessionID(2) {
		t.Fatal("equal fuzzy matches lost MRU order")
	}
	items[0].Label = "w--o--r--k"
	filtered = FilterLauncherItems(items, "work", "")
	if filtered[0].SessionID != testRecentSessionID(1) {
		t.Fatal("recency must not override a better fuzzy match")
	}
}
