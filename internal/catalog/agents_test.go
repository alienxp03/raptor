package catalog

import (
	"github.com/alienxp03/raptor/internal/rex"
	"reflect"
	"testing"
)

func TestFilterAgents(t *testing.T) {
	entries := []rex.AgentEntry{{Label: "Fix login", App: "pi", State: "working", SessionLabel: "Personal", WindowLabel: "Backend"}, {Label: "Review", App: "codex", State: "blocked", SessionLabel: "Work", WindowLabel: "Frontend"}}
	for _, tt := range []struct {
		query string
		want  []int
	}{{"", []int{0, 1}}, {"login", []int{0}}, {"pi", []int{0}}, {"blocked", []int{1}}, {"Work", []int{0, 1}}, {"Frontend", []int{1}}, {"zzzzzz", []int{}}} {
		got := FilterAgents(entries, tt.query)
		if !reflect.DeepEqual(got, tt.want) {
			t.Fatalf("query=%q got=%v want=%v", tt.query, got, tt.want)
		}
	}
}
