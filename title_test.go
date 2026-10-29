package main

import (
	"reflect"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestPickersInheritOriginTitle(t *testing.T) {
	ctx := Ctx{Title: ".dotfiles"}
	models := []tea.Model{&dirModel{ctx: ctx}, &wtModel{ctx: ctx}, &repoPickModel{ctx: ctx}}
	for _, model := range models {
		cmd := model.Init()
		if cmd == nil || !reflect.DeepEqual(cmd(), tea.SetWindowTitle(ctx.Title)()) {
			t.Fatalf("%T did not inherit the origin title", model)
		}
	}
}

func TestTitleCommand(t *testing.T) {
	for _, tt := range []struct{ input, want string }{
		{"", ""},
		{"\x1b\x07\n\r\u009c", ""},
		{".dotfiles\x07\n", ".dotfiles"},
		{"旅行 project", "旅行 project"},
	} {
		cmd := (Ctx{Title: tt.input}).titleCommand()
		if tt.want == "" {
			if cmd != nil {
				t.Fatalf("unexpected title command for %q", tt.input)
			}
			continue
		}
		if cmd == nil || !reflect.DeepEqual(cmd(), tea.SetWindowTitle(tt.want)()) {
			t.Fatalf("incorrect title command for %q", tt.input)
		}
	}
}
