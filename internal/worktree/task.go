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

// SuggestTaskName returns an available task name without claiming it or changing
// the repository or filesystem. Creation must still validate the name.
func SuggestTaskName(repo string, cfg config.Config) (string, error) {
	words, err := shuffledTaskWords()
	if err != nil {
		return "", err
	}
	return suggestTaskName(repo, cfg, taskNamePairs(words))
}

func suggestTaskName(repo string, cfg config.Config, names []string) (string, error) {
	if _, err := taskHEAD(repo); err != nil {
		return "", err
	}
	blocked, err := taskBlockedBranches(repo)
	if err != nil {
		return "", err
	}
	for _, branch := range names {
		path, err := taskDestination(repo, branch, cfg, blocked)
		if err != nil {
			return "", err
		}
		if path != "" {
			return branch, nil
		}
	}
	return "", taskNamesExhausted(len(names))
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

func taskHEAD(repo string) (string, error) {
	head, err := GitOut(repo, "rev-parse", "--verify", "HEAD^{commit}")
	if err != nil {
		return "", fmt.Errorf("repository needs a committed HEAD: %w", err)
	}
	return head, nil
}

func taskBlockedBranches(repo string) (map[string]bool, error) {
	// Read refs with errors intact: a failed read must not suggest a taken name.
	out, err := GitOut(repo, "for-each-ref", "--format=%(refname:strip=2)", "refs/heads/")
	if err != nil {
		return nil, err
	}
	blocked := map[string]bool{}
	for _, existing := range strings.Fields(out) {
		blocked[existing] = true
		// A branch such as otter/topic also prevents creating the word otter.
		blocked[strings.SplitN(existing, "/", 2)[0]] = true
	}
	return blocked, nil
}

// An empty destination means a collision or invalid candidate. Lstat also
// rejects dangling symlinks; other filesystem errors stop selection.
func taskDestination(repo, branch string, cfg config.Config, blocked map[string]bool) (string, error) {
	if blocked[branch] {
		return "", nil
	}
	if err := ValidateNewBranch(repo, branch); err != nil {
		return "", nil
	}
	path := Path(repo, branch, cfg)
	if _, err := os.Lstat(path); err == nil {
		return "", nil
	} else if !os.IsNotExist(err) {
		return "", err
	}
	return path, nil
}

func taskNamesExhausted(count int) error {
	return fmt.Errorf("all %d two-word branch names are taken by existing branches or destinations", count)
}

func createTask(repo string, cfg config.Config, names []string) (Worktree, error) {
	head, err := taskHEAD(repo)
	if err != nil {
		return Worktree{}, err
	}
	blocked, err := taskBlockedBranches(repo)
	if err != nil {
		return Worktree{}, err
	}
	for _, branch := range names {
		path, err := taskDestination(repo, branch, cfg, blocked)
		if err != nil {
			return Worktree{}, err
		}
		if path == "" {
			continue
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
	return Worktree{}, taskNamesExhausted(len(names))
}
