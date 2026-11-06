package worktree

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
)

// Snapshot includes Git internals, dirty files, directories, and symlinks.
func taskSnapshot(t *testing.T, root string) map[string]string {
	t.Helper()
	result := map[string]string{}
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		var content string
		if info.Mode()&os.ModeSymlink != 0 {
			content, err = os.Readlink(path)
		} else if !entry.IsDir() {
			var data []byte
			data, err = os.ReadFile(path)
			content = string(data)
		}
		result[path] = fmt.Sprintf("%s %d %s", info.Mode(), info.ModTime().UnixNano(), content)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func TestSuggestTaskNameReadOnly(t *testing.T) {
	for _, detached := range []bool{false, true} {
		t.Run(map[bool]string{false: "branch", true: "detached"}[detached], func(t *testing.T) {
			repo := fixtureRepo(t)
			if detached {
				if _, err := GitOut(repo, "checkout", "--detach"); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.WriteFile(filepath.Join(repo, "dirty"), []byte("keep"), 0600); err != nil {
				t.Fatal(err)
			}
			root := t.TempDir()
			cfg := config.Config{WorktreeRoot: filepath.Join(root, "not-created")}
			beforeRepo, beforeRoot := taskSnapshot(t, repo), taskSnapshot(t, root)
			name, err := SuggestTaskName(repo, cfg)
			if err != nil {
				t.Fatal(err)
			}
			parts := strings.Split(name, "-")
			if len(parts) != 2 || parts[0] == parts[1] {
				t.Fatalf("not two distinct words: %q", name)
			}
			known := " " + strings.Join(strings.Fields(taskWordList), " ") + " "
			for _, part := range parts {
				if !strings.Contains(known, " "+part+" ") {
					t.Fatalf("word not in whitelist: %q", part)
				}
			}
			if !reflect.DeepEqual(beforeRepo, taskSnapshot(t, repo)) || !reflect.DeepEqual(beforeRoot, taskSnapshot(t, root)) {
				t.Fatal("suggestion changed repository or destination filesystem")
			}
			// No reservation: the same deterministic candidate remains available.
			for i := 0; i < 2; i++ {
				got, err := suggestTaskName(repo, cfg, []string{name})
				if got != name || err != nil {
					t.Fatalf("name was claimed: %q %v", got, err)
				}
			}
		})
	}
}

func TestSuggestTaskNameCollisionsAndExhaustion(t *testing.T) {
	repo := fixtureRepo(t)
	cfg := config.Config{WorktreeRoot: t.TempDir()}
	for _, branch := range []string{"amber-birch", "cedar-dune/topic"} {
		if _, err := GitOut(repo, "branch", branch); err != nil {
			t.Fatal(err)
		}
	}
	// Include packed refs in prefix collision checks.
	if _, err := GitOut(repo, "pack-refs", "--all"); err != nil {
		t.Fatal(err)
	}
	dir := Path(repo, "elm-frost", cfg)
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(Path(repo, "grove-hazel", cfg), []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(cfg.WorktreeRoot, "missing"), Path(repo, "iris-jade", cfg)); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(dir, Path(repo, "kelp-larch", cfg)); err != nil {
		t.Fatal(err)
	}
	blocked := []string{"amber-birch", "cedar-dune", "elm-frost", "grove-hazel", "iris-jade", "kelp-larch", "invalid branch"}
	names := append(append([]string{}, blocked...), "maple-north")
	beforeRepo, beforeRoot := taskSnapshot(t, repo), taskSnapshot(t, cfg.WorktreeRoot)
	got, err := suggestTaskName(repo, cfg, names)
	if got != "maple-north" || err != nil {
		t.Fatalf("suggestion = %q, %v", got, err)
	}
	for _, candidates := range [][]string{blocked, nil} {
		got, err := suggestTaskName(repo, cfg, candidates)
		if got != "" || err == nil || !strings.Contains(err.Error(), fmt.Sprintf("all %d", len(candidates))) {
			t.Fatalf("expected exhaustion: %q %v", got, err)
		}
	}
	if !reflect.DeepEqual(beforeRepo, taskSnapshot(t, repo)) || !reflect.DeepEqual(beforeRoot, taskSnapshot(t, cfg.WorktreeRoot)) {
		t.Fatal("collision selection changed filesystem")
	}
	// Instant Create and the form must select the same candidate.
	tree, err := createTask(repo, cfg, names)
	if err != nil || tree.Branch != got {
		t.Fatalf("create differs from suggestion: %+v %v, want %s", tree, err, got)
	}
}

func TestSuggestTaskNameErrors(t *testing.T) {
	unborn := t.TempDir()
	if _, err := GitOut(unborn, "init"); err != nil {
		t.Fatal(err)
	}
	for _, repo := range []string{unborn, t.TempDir(), filepath.Join(t.TempDir(), "missing")} {
		name, err := SuggestTaskName(repo, config.Config{WorktreeRoot: t.TempDir()})
		if name != "" || err == nil || !strings.Contains(err.Error(), "committed HEAD") {
			t.Fatalf("invalid repo accepted: %q %v", name, err)
		}
	}
	repo := fixtureRepo(t)
	root := t.TempDir()
	// A symlink loop gives a deterministic Lstat error, even when run as root.
	loop := filepath.Join(root, "loop")
	if err := os.Symlink(loop, loop); err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{WorktreeRoot: loop}
	beforeRepo, beforeRoot := taskSnapshot(t, repo), taskSnapshot(t, root)
	name, err := suggestTaskName(repo, cfg, []string{"amber-birch", "cedar-dune"})
	if name != "" || err == nil || strings.Contains(err.Error(), "all 2") {
		t.Fatalf("filesystem error hidden: %q %v", name, err)
	}
	if !reflect.DeepEqual(beforeRepo, taskSnapshot(t, repo)) || !reflect.DeepEqual(beforeRoot, taskSnapshot(t, root)) {
		t.Fatal("error handling changed filesystem")
	}
}

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
			parts := strings.Split(tree.Branch, "-")
			if len(parts) != 2 {
				t.Fatal(tree.Branch)
			}
			known := " " + strings.Join(strings.Fields(taskWordList), " ") + " "
			for _, part := range parts {
				if !strings.Contains(known, " "+part+" ") {
					t.Fatalf("branch %q not built from the word list", tree.Branch)
				}
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

func TestTaskNamesAreTwoWordPairsWithoutRepeats(t *testing.T) {
	pairs := taskNamePairs([]string{"amber", "birch", "cedar", "dune", "elm", "frost"})
	want := []string{"amber-dune", "birch-elm", "cedar-frost"}
	if len(pairs) != len(want) {
		t.Fatalf("pairs = %v", pairs)
	}
	seen := map[string]bool{}
	for i, pair := range pairs {
		if pair != want[i] {
			t.Fatalf("pair %d = %s, want %s", i, pair, want[i])
		}
		parts := strings.Split(pair, "-")
		if len(parts) != 2 {
			t.Fatalf("not two words: %q", pair)
		}
		for _, part := range parts {
			if seen[part] {
				t.Fatalf("word reused across pairs: %q", part)
			}
			seen[part] = true
		}
	}
	shuffled, err := shuffledTaskWords()
	if err != nil {
		t.Fatal(err)
	}
	generated := taskNamePairs(shuffled)
	if len(generated) != len(shuffled)/2 {
		t.Fatalf("pair count = %d, want %d", len(generated), len(shuffled)/2)
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
