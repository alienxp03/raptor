package main

import (
	"os"
	"path/filepath"
)

// Config is read from ~/.config/raptor/config.toml (all optional).
type Config struct {
	WorktreeRoot string // where new worktrees are created
	SlugLen      int    // max slug characters in branch/dir names
	Enter        string // default target for Enter in the dir picker
	Targets      []string
}

func defaultConfig() Config {
	home, _ := os.UserHomeDir()
	return Config{
		WorktreeRoot: filepath.Join(home, "Workspace", "worktrees"),
		SlugLen:      24,
		Enter:        "tab",
		Targets:      []string{"session", "tab", "pane", "pane_below", "here"},
	}
}

// loadConfig parses a flat TOML subset: key = "value" / key = 12.
func loadConfig() Config {
	cfg := defaultConfig()
	home, _ := os.UserHomeDir()
	data, err := os.ReadFile(filepath.Join(home, ".config", "raptor", "config.toml"))
	if err != nil {
		return cfg
	}
	s := string(data)
	get := func(key string) (string, bool) {
		for _, line := range splitLines(s) {
			line = trimSpace(line)
			if len(line) >= len(key)+1 && line[:len(key)] == key {
				rest := trimSpace(line[len(key):])
				if len(rest) > 0 && rest[0] == '=' {
					v := trimSpace(rest[1:])
					v = trimQuotes(v)
					return v, true
				}
			}
		}
		return "", false
	}
	if v, ok := get("worktree_root"); ok && v != "" {
		cfg.WorktreeRoot = expandHome(v)
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
		var ts []string
		for _, part := range splitComma(v) {
			if part != "" {
				ts = append(ts, part)
			}
		}
		if len(ts) > 0 {
			cfg.Targets = ts
		}
	}
	return cfg
}
