package picker

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	worktreepkg "github.com/alienxp03/raptor/internal/worktree"
	tea "github.com/charmbracelet/bubbletea"
)

func loadedForm(t *testing.T) (*wtModel, catalog.Worktrees) {
	t.Helper()
	repo := fixtureRepo(t)
	cfg := config.Default()
	cfg.WorktreeRoot = filepath.Join(t.TempDir(), "not-created")
	info := catalog.ListWorktrees(repo, cfg)
	m := newCreateModel(rex.Ctx{}, cfg, repo, true)
	m.Update(wtLoadedMsg{repo: repo, info: info})
	return m, info
}

func TestWorktreeDefaultEnterCreatesOnce(t *testing.T) {
	m, info := loadedForm(t)
	if m.branch == "" || m.branch != info.SuggestedBranch || len(strings.Split(m.branch, "-")) != 2 {
		t.Fatalf("expected shared two-word suggestion, got %q", m.branch)
	}
	if _, err := os.Stat(m.cfg.WorktreeRoot); !os.IsNotExist(err) {
		t.Fatalf("prefill created destination root: %v", err)
	}
	if len(worktreepkg.List(m.repo)) != 1 || worktreepkg.ValidateNewBranch(m.repo, m.branch) != nil {
		t.Fatal("prefill must not create a worktree or branch")
	}
	branch, base, target, path := m.branch, m.base, m.target, m.destination()
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil || !m.busy || m.baseSelecting || m.field != 0 {
		t.Fatal("one Enter on branch must submit")
	}
	if _, duplicate := m.Update(tea.KeyMsg{Type: tea.KeyEnter}); duplicate != nil {
		t.Fatal("busy Enter must not queue another command")
	}
	msg := cmd().(wtCreatedMsg)
	if msg.err != nil {
		t.Fatal(msg.err)
	}
	_, quit := m.Update(msg)
	if quit == nil || m.chosen == nil || m.chosen.Path != path || m.chosen.Branch != branch || m.target != target {
		t.Fatal("creation must select the suggested worktree with the existing target")
	}
	head, err := worktreepkg.GitOut(path, "rev-parse", "HEAD")
	want, _ := worktreepkg.GitOut(m.repo, "rev-parse", base)
	if err != nil || head != want || len(worktreepkg.List(m.repo)) != 2 {
		t.Fatal("command must create exactly one worktree from the selected base")
	}
}

func TestWorktreeBranchEnterKeepsSelectedBaseAndTarget(t *testing.T) {
	m, _ := loadedForm(t)
	if _, err := worktreepkg.GitOut(m.repo, "branch", "alternate"); err != nil {
		t.Fatal(err)
	}
	m.base, m.target = "alternate", "session"
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil || m.base != "alternate" || m.target != "session" || m.baseSelecting {
		t.Fatal("branch Enter changed selected base or target")
	}
	if result := cmd().(wtCreatedMsg); result.err != nil {
		t.Fatal(result.err)
	}
}

func TestWorktreeSuggestionDoesNotOverwriteInput(t *testing.T) {
	for _, input := range []string{"feat/early", ""} {
		t.Run("input="+input, func(t *testing.T) {
			m := newCreateModel(rex.Ctx{}, config.Default(), "/repo", true)
			// Clearing an already empty field also expresses user intent.
			m.Update(tea.KeyMsg{Type: tea.KeyCtrlU})
			if input != "" {
				m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(input)})
			}
			if _, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter}); cmd != nil {
				t.Fatal("loading Enter queued")
			}
			for _, suggestion := range []string{"quiet-otter", "brave-bird"} {
				m.Update(wtLoadedMsg{repo: "/repo", info: catalog.Worktrees{SuggestedBranch: suggestion}})
				if m.branch != input || m.busy {
					t.Fatal("metadata replaced early input or queued Enter")
				}
			}
		})
	}
	m := newCreateModel(rex.Ctx{}, config.Default(), "/repo", true)
	m.Update(wtLoadedMsg{repo: "/repo", info: catalog.Worktrees{SuggestedBranch: "quiet-otter"}})
	m.Update(wtLoadedMsg{repo: "/repo", info: catalog.Worktrees{SuggestedBranch: "brave-bird"}})
	if m.branch != "quiet-otter" {
		t.Fatal("metadata refresh changed default")
	}
}

func TestWorktreeChooseRepoContinuesInput(t *testing.T) {
	for _, input := range []string{"feat/early", ""} {
		m := newCreateModel(rex.Ctx{}, config.Default(), "", true)
		m.Update(tea.KeyMsg{Type: tea.KeyCtrlU})
		if input != "" {
			m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(input)})
		}
		_, quit := m.Update(wtLoadedMsg{})
		if quit == nil || m.action != "choose-repo" {
			t.Fatal("expected repository picker")
		}
		next := m.continueCreate("/chosen")
		next.Update(wtLoadedMsg{repo: "/chosen", info: catalog.Worktrees{SuggestedBranch: "quiet-otter"}})
		if next.branch != input || !next.closeOnCancel || next.action != "" {
			t.Fatal("repository continuation lost input or cancellation state")
		}
	}
	m := newCreateModel(rex.Ctx{}, config.Default(), "", false).continueCreate("/chosen")
	m.Update(wtLoadedMsg{repo: "/chosen", info: catalog.Worktrees{SuggestedBranch: "quiet-otter"}})
	if m.branch != "quiet-otter" || m.closeOnCancel {
		t.Fatal("untouched continuation must receive default")
	}
}

func TestWorktreeMissingSuggestionAllowsManualInput(t *testing.T) {
	m, info := loadedForm(t)
	m = newCreateModel(m.ctx, m.cfg, m.repo, true)
	info.SuggestedBranch = ""
	m.Update(wtLoadedMsg{repo: m.repo, info: info})
	if m.err != "" || m.branch != "" {
		t.Fatal("missing suggestion must not block form")
	}
	if _, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter}); cmd != nil || m.err == "" {
		t.Fatal("blank input must fail validation")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("manual-name")})
	if _, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter}); cmd == nil {
		t.Fatal("manual input must submit")
	}
}

func TestWorktreeListSuggestionFailureAllowsManualInput(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	m := newWtModel(rex.Ctx{}, config.Default(), "/missing")
	if m.err != "" || m.form {
		t.Fatal("suggestion failure must not block list")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlN})
	if !m.form || m.err != "" || m.branch != "" {
		t.Fatal("suggestion failure must leave manual form")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("manual-name")})
	if m.branch != "manual-name" {
		t.Fatal("manual input unavailable")
	}
}

func TestWorktreeDefaultCollisionBlocksAndRetryStaysInForm(t *testing.T) {
	for _, collision := range []string{"branch", "destination", "after-submit", "missing-base"} {
		t.Run(collision, func(t *testing.T) {
			m, _ := loadedForm(t)
			var command tea.Cmd
			if collision == "after-submit" {
				_, command = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
			}
			switch collision {
			case "branch":
				if _, err := worktreepkg.GitOut(m.repo, "branch", m.branch); err != nil {
					t.Fatal(err)
				}
			case "missing-base":
				m.base = "missing"
			default:
				if err := os.MkdirAll(m.destination(), 0755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(m.destination(), "keep"), []byte("safe"), 0644); err != nil {
					t.Fatal(err)
				}
			}
			if command != nil {
				result := command().(wtCreatedMsg)
				if result.err == nil {
					t.Fatal("race collision must fail")
				}
				m.Update(result)
			} else if _, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter}); cmd != nil {
				t.Fatal("collision must block command")
			}
			if m.busy || !m.form || m.err == "" || m.chosen != nil || len(worktreepkg.List(m.repo)) != 1 {
				t.Fatal("collision must leave editable form without creation")
			}
			if collision == "destination" || collision == "after-submit" {
				data, err := os.ReadFile(filepath.Join(m.destination(), "keep"))
				if err != nil || string(data) != "safe" {
					t.Fatal("collision overwrote destination")
				}
			}
		})
	}
}

func TestWorktreeListNewFormUsesMetadataThenFreshSafeSuggestion(t *testing.T) {
	repo := fixtureRepo(t)
	cfg := config.Default()
	cfg.WorktreeRoot = t.TempDir()
	m := newWtModel(rex.Ctx{}, cfg, repo)
	suggestion := m.suggestedBranch
	if suggestion == "" {
		t.Fatal("list metadata missing suggestion")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlN})
	if m.branch != suggestion {
		t.Fatal("list form must use current metadata suggestion")
	}
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlU})
	m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if _, err := worktreepkg.GitOut(repo, "branch", suggestion); err != nil {
		t.Fatal(err)
	}
	m.Update(tea.KeyMsg{Type: tea.KeyCtrlN})
	if m.branch == "" || m.branch == suggestion || m.branchEdited || m.field != 0 || worktreepkg.Validate(repo, m.branch, m.base, m.destination()) != nil {
		t.Fatal("new form must reset edits and get a fresh safe shared suggestion")
	}
	if len(worktreepkg.List(repo)) != 1 {
		t.Fatal("opening forms must be read-only")
	}
}
