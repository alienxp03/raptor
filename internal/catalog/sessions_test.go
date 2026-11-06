package catalog

import (
	"reflect"
	"testing"

	"github.com/alienxp03/raptor/internal/rex"
)

func TestFilterSessionsKeepsGroups(t *testing.T) {
	entries := []rex.SessionEntry{
		{Kind: "session", SessionID: "a", Label: "Project"},
		{Kind: "window", SessionID: "a", Label: "build server", SessionLabel: "Project"},
		{Kind: "window", SessionID: "a", Label: "shell", SessionLabel: "Project"},
		{Kind: "window", SessionID: "a", Label: "build", SessionLabel: "Project"},
		{Kind: "session", SessionID: "b", Label: "Tools"},
		{Kind: "window", SessionID: "b", Label: "build", SessionLabel: "Tools"},
		{Kind: "window", SessionID: "b", Label: "logs", SessionLabel: "Tools"},
		{Kind: "session", SessionID: "c", Label: "Empty"},
	}
	for _, tt := range []struct {
		name  string
		query string
		want  []int
	}{
		{"all rows", "", []int{0, 1, 2, 3, 4, 5, 6, 7}},
		{"matching tabs retain parents once and keep order", "build", []int{0, 1, 3, 4, 5}},
		{"fuzzy tab match retains parent", "shl", []int{0, 2}},
		{"session match excludes unrelated tabs", "Project", []int{0}},
		{"empty session remains selectable", "Empty", []int{7}},
		{"no matches", "zzzz", []int{}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if got := FilterSessions(entries, tt.query); !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("got %v, want %v", got, tt.want)
			}
		})
	}
}

func TestFilterSessionsMissingParent(t *testing.T) {
	entries := []rex.SessionEntry{
		{Kind: "session", SessionID: "other", Label: "Other"},
		{Kind: "window", SessionID: "missing", Label: "shell"},
	}
	if got := FilterSessions(entries, "shell"); !reflect.DeepEqual(got, []int{1}) {
		t.Fatalf("missing parent included an unrelated session: %v", got)
	}
	if got := FilterSessions(nil, ""); got == nil || len(got) != 0 {
		t.Fatalf("empty list = %v", got)
	}
}
