package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

func fixtureRepo(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "repo")
	if err := os.Mkdir(dir, 0755); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"init", "-b", "main"}, {"config", "user.name", "Test"}, {"config", "user.email", "test@example.com"}, {"-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "initial"}} {
		if _, err := gitOut(dir, args...); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}
func TestWorktreeRepoFolder(t *testing.T) {
	for input, want := range map[string]string{
		".dotfiles": "dotfiles",
		"raptor":    "raptor",
		"...":       "repository",
	} {
		if got := worktreeRepoFolder(input); got != want {
			t.Errorf("worktreeRepoFolder(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestLocalWorktreeLifecycle(t *testing.T) {
	repo := fixtureRepo(t)
	cfg := defaultConfig()
	cfg.WorktreeRoot = t.TempDir()
	for _, pair := range [][2]string{{"feat/login", "feature-login"}, {"fix/crash", "fix-crash"}, {"chore/deps", "chore-deps"}, {"refactor/auth/session", "refactor-auth-session"}} {
		if got := worktreeFolder(pair[0]); got != pair[1] {
			t.Fatalf("%s -> %s", pair[0], got)
		}
	}
	path := worktreePath(repo, "feat/login", cfg)
	if !strings.HasSuffix(path, "repo/feature-login") {
		t.Fatal(path)
	}
	if err := createLocalWorktree(repo, "feat/login", "main", path); err != nil {
		t.Fatal(err)
	}
	trees := listWorktrees(repo)
	if len(trees) != 2 || !trees[0].IsMain || trees[1].Branch != "feat/login" {
		t.Fatalf("%+v", trees)
	}
	if err := createLocalWorktree(repo, "feat/login", "main", path); err == nil {
		t.Fatal("duplicate accepted")
	}
	if err := validateWorktree(repo, "../escape", "main", path); err == nil {
		t.Fatal("invalid name accepted")
	}
	if err := validateWorktree(repo, "feat/new", "missing", path+"new"); err == nil {
		t.Fatal("invalid base accepted")
	}
	if err := os.WriteFile(filepath.Join(path, "unsaved"), []byte("keep me"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := removeWorktree(repo, trees[1]); err == nil {
		t.Fatal("dirty worktree removed")
	}
	if err := os.Remove(filepath.Join(path, "unsaved")); err != nil {
		t.Fatal(err)
	}
	if err := removeWorktree(repo, trees[1]); err != nil {
		t.Fatal(err)
	}
	if _, err := gitOut(repo, "show-ref", "--verify", "refs/heads/feat/login"); err != nil {
		t.Fatal("branch should be kept")
	}
	if err := removeWorktree(repo, trees[0]); err == nil {
		t.Fatal("primary removable")
	}
}
func TestWorktreeForm(t *testing.T) {
	repo := fixtureRepo(t)
	cfg := defaultConfig()
	cfg.WorktreeRoot = t.TempDir()
	m := newWtModel(Ctx{}, cfg, repo)
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
	for _, s := range []string{"feat/login", "feature-login", "main", "Create & open"} {
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
		t.Fatal("selecting a base must focus Create, not submit")
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
