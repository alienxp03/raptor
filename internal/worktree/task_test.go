package worktree

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
)

func TestTaskFromCurrentHEADKeepsDirtyFiles(t *testing.T) {
	for _, detached := range []bool{false, true} {
		t.Run(map[bool]string{false: "branch", true: "detached"}[detached], func(t *testing.T) {
			repo := fixtureRepo(t)
			if _, err := GitOut(repo, "checkout", "-b", "feature/source"); err != nil {
				t.Fatal(err)
			}
			if _, err := GitOut(repo, "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "source"); err != nil {
				t.Fatal(err)
			}
			head, _ := GitOut(repo, "rev-parse", "HEAD")
			if detached {
				if _, err := GitOut(repo, "checkout", "--detach"); err != nil {
					t.Fatal(err)
				}
			}
			dirty := filepath.Join(repo, "uncommitted")
			if err := os.WriteFile(dirty, []byte("keep me"), 0600); err != nil {
				t.Fatal(err)
			}
			cfg := config.Config{WorktreeRoot: filepath.Join(t.TempDir(), "worktree root")}
			tree, err := CreateTask(repo, cfg)
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(" "+strings.Join(strings.Fields(taskWordList), " ")+" ", " "+tree.Branch+" ") {
				t.Fatal(tree.Branch)
			}
			got, _ := GitOut(tree.Path, "rev-parse", "HEAD")
			if got != head {
				t.Fatalf("base = %s, want origin HEAD %s", got, head)
			}
			current, _ := GitOut(tree.Path, "branch", "--show-current")
			if current != tree.Branch {
				t.Fatal(current)
			}
			if data, err := os.ReadFile(dirty); err != nil || string(data) != "keep me" {
				t.Fatal("origin dirty file lost")
			}
			if _, err := os.Stat(filepath.Join(tree.Path, "uncommitted")); !os.IsNotExist(err) {
				t.Fatal("copied dirty origin state")
			}
		})
	}
}

func TestTaskRetriesExistingNamesAndDestinations(t *testing.T) {
	repo := fixtureRepo(t)
	cfg := config.Config{WorktreeRoot: t.TempDir()}
	if _, err := GitOut(repo, "branch", "task/existing"); err != nil {
		t.Fatal(err)
	}
	occupied := Path(repo, "task/occupied", cfg)
	if err := os.MkdirAll(occupied, 0755); err != nil {
		t.Fatal(err)
	}
	names := []string{"task/existing", "task/occupied", "task/fresh"}
	tree, err := createTask(repo, cfg, names)
	if err != nil || tree.Branch != "task/fresh" {
		t.Fatalf("%+v %v", tree, err)
	}
	if _, err := os.Stat(occupied); err != nil {
		t.Fatal("existing destination removed")
	}
}

func TestTaskWordsAreUniqueSingleWordsAndShufflePreservesThem(t *testing.T) {
	words := strings.Fields(taskWordList)
	if len(words) < 400 {
		t.Fatalf("word list too short: %d", len(words))
	}
	seen := map[string]bool{}
	for _, word := range words {
		if seen[word] || word == "" {
			t.Fatalf("duplicate/empty word: %q", word)
		}
		for _, char := range word {
			if char < 'a' || char > 'z' {
				t.Fatalf("not a lowercase single word: %q", word)
			}
		}
		seen[word] = true
	}
	shuffled, err := shuffledTaskWords()
	if err != nil {
		t.Fatal(err)
	}
	if len(shuffled) != len(words) {
		t.Fatal("shuffle changed word count")
	}
	for _, word := range shuffled {
		if !seen[word] {
			t.Fatalf("unknown/repeated shuffled word: %q", word)
		}
		delete(seen, word)
	}
	if len(seen) != 0 {
		t.Fatal("shuffle lost words")
	}
}

func TestTaskCollisionsChooseAnotherWordWithoutSuffix(t *testing.T) {
	repo := fixtureRepo(t)
	cfg := config.Config{WorktreeRoot: t.TempDir()}
	if _, err := GitOut(repo, "branch", "otter"); err != nil {
		t.Fatal(err)
	}
	if _, err := GitOut(repo, "branch", "willow/topic"); err != nil {
		t.Fatal(err)
	}
	occupied := Path(repo, "cedar", cfg)
	if err := os.MkdirAll(occupied, 0755); err != nil {
		t.Fatal(err)
	}
	tree, err := createTask(repo, cfg, []string{"otter", "cedar", "willow", "falcon"})
	if err != nil || tree.Branch != "falcon" {
		t.Fatalf("%+v %v", tree, err)
	}
	_, err = createTask(repo, cfg, []string{"otter", "cedar", "falcon"})
	if err == nil || !strings.Contains(err.Error(), "all 3") {
		t.Fatalf("expected exhaustion, got %v", err)
	}
	if len(List(repo)) != 2 {
		t.Fatal("collision handling created extra worktrees")
	}
}

func TestTaskRequiresCommittedHEAD(t *testing.T) {
	repo := t.TempDir()
	if _, err := GitOut(repo, "init"); err != nil {
		t.Fatal(err)
	}
	if _, err := CreateTask(repo, config.Config{WorktreeRoot: t.TempDir()}); err == nil {
		t.Fatal("unborn repository accepted")
	}
}
