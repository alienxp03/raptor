package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// ---------- git ----------

type worktree struct {
	Path     string
	Branch   string // short name, HEAD if detached
	IsMain   bool
	Dirty    bool
	Short    string // repo#123 derived from branch when possible
	IssueNum string // "142" when branch looks like an issue branch
}

// gitOut runs git in dir; returns trimmed stdout.
func gitOut(dir string, args ...string) (string, error) {
	r, err := runCmd(dir, 10*time.Second, "git", args...)
	if err != nil {
		return "", err
	}
	if r.Code != 0 {
		return "", fmt.Errorf("git %s: %s", strings.Join(args, " "), strings.TrimSpace(r.Stderr))
	}
	return strings.TrimSpace(r.Stdout), nil
}

// repoRoot finds the repo containing dir (or cwd).
func repoRoot(dir string) string {
	if dir == "" {
		dir, _ = os.Getwd()
	}
	if dir == "" {
		return ""
	}
	// worktrees report the main repo; that's fine for gh, but we want the
	// worktree's own root when standing inside one.
	if out, err := gitOut(dir, "rev-parse", "--show-toplevel"); err == nil && out != "" {
		return out
	}
	return ""
}

// isGitRepo reports whether dir is inside a git repo.
func isGitRepo(dir string) bool { return repoRoot(dir) != "" }

// listWorktrees returns the repo's worktrees with dirty state.
func listWorktrees(repo string) []worktree {
	out, err := gitOut(repo, "worktree", "list", "--porcelain")
	if err != nil {
		return nil
	}
	var wts []worktree
	var cur *worktree
	flush := func() {
		if cur != nil && cur.Path != "" {
			cur.IssueNum = issueNumFromBranch(cur.Branch)
			if n := cur.IssueNum; n != "" {
				name := basename(repo)
				cur.Short = name + "#" + n
			}
			wts = append(wts, *cur)
		}
	}
	for _, line := range strings.Split(out, "\n") {
		switch {
		case strings.HasPrefix(line, "worktree "):
			flush()
			cur = &worktree{Path: strings.TrimPrefix(line, "worktree ")}
		case strings.HasPrefix(line, "branch "):
			ref := strings.TrimPrefix(line, "branch ")
			cur.Branch = strings.TrimPrefix(ref, "refs/heads/")
		case line == "detached":
			if cur != nil {
				cur.Branch = "HEAD"
			}
		case line == "bare":
			if cur != nil {
				cur.IsMain = true
			}
		}
	}
	flush()
	// dirty state (visible rows only in UI; here it's fine for a repo's few worktrees)
	for i := range wts {
		if st, err := gitOut(wts[i].Path, "status", "--porcelain"); err == nil {
			wts[i].Dirty = strings.TrimSpace(st) != ""
		}
	}
	// main first, then issue number desc
	sort.SliceStable(wts, func(i, j int) bool {
		if wts[i].IsMain != wts[j].IsMain {
			return wts[i].IsMain
		}
		return wts[i].IssueNum > wts[j].IssueNum
	})
	return wts
}

func issueNumFromBranch(branch string) string {
	if branch == "" || branch == "HEAD" || branch == "main" || branch == "master" {
		return ""
	}
	// accept 123-slug, wt/123-slug, issue-123, feature/123-…
	parts := strings.Split(branch, "/")
	last := parts[len(parts)-1]
	num := ""
	for _, r := range last {
		if r >= '0' && r <= '9' {
			num += string(r)
			continue
		}
		break
	}
	if num != "" && strings.HasPrefix(last, num+"-") {
		return num
	}
	if strings.HasPrefix(last, "issue-") {
		return strings.TrimPrefix(last, "issue-")
	}
	return ""
}

// createWorktree creates ../<root>/<repo>/<num>-<slug> with branch <num>-<slug>.
func createWorktree(repo, num, title string, cfg Config) (string, string, error) {
	slug := num + "-" + slugify(title, cfg.SlugLen)
	wtDir := filepath.Join(cfg.WorktreeRoot, basename(repo), slug)
	if _, err := os.Stat(wtDir); err == nil {
		// exists: reuse
		return wtDir, slug, nil
	}
	if err := os.MkdirAll(filepath.Dir(wtDir), 0o755); err != nil {
		return "", "", err
	}
	if _, err := gitOut(repo, "worktree", "add", "-b", slug, wtDir); err != nil {
		return "", "", err
	}
	return wtDir, slug, nil
}

// removeWorktree removes a worktree and its branch (run from repoRoot so
// the branch delete still works after the worktree directory is gone).
func removeWorktree(repo string, w worktree, force bool) error {
	args := []string{"worktree", "remove"}
	if force {
		args = append(args, "--force")
	}
	args = append(args, w.Path)
	if _, err := gitOut(repo, args...); err != nil {
		// already gone is fine
		if !strings.Contains(err.Error(), "not a working tree") {
			return err
		}
	}
	if w.Branch != "" && w.Branch != "HEAD" && w.IssueNum != "" {
		_, _ = gitOut(repo, "branch", "-D", w.Branch)
	}
	return nil
}

// defaultBranch returns the repo's default branch (origin/HEAD or best guess).
func defaultBranch(repo string) string {
	if out, err := gitOut(repo, "rev-parse", "--abbrev-ref", "origin/HEAD"); err == nil {
		return strings.TrimPrefix(out, "origin/")
	}
	for _, b := range []string{"main", "master"} {
		if _, err := gitOut(repo, "rev-parse", "--verify", "--quiet", b); err == nil {
			return b
		}
	}
	return ""
}

// ---------- gh ----------

type ghItem struct {
	Number    int    `json:"number"`
	Title     string `json:"title"`
	State     string `json:"state"`
	IsPR      bool   `json:"is_pr"`
	UpdatedAt string `json:"updated_at"`
	URL       string `json:"url"`
}

// ghIssues lists open issues + PRs for the repo. Needs gh auth.
func ghIssues(repo string) []ghItem {
	owner, name, ok := ghRepoCoords(repo)
	if !ok {
		return nil
	}
	slug := owner + "/" + name
	var items []ghItem
	if out, err := runCmd(repo, 20*time.Second, "gh", "issue", "list", "-R", slug,
		"--state", "open", "--limit", "50", "--json", "number,title,updatedAt,url"); err == nil {
		var arr []ghItem
		if json.Unmarshal([]byte(out.Stdout), &arr) == nil {
			for _, it := range arr {
				it.IsPR = false
				items = append(items, it)
			}
		}
	}
	if out, err := runCmd(repo, 20*time.Second, "gh", "pr", "list", "-R", slug,
		"--state", "open", "--limit", "50", "--json", "number,title,updatedAt,url"); err == nil {
		var arr []ghItem
		if json.Unmarshal([]byte(out.Stdout), &arr) == nil {
			for _, it := range arr {
				it.IsPR = true
				items = append(items, it)
			}
		}
	}
	sort.SliceStable(items, func(i, j int) bool { return items[i].Number > items[j].Number })
	return items
}

// ghRepoCoords returns owner/name from the repo's origin remote.
func ghRepoCoords(repo string) (string, string, bool) {
	out, err := gitOut(repo, "remote", "get-url", "origin")
	if err != nil || out == "" {
		return "", "", false
	}
	u := out
	u = strings.TrimSuffix(u, ".git")
	switch {
	case strings.HasPrefix(u, "git@"):
		s := strings.TrimPrefix(u, "git@")
		s = strings.Replace(s, ":", "/", 1)
		parts := strings.Split(s, "/")
		if len(parts) >= 3 {
			return parts[len(parts)-2], parts[len(parts)-1], true
		}
	case strings.Contains(u, "://"):
		parts := strings.Split(u, "/")
		if len(parts) >= 2 {
			return parts[len(parts)-2], parts[len(parts)-1], true
		}
	}
	return "", "", false
}

// ghOpenBrowser opens the issue/PR in the browser.
func ghOpenBrowser(repo string, num int, isPR bool) {
	kind := "issue"
	if isPR {
		kind = "pr"
	}
	owner, name, ok := ghRepoCoords(repo)
	if !ok {
		return
	}
	_, _ = runCmd("", 10*time.Second, "gh", kind, "view", fmt.Sprint(num),
		"-R", owner+"/"+name, "--web")
}

// ghTitle fetches a single item's title by number (for ghost rows).
func ghTitle(repo string, num int) (ghItem, bool) {
	owner, name, ok := ghRepoCoords(repo)
	if !ok {
		return ghItem{}, false
	}
	slug := owner + "/" + name
	if out, err := runCmd(repo, 15*time.Second, "gh", "issue", "view", fmt.Sprint(num),
		"-R", slug, "--json", "number,title,url"); err == nil {
		var it ghItem
		if json.Unmarshal([]byte(out.Stdout), &it) == nil {
			return it, true
		}
	}
	if out, err := runCmd(repo, 15*time.Second, "gh", "pr", "view", fmt.Sprint(num),
		"-R", slug, "--json", "number,title,url"); err == nil {
		var it ghItem
		if json.Unmarshal([]byte(out.Stdout), &it) == nil {
			it.IsPR = true
			return it, true
		}
	}
	return ghItem{}, false
}
