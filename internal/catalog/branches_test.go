package catalog

import (
	"reflect"
	"testing"

	"github.com/sahilm/fuzzy"
)

func TestFilterBranches(t *testing.T) {
	branches := []string{"feat/long-login", "main", "fix/login", "login", "feat/logout"}
	original := append([]string{}, branches...)
	for _, query := range []string{"", "login", "flgn", "MAIN", "no-such-branch"} {
		t.Run(query, func(t *testing.T) {
			want := []string{}
			if query == "" {
				want = append(want, branches...)
			} else {
				for _, m := range fuzzy.Find(query, branches) {
					want = append(want, branches[m.Index])
				}
			}
			got := FilterBranches(branches, query)
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("got %v, want %v", got, want)
			}
			if query == "login" && (len(got) == 0 || got[0] != "login") {
				t.Fatalf("exact match must rank first: %v", got)
			}
		})
	}
	if !reflect.DeepEqual(branches, original) {
		t.Fatalf("input changed: %v", branches)
	}
	for _, branches := range [][]string{nil, {}} {
		for _, query := range []string{"", "main"} {
			if got := FilterBranches(branches, query); got == nil || len(got) != 0 {
				t.Fatalf("empty input: got %#v", got)
			}
		}
	}
}
