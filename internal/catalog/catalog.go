// Package catalog shares picker data and fuzzy matching with native clients.
package catalog

import (
	"fmt"
	"path/filepath"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/paths"
	"github.com/alienxp03/raptor/internal/rex"
	"github.com/alienxp03/raptor/internal/worktree"
	"github.com/sahilm/fuzzy"
)

type Directory struct {
	Path    string `json:"path"`
	Label   string `json:"label"`
	Pinned  bool   `json:"is_pinned,omitempty"`
	State   string `json:"state,omitempty"`
	Working bool   `json:"working,omitempty"`
}

func Directories(reposOnly bool) []Directory {
	return DirectoriesOn("", reposOnly)
}

// DirectoriesOn scopes frecency directories to one host. The empty host and
// "This Mac" read the local zoxide database; remote hosts answer over SSH.
func DirectoriesOn(host string, reposOnly bool) []Directory {
	return DirectoryItems(rex.ZoxideListOn(host), reposOnly)
}

// DirectoryItems keeps zoxide order. Repository discovery also accepts subdirectories.
func DirectoryItems(dirs []string, reposOnly bool) []Directory {
	items := make([]Directory, 0, len(dirs))
	seen := make(map[string]bool)
	for _, dir := range dirs {
		if reposOnly {
			dir = worktree.RepoRoot(dir)
			if dir == "" || seen[dir] {
				continue
			}
			seen[dir] = true
		}
		items = append(items, Directory{Path: dir, Label: paths.Basename(dir)})
	}
	return items
}

func FilterDirectories(items []Directory, query string) []int {
	entries := make([]string, len(items))
	for i, item := range items {
		entries[i] = item.Label + " " + paths.HomeRelative(item.Path)
	}
	return match(entries, query)
}

// ApplyPins marks and floats pinned directories. Stable sort keeps each
// group's order; a canonical match survives symlinked zoxide entries.
func ApplyPins(items []Directory) []Directory {
	pins := map[string]bool{}
	for _, pin := range config.LoadPins() {
		pins[pin] = true
	}
	firstUnpinned := 0
	for i := range items {
		if items[i].Pinned = pins[paths.Canonical(items[i].Path)]; items[i].Pinned {
			item := items[i]
			copy(items[firstUnpinned+1:i+1], items[firstUnpinned:i])
			items[firstUnpinned] = item
			firstUnpinned++
		}
	}
	return items
}

// FilterSessions fuzzy-matches each row's label, retaining parent sessions for
// matching tabs. Results keep sidebar order, not fuzzy score order. A matching
// session does not include tabs whose own labels do not match.
func FilterSessions(entries []rex.SessionEntry, query string) []int {
	texts := make([]string, len(entries))
	parents := make(map[string]int)
	for i, entry := range entries {
		texts[i] = entry.Label
		if entry.Kind == "session" {
			parents[entry.SessionID] = i
		}
	}
	keep := make([]bool, len(entries))
	for _, i := range match(texts, query) {
		keep[i] = true
		if entries[i].Kind == "window" {
			if parent, ok := parents[entries[i].SessionID]; ok {
				keep[parent] = true
			}
		}
	}
	indices := make([]int, 0, len(entries))
	for i := range entries {
		if keep[i] {
			indices = append(indices, i)
		}
	}
	return indices
}

func FilterWorktrees(items []worktree.Worktree, query string) []int {
	entries := make([]string, len(items))
	for i, item := range items {
		entries[i] = item.Branch + " " + paths.HomeRelative(item.Path)
	}
	return match(entries, query)
}

// FilterBranches ranks fuzzy matches, keeping the original order for an empty query.
func FilterBranches(branches []string, query string) []string {
	result := make([]string, 0, len(branches))
	for _, i := range match(branches, query) {
		result = append(result, branches[i])
	}
	return result
}

func match(entries []string, query string) []int {
	indices := make([]int, 0, len(entries))
	if query == "" {
		for i := range entries {
			indices = append(indices, i)
		}
	} else {
		for _, match := range fuzzy.Find(query, entries) {
			indices = append(indices, match.Index)
		}
	}
	return indices
}

// ResolveRepo returns an empty path when no origin repository is available.
// Do not let RepoRoot("") fall back to the backend process's working directory.
func ResolveRepo(ctx rex.Ctx, repo string) (string, error) {
	explicit := repo != ""
	if !explicit {
		repo = rex.BlockCwdInSession(ctx.Session, ctx.Block)
		if repo == "" {
			return "", nil
		}
	}
	root := worktree.RepoRoot(repo)
	if root == "" && explicit {
		return "", fmt.Errorf("not a git repository: %s", repo)
	}
	return root, nil
}

type Worktrees struct {
	Items           []worktree.Worktree
	Branches        []string
	BaseBranch      string
	SuggestedBranch string
	Root            string
}

func ListWorktrees(repo string, cfg config.Config) Worktrees {
	info := Worktrees{Items: worktree.List(repo), Branches: worktree.LocalBranches(repo)}
	// Suggestions are read-only and optional; unavailable names must not hide trees.
	info.SuggestedBranch, _ = worktree.SuggestTaskName(repo, cfg)
	// Root is informational only; branch-specific destinations must use
	// PreviewPath because Worktrunk templates can include nested branch paths.
	if info.SuggestedBranch != "" {
		if destination, err := worktree.PreviewPath(repo, info.SuggestedBranch); err == nil {
			info.Root = filepath.Dir(destination)
		}
	}
	info.BaseBranch, _ = worktree.GitOut(repo, "branch", "--show-current")
	if info.BaseBranch == "" && len(info.Branches) > 0 {
		info.BaseBranch = info.Branches[0]
	}
	return info
}

// LauncherItem is one row of the unified Sessions launcher: a live session on
// any host, or a frecency directory that would start one. Every field is
// explicit — embedding the session entry would emit duplicate JSON keys.
type LauncherItem struct {
	Kind         string `json:"kind"` // "session" | "dir"
	ID           string `json:"id"`
	Path         string `json:"path,omitempty"`
	SessionID    string `json:"session_id,omitempty"`
	Label        string `json:"label"`
	SessionLabel string `json:"session_label,omitempty"`
	Host         string `json:"host"`
	Active       bool   `json:"active,omitempty"`
	Local        bool   `json:"is_local"`
	Pinned       bool   `json:"is_pinned,omitempty"`
	State        string `json:"state,omitempty"`
	Working      bool   `json:"working,omitempty"`
}

// LauncherItems composes the flat launcher: live sessions first — the origin
// session pinned to the top — then each host's directories by frecency with
// pinned local directories floating first. Directories whose label already
// has a live session on the same host are skipped: selecting the session is
// the same action. A query fuzzy-ranks the composed rows over label, path,
// and host.
func LauncherItems(groups []rex.HostGroup, hostOrder []string, hostDirs map[string][]Directory, query string, agents []rex.AgentEntry, localDisplay string) []LauncherItem {
	rows := make([]LauncherItem, 0, 16)
	// Local rows carry the machine's real hostname so every badge answers
	// "where is this" without a generic "This Mac".
	if localDisplay == "" {
		localDisplay = rex.LocalHostLabel
	}
	session := func(entry rex.SessionEntry, local bool) LauncherItem {
		host := entry.Host
		if host == "" || host == rex.LocalHostLabel {
			host = localDisplay
		}
		return LauncherItem{
			Kind: "session", ID: entry.ID, Path: entry.ID,
			SessionID: entry.SessionID, Label: entry.Label, SessionLabel: entry.SessionLabel,
			Host: host, Active: entry.Active, Local: local, State: entry.State, Working: entry.Working,
		}
	}
	dir := func(host string, identityLocal bool, item Directory, pinned bool) LauncherItem {
		if host == "" || host == rex.LocalHostLabel {
			host = localDisplay
		}
		return LauncherItem{
			Kind: "dir", ID: item.Path, Path: item.Path, Label: item.Label,
			Host: host, Local: identityLocal, Pinned: pinned, State: item.State, Working: item.Working,
		}
	}
	origin := -1
	for _, group := range groups {
		if !group.Reachable {
			continue
		}
		for i, entry := range group.Entries {
			if entry.Active {
				origin = len(rows)
			}
			rows = append(rows, session(group.Entries[i], group.Local))
		}
	}
	if origin > 0 {
		active := rows[origin]
		copy(rows[1:origin+1], rows[0:origin])
		rows[0] = active
	}
	taken := map[string]bool{}
	for _, group := range groups {
		if group.Reachable {
			for _, entry := range group.Entries {
				taken[group.Label+"\x00"+entry.Label] = true
			}
		}
	}
	for _, host := range hostOrder {
		items, loaded := hostDirs[host]
		if !loaded {
			continue
		}
		local := host == rex.LocalHostLabel
		pinnedRows := make([]Directory, 0, 2)
		rest := make([]Directory, 0, len(items))
		for _, item := range items {
			if taken[host+"\x00"+item.Label] {
				continue
			}
			if local && item.Pinned {
				pinnedRows = append(pinnedRows, item)
			} else {
				rest = append(rest, item)
			}
		}
		for _, item := range append(pinnedRows, rest...) {
			rows = append(rows, dir(host, local, item, local && item.Pinned))
		}
	}

	if query == "" {
		return rows
	}
	scored := rankLauncherItems(rows, query)
	ranked := make([]LauncherItem, 0, len(scored))
	for _, match := range scored {
		ranked = append(ranked, rows[match.Index])
	}
	return ranked
}

// FilterLauncherItems applies the query to a cached (unfiltered) launcher
// composition: everything when the query is empty, exact names then fuzzy
// quality otherwise.
func FilterLauncherItems(items []LauncherItem, query, originSession string) []LauncherItem {
	if query == "" {
		return items
	}
	scored := rankLauncherItems(items, query)
	ranked := make([]LauncherItem, 0, len(scored))
	for _, match := range scored {
		ranked = append(ranked, items[match.Index])
	}
	return ranked
}

// PreferredLauncherID chooses a default without hiding the current session.
// Items must already be MRU ordered (empty query) or search ranked.
func PreferredLauncherID(items []LauncherItem, query string) string {
	if len(items) == 0 {
		return ""
	}
	if query == "" {
		for _, item := range items {
			if item.Kind == "session" && !item.Active {
				return item.ID
			}
		}
		for _, item := range items {
			if item.Kind == "dir" {
				return item.ID
			}
		}
	}
	return items[0].ID
}

// PinLauncherOrigin moves the origin session to the front of already-composed
// items (used by callers that compose without a query).
func PinLauncherOrigin(items []LauncherItem, originSession string) []LauncherItem {
	return pinOriginFirst(items, originSession)
}

// pinOriginFirst moves the origin session to the front of ranked results:
// the session you're in is always the first suggestion, whatever the match
// score says. Origin matches by the active flag or by the origin session id —
// cached payloads may predate active flags.
func pinOriginFirst(ranked []LauncherItem, originSession string) []LauncherItem {
	isOrigin := func(item LauncherItem) bool {
		return item.Kind == "session" &&
			(item.Active || rex.SameSession(item.SessionID, originSession))
	}
	if len(ranked) > 1 && isOrigin(ranked[0]) {
		return ranked
	}
	for i, item := range ranked {
		if isOrigin(item) {
			pinned := item
			ranked = append(ranked[:i], ranked[i+1:]...)
			return append([]LauncherItem{pinned}, ranked...)
		}
	}
	return ranked
}

type launcherTexts []string

func (l launcherTexts) String(i int) string { return l[i] }
func (l launcherTexts) Len() int            { return len(l) }
