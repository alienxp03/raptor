// Package pullrequest resolves GitHub PRs and opens durable, visible setup terminals.
package pullrequest

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/alienxp03/raptor/internal/worktree"
)

type Info struct {
	source        string
	Input         string `json:"input"`
	URL           string `json:"url"`
	Number        int    `json:"number"`
	Title         string `json:"title"`
	Branch        string `json:"branch"`
	Repo          string `json:"repo"`
	Path          string `json:"path"`
	CloneRequired bool   `json:"clone_required"`
	Existing      bool   `json:"existing"`
}

var component = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]*$`)
var number = regexp.MustCompile(`^[1-9][0-9]*$`)

func command(dir, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	return commandContext(ctx, dir, name, args...)
}

func commandContext(ctx context.Context, dir, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	boundProcess(cmd)
	defer finishProcess(cmd)
	cmd.Dir = dir
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return string(out), fmt.Errorf("%s: %w: %s", name, err, strings.TrimSpace(stderr.String()))
	}
	return strings.TrimSpace(string(out)), nil
}

func canonical(path string) (string, error) {
	if path == "" {
		return "", fmt.Errorf("empty path")
	}
	p, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(p)
}

func identity(remote string) (string, error) {
	remote = strings.TrimSpace(remote)
	if strings.HasPrefix(remote, "git@github.com:") {
		remote = "https://github.com/" + strings.TrimPrefix(remote, "git@github.com:")
	}
	u, err := url.Parse(remote)
	if err != nil || u.Hostname() != "github.com" || (u.Scheme != "https" && u.Scheme != "ssh") || u.RawQuery != "" || u.Fragment != "" {
		return "", fmt.Errorf("unsupported GitHub origin %q", remote)
	}
	parts := strings.Split(strings.TrimSuffix(strings.Trim(u.Path, "/"), ".git"), "/")
	if len(parts) != 2 || !component.MatchString(parts[0]) || !component.MatchString(parts[1]) || parts[1] == "." || parts[1] == ".." {
		return "", fmt.Errorf("invalid GitHub repository")
	}
	return strings.Join(parts, "/"), nil
}

func parse(input, repo string) (string, string, error) {
	if number.MatchString(input) {
		if repo == "" {
			return "", "", fmt.Errorf("a PR number requires a local repository")
		}
		origin, err := command(repo, "git", "remote", "get-url", "origin")
		if err != nil {
			return "", "", err
		}
		id, err := identity(origin)
		return id, input, err
	}
	u, err := url.Parse(input)
	if err != nil || u.Scheme != "https" || u.Host != "github.com" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", "", fmt.Errorf("enter a github.com PR URL or a PR number with a repository")
	}
	p := strings.Split(strings.TrimSuffix(u.Path, "/"), "/")
	if len(p) != 5 || p[0] != "" || p[3] != "pull" || !number.MatchString(p[4]) {
		return "", "", fmt.Errorf("invalid PR URL")
	}
	id, err := identity("https://github.com/" + p[1] + "/" + p[2])
	return id, p[4], err
}

// Resolve performs read-only metadata, origin and worktree checks. Repo is a local path.
func Resolve(repo, input string) (Info, error) {
	info := Info{Input: input}
	id, n, err := parse(input, repo)
	if err != nil {
		return info, err
	}
	// The REST PR response names the base repository, including for fork PRs.
	raw, err := command("", "gh", "api", "--hostname", "github.com", "repos/"+id+"/pulls/"+n)
	if err != nil {
		return info, err
	}
	var base struct {
		Base struct {
			Repo struct {
				FullName string `json:"full_name"`
			} `json:"repo"`
		} `json:"base"`
	}
	if err = json.Unmarshal([]byte(raw), &base); err != nil {
		return info, err
	}
	baseID, err := identity("https://github.com/" + base.Base.Repo.FullName)
	if err != nil || !strings.EqualFold(baseID, id) {
		return info, fmt.Errorf("GitHub returned a different base repository")
	}
	info.URL = "https://github.com/" + baseID + "/pull/" + n
	raw, err = command("", "gh", "pr", "view", info.URL, "--json", "number,title,headRefName,url")
	if err != nil {
		return info, err
	}
	var metadata struct {
		Number      int
		Title       string
		HeadRefName string
		URL         string
	}
	if err = json.Unmarshal([]byte(raw), &metadata); err != nil {
		return info, err
	}
	expected, _ := strconv.Atoi(n)
	if metadata.Number != expected || metadata.HeadRefName == "" {
		return info, fmt.Errorf("invalid PR metadata")
	}
	info.Number, info.Title, info.Branch = metadata.Number, metadata.Title, metadata.HeadRefName
	home, err := os.UserHomeDir()
	if err != nil {
		return info, err
	}
	destination := filepath.Join(home, "workspace", filepath.FromSlash(baseID))
	candidates := []string{repo}
	cwd, _ := os.Getwd()
	candidates = append(candidates, cwd, destination)
	if out, err := command("", "zoxide", "query", "-l"); err == nil {
		candidates = append(candidates, strings.Split(out, "\n")...)
	}
	for _, candidate := range candidates {
		if candidate == "" {
			continue
		}
		origin, err := command(candidate, "git", "remote", "get-url", "origin")
		if err != nil {
			if candidate == repo {
				return info, fmt.Errorf("invalid repository context: %w", err)
			}
			continue
		}
		localID, err := identity(origin)
		if err != nil || !strings.EqualFold(localID, baseID) {
			if candidate == repo {
				return info, fmt.Errorf("repository context does not match %s", baseID)
			}
			continue
		}
		root, err := command(candidate, "git", "rev-parse", "--path-format=absolute", "--git-common-dir")
		if err != nil {
			continue
		}
		// Resolve linked worktrees back to their primary clone, not the selected worktree.
		primary := filepath.Dir(root)
		if filepath.Base(root) != ".git" {
			continue
		} // bare clones are not supported
		info.Repo, err = canonical(primary)
		if err != nil {
			continue
		}
		sourceRoot, sourceErr := command(candidate, "git", "rev-parse", "--show-toplevel")
		if sourceErr != nil {
			return info, sourceErr
		}
		info.source, err = canonical(sourceRoot)
		if err != nil {
			return info, err
		}
		info.Path, err = worktree.PreviewPath(info.source, info.Branch)
		if err != nil {
			return info, err
		}
		for _, tree := range worktree.List(info.Repo) {
			if tree.Branch == info.Branch {
				info.Path, info.Existing = tree.Path, true
				break
			}
		}
		return info, nil
	}
	info.Repo, info.CloneRequired = destination, true
	return info, nil
}

// Prepare clones into an absent or verified owned empty destination, then
// creates/reuses via Worktrunk. Valid existing clones resume without recloning.
func Prepare(repo, input string) (Info, error) {
	info, err := Resolve(repo, input)
	if err != nil {
		return info, err
	}
	unlock, err := lock("prepare:"+prospectivePath(info.Repo), false)
	if err != nil {
		return info, err
	}
	defer unlock()
	if info.CloneRequired {
		if err := claimClone(info.Repo); err != nil {
			return info, err
		}
		id, _, _ := parse(info.URL, "")
		if _, err := command("", "gh", "repo", "clone", "https://github.com/"+id+".git", info.Repo); err != nil {
			return info, err
		}
		info.CloneRequired = false
		origin, err := command(info.Repo, "git", "remote", "get-url", "origin")
		actual, parseErr := identity(origin)
		if err != nil || parseErr != nil || !strings.EqualFold(actual, id) {
			return info, fmt.Errorf("cloned origin does not match %s", id)
		}
	}
	if _, err := command(info.Repo, "git", "rev-parse", "--verify", "HEAD"); err != nil {
		return info, fmt.Errorf("clone is incomplete; inspect before retry: %w", err)
	}
	source := info.source
	if source == "" {
		source = info.Repo
	}
	if err := checkPreSwitch(source); err != nil {
		return info, err
	}
	preview, err := worktree.PreviewPath(source, info.Branch)
	if err != nil {
		return info, err
	}
	unlockState, err := lock(preview, false)
	if err != nil {
		return info, err
	}
	defer unlockState()
	// Journal before mutation. On an interrupted switch, creation hooks remain pending.
	s, err := load(preview)
	if err != nil {
		return info, err
	}
	// A bound journal belongs to one registration, not to a pathname. An
	// unbound preparation journal survives a crash between switch and save.
	if s.Instance != "" && !validState(preview, s) || s.Instance == "" && (s.Complete || s.Opening || s.Stage != 0) {
		s = setupState{}
	}
	newJournal := s.Path == ""
	if newJournal {
		s = setupState{Path: preview, Source: source, Branch: info.Branch, URL: info.URL, New: !info.Existing}
		s.Base, _ = command(source, "git", "symbolic-ref", "--short", "HEAD")
		s.Config, err = configStamp(source)
		if err != nil {
			return info, err
		}
		if err := save(preview, s); err != nil {
			return info, err
		}
	}
	tree, created, switchErr := worktree.SwitchPR(source, info.URL)
	if tree.Path == "" {
		if switchErr == nil {
			switchErr = fmt.Errorf("Worktrunk returned no destination")
		}
		return info, switchErr
	}
	info.Path, info.Existing = tree.Path, !created
	path, err := canonical(tree.Path)
	if err != nil {
		return info, err
	}
	info.Path = path
	if prospectivePath(preview) != path {
		unlockDestination, err := lock(path, false)
		if err != nil {
			return info, err
		}
		defer unlockDestination()
	}
	prior, err := load(path)
	if err != nil {
		return info, err
	}
	if prior.Path == "" || newJournal || prior.Instance == "" {
		s.Path, s.Branch = path, tree.Branch
		if newJournal {
			s.New = created
		}
		s.Instance, err = instance(path)
		if err == nil {
			err = save(path, s)
		}
	} else if !validState(path, prior) {
		return info, fmt.Errorf("worktree branch differs from saved setup state; resources preserved")
	}
	return info, errors.Join(switchErr, err)
}
