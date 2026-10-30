package picker

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	worktreepkg "github.com/alienxp03/raptor/internal/worktree"
)

func fixtureRepo(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "repo")
	if err := os.Mkdir(dir, 0755); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"init", "-b", "main"}, {"config", "user.name", "Test"}, {"config", "user.email", "test@example.com"}, {"-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "initial"}} {
		if _, err := worktreepkg.GitOut(dir, args...); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestWorktreeForm(t *testing.T) {
	repo := fixtureRepo(t)
	cfg := config.Default()
	cfg.WorktreeRoot = t.TempDir()
	m := newWtModel(rex.Ctx{}, cfg, repo)
	m.width, m.height = 80, 22
	if cmd := m.Init(); cmd != nil {
		t.Fatal("local picker must not fetch GitHub")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlN})
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("feat/login")})
	if !m.form || m.branch != "feat/login" {
		t.Fatal("form not editable")
	}
	out := ansi.Strip(m.View())
	for _, s := range []string{"feat/login", "feature-login", "main", "Create"} {
		if !strings.Contains(out, s) {
			t.Fatal("missing " + s)
		}
	}
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd != nil || m.busy || m.field != 1 {
		t.Fatal("Enter on branch must advance, not create")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if !m.baseSelecting {
		t.Fatal("base chooser did not open")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("mai")})
	if len(m.baseChoices()) != 1 || m.baseChoices()[0] != "main" {
		t.Fatal("base chooser filtering failed")
	}
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd != nil || m.baseSelecting || m.field != 2 {
		t.Fatal("selecting a base must focus Open in, not submit")
	}
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd != nil || m.busy || m.field != 3 {
		t.Fatal("Enter on Open in must focus Create, not submit")
	}
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil || !m.busy {
		t.Fatal("explicit Create action did not submit")
	}
	m.busy = false
	m.Update(wtCreatedMsg{err: os.ErrPermission})
	if !m.form || m.err == "" {
		t.Fatal("errors must stay in form")
	}
	for _, size := range [][2]int{{80, 22}, {40, 18}} {
		m.width, m.height = size[0], size[1]
		lines := strings.Split(m.View(), "\n")
		if len(lines) != m.height {
			t.Fatal("wrong height")
		}
		for _, line := range lines {
			if lipgloss.Width(line) > m.width {
				t.Fatal("overflow")
			}
		}
	}
	m.form = false
	rowCount := len(m.rows)
	m.filter = "123"
	m.applyFilter()
	if len(m.rows) != rowCount {
		t.Fatal("numeric filter created ghost")
	}
}
