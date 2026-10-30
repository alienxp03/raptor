package config

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/alienxp03/raptor/internal/paths"
)

// Config is read from ~/.config/raptor/config.toml (all optional).
type Config struct {
	WorktreeRoot string // where new worktrees are created
	SlugLen      int    // max slug characters in branch/dir names
	Enter        string // default target for Enter in the dir picker
	Targets      []string
}

func Default() Config {
	home, _ := os.UserHomeDir()
	return Config{
		WorktreeRoot: filepath.Join(home, "Workspace", "worktrees"),
		SlugLen:      24,
		Enter:        "tab",
		Targets:      []string{"tab", "session", "here", "pane", "pane_left", "pane_above", "pane_below"},
	}
}

// AvailableTargets shares target order and context requirements across both UIs.
func (cfg Config) AvailableTargets(hasBlock bool) []string {
	targets := cfg.Targets
	if len(targets) == 0 {
		targets = Default().Targets
	}
	result := []string{}
	seen := map[string]bool{}
	for _, target := range targets {
		if seen[target] || (!hasBlock && (target == "here" || strings.HasPrefix(target, "pane"))) {
			continue
		}
		seen[target] = true
		result = append(result, target)
	}
	return result
}

// Load parses a flat TOML subset: key = "value" / key = 12.
func Load() Config {
	cfg := Default()
	home, _ := os.UserHomeDir()
	data, err := os.ReadFile(filepath.Join(home, ".config", "raptor", "config.toml"))
	if err != nil {
		return cfg
	}
	s := string(data)
	get := func(key string) (string, bool) {
		for _, line := range strings.Split(s, "\n") {
			line = strings.TrimSpace(line)
			if len(line) >= len(key)+1 && line[:len(key)] == key {
				rest := strings.TrimSpace(line[len(key):])
				if len(rest) > 0 && rest[0] == '=' {
					v := strings.TrimSpace(rest[1:])
					v = strings.Trim(v, "\"'")
					return v, true
				}
			}
		}
		return "", false
	}
	if v, ok := get("worktree_root"); ok && v != "" {
		cfg.WorktreeRoot = paths.ExpandHome(v)
	}
	if v, ok := get("slug_len"); ok && v != "" {
		n := 0
		for _, c := range v {
			if c < '0' || c > '9' {
				n = 0
				break
			}
			n = n*10 + int(c-'0')
		}
		if n > 0 {
			cfg.SlugLen = n
		}
	}
	if v, ok := get("enter"); ok && v != "" {
		cfg.Enter = v
	}
	if v, ok := get("targets"); ok && v != "" {
		parts := strings.Split(strings.Trim(v, "[]\"'"), ",")
		var targets []string
		for _, part := range parts {
			if part = strings.TrimSpace(strings.Trim(part, "\"'")); part != "" {
				targets = append(targets, part)
			}
		}
		if len(targets) > 0 {
			cfg.Targets = targets
		}
	}
	return cfg
}
