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
	Pins         []string // canonical paths pinned to the top of the dir picker
}

func Default() Config {
	home, _ := os.UserHomeDir()
	return Config{
		WorktreeRoot: filepath.Join(home, "Workspace", "worktrees"),
		SlugLen:      24,
		Enter:        "tab",
		Targets:      []string{"session", "tab", "here", "pane_right", "pane_below"},
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
	cfg.Pins = LoadPins()
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
			if part = strings.TrimSpace(strings.Trim(strings.TrimSpace(part), "\"'")); part != "" {
				targets = append(targets, part)
			}
		}
		if len(targets) > 0 {
			cfg.Targets = targets
		}
	}
	return cfg
}

// configPath is the single TOML file both UIs read.
func configPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".config", "raptor", "config.toml"), nil
}

// LoadPins reads just the pins list. Missing file means no pins.
func LoadPins() []string {
	path, err := configPath()
	if err != nil {
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "pins") {
			continue
		}
		rest := strings.TrimSpace(line[len("pins"):])
		if len(rest) == 0 || rest[0] != '=' {
			continue
		}
		var pins []string
		for _, part := range strings.Split(strings.Trim(strings.TrimSpace(rest[1:]), "[]"), ",") {
			if part = strings.Trim(strings.TrimSpace(part), "\"'"); part != "" {
				pins = append(pins, part)
			}
		}
		return pins
	}
	return nil
}

// SavePins rewrites only the pins line, leaving every other byte untouched.
func SavePins(pins []string) error {
	path, err := configPath()
	if err != nil {
		return err
	}
	quoted := make([]string, len(pins))
	for i, pin := range pins {
		quoted[i] = "\"" + strings.ReplaceAll(pin, "\"", "\\\\\"") + "\""
	}
	line := "pins = [" + strings.Join(quoted, ", ") + "]"
	data, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	var out []string
	replaced := false
	for _, existing := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(strings.TrimSpace(existing), "pins") && !strings.HasPrefix(strings.TrimSpace(existing), "pins_x") {
			if !replaced {
				out = append(out, line)
				replaced = true
			}
			continue
		}
		out = append(out, existing)
	}
	if !replaced {
		if len(out) > 0 && out[len(out)-1] != "" {
			out = append(out, "")
		}
		out = append(out, line)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(strings.Join(out, "\n")), 0o644)
}

// TogglePin adds or removes a canonical path. It reports the new state.
func TogglePin(path string) (bool, error) {
	canonical := paths.Canonical(path)
	pins := LoadPins()
	next := pins[:0:0]
	found := false
	for _, pin := range pins {
		if pin == canonical {
			found = true
			continue
		}
		next = append(next, pin)
	}
	if !found {
		next = append(next, canonical)
	}
	if err := SavePins(next); err != nil {
		return false, err
	}
	return !found, nil
}
