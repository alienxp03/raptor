package worktree

import (
	"crypto/rand"
	_ "embed"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"

	"github.com/alienxp03/raptor/internal/config"
)

// CreateTask starts from the origin worktree's committed HEAD, including when
// detached. Dirty files stay in the original worktree. Names are generated,
// validated, and never overwrite an existing branch or destination.
//
//go:embed task_words.txt
var taskWordList string

func CreateTask(repo string, cfg config.Config) (Worktree, error) {
	words, err := shuffledTaskWords()
	if err != nil {
		return Worktree{}, err
	}
	return createTask(repo, cfg, taskNamePairs(words))
}

// Shuffle once so collisions always try another pair, never a suffix or a
// repeated candidate. Each name joins a word from each half of the shuffled
// list, so every word is used at most once and every pair is considered
// before declaring exhaustion.
func taskNamePairs(words []string) []string {
	half := len(words) / 2
	pairs := make([]string, half)
	for i := range pairs {
		pairs[i] = words[i] + "-" + words[i+half]
	}
	return pairs
}
func shuffledTaskWords() ([]string, error) {
	names := strings.Fields(taskWordList)
	for i := len(names) - 1; i > 0; i-- {
		j, err := rand.Int(rand.Reader, big.NewInt(int64(i+1)))
		if err != nil {
			return nil, err
		}
		names[i], names[j.Int64()] = names[j.Int64()], names[i]
	}
	return names, nil
}

func createTask(repo string, cfg config.Config, names []string) (Worktree, error) {
	head, err := GitOut(repo, "rev-parse", "--verify", "HEAD^{commit}")
	if err != nil {
		return Worktree{}, fmt.Errorf("repository needs a committed HEAD: %w", err)
	}
	// A branch such as otter/topic also prevents creating the word otter.
	blocked := map[string]bool{}
	for _, existing := range LocalBranches(repo) {
		blocked[existing] = true
		blocked[strings.SplitN(existing, "/", 2)[0]] = true
	}
	for _, branch := range names {
		if blocked[branch] {
			continue
		}
		if err := ValidateNewBranch(repo, branch); err != nil {
			continue
		}
		path := Path(repo, branch, cfg)
		if _, err := os.Lstat(path); err == nil {
			continue
		} else if !os.IsNotExist(err) {
			return Worktree{}, err
		}
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			return Worktree{}, err
		}
		if _, err := GitOut(repo, "worktree", "add", "-b", branch, path, head); err != nil {
			// Another shortcut/process can claim a name between validation and
			// creation. Git is the final arbiter; never overwrite its result.
			if strings.Contains(err.Error(), "already exists") || strings.Contains(err.Error(), "exists; cannot create") {
				continue
			}
			return Worktree{}, fmt.Errorf("create task worktree: %w", err)
		}
		return Worktree{Path: path, Branch: branch}, nil
	}
	return Worktree{}, fmt.Errorf("all %d two-word branch names are taken by existing branches or destinations", len(names))
}
