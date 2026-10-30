package picker

import (
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func TestCreateFormRendersBeforeRepositoryLoad(t *testing.T) {
	t.Setenv("PATH", t.TempDir()) // Construction and rendering must not need Rex or Git.
	m := newCreateModel(rex.Ctx{}, config.Default(), "/repo", true)
	m.width, m.height = 80, 18
	cmd := m.Init()
	if cmd == nil || !m.loading || !m.form {
		t.Fatal("repository metadata must load through a command after rendering")
	}
	view := ansi.Strip(m.View())
	for _, label := range []string{"New worktree", "Branch", "Loading…", "Loading repository…", "Create & open"} {
		if !strings.Contains(view, label) {
			t.Fatalf("first render missing %q", label)
		}
	}
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("feat/fast")})
	_, submit := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if submit != nil || m.busy || m.branch != "feat/fast" {
		t.Fatal("allow typing but not Git actions while loading")
	}
	m.Update(wtLoadedMsg{repo: "/repo", info: catalog.Worktrees{Root: "/trees/repo", BaseBranch: "main", Branches: []string{"main"}}})
	if m.loading || m.repo != "/repo" || m.base != "main" || m.destination() != "/trees/repo/feature-fast" || m.branch != "feat/fast" {
		t.Fatal("loaded metadata must preserve typed input")
	}
}

func TestCreateFormEscapeDuringLoad(t *testing.T) {
	for _, direct := range []bool{true, false} {
		m := newCreateModel(rex.Ctx{}, config.Default(), "", direct)
		_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEsc})
		if cmd == nil {
			t.Fatal("Escape must not wait for repository metadata")
		}
		if _, ok := cmd().(tea.QuitMsg); !ok {
			t.Fatal("Escape must quit the loading picker")
		}
		if (m.action == "back") == direct {
			t.Fatal("only forms opened from a list should return to it")
		}
	}
}

func TestCreateFormWithoutRepositoryRequestsPicker(t *testing.T) {
	m := newCreateModel(rex.Ctx{}, config.Default(), "", true)
	_, cmd := m.Update(wtLoadedMsg{})
	if cmd == nil || m.action != "choose-repo" {
		t.Fatal("missing repository must lead to the repository picker")
	}
}

func BenchmarkCreateFormFirstRender(b *testing.B) {
	cfg := config.Default()
	for b.Loop() {
		m := newCreateModel(rex.Ctx{}, cfg, "", true)
		m.width, m.height = 80, 18
		m.View()
	}
}
