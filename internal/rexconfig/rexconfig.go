// Package rexconfig wires Raptor into a Rex configuration file, resh-style:
// one managed, idempotent block the user never edits by hand.
package rexconfig

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Managed block markers. Content between them is replaced on every init.
const (
	beginMarker = "-- >>> raptor >>>"
	endMarker   = "-- <<< raptor <<<"
)

// Options control where the plugin lives and which bindings init writes.
type Options struct {
	// Bindings maps Rex key names to action invocations, written in order.
	Bindings [][2]string
}

func DefaultOptions() Options {
	return Options{Bindings: [][2]string{
		{"shift+cmd+o", "raptor"},
		{"shift+cmd+n", "raptor_worktree_new"},
	}}
}

// LocatePlugin finds the packaged init.lua for the running executable:
// Homebrew opt layouts, an app bundle's bundled plugin, or an installer-owned
// copy under the Rex config directory. Empty means "use plain require".
func LocatePlugin() string {
	exe, err := os.Executable()
	if err == nil {
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			exe = real
		}
		dir := filepath.Dir(exe)
		// Homebrew: …/opt/raptor/bin/raptor → …/opt/raptor/share/raptor/init.lua
		candidates := []string{filepath.Join(dir, "..", "share", "raptor", "init.lua")}
		// App bundle CLI: …/Raptor.app/Contents/MacOS/raptor-cli
		bundle := filepath.Dir(dir)
		candidates = append(candidates,
			filepath.Join(bundle, "Resources", "rex", "init.lua"),
			// macOS app next to a standalone CLI installation.
			filepath.Join(bundle, "..", "..", "Resources", "rex", "init.lua"),
		)
		for _, candidate := range candidates {
			if isFile(candidate) {
				return filepath.Clean(candidate)
			}
		}
	}
	home, _ := os.UserHomeDir()
	if app := discoverApp(home); app != "" {
		path := filepath.Join(app, "Contents", "Resources", "rex", "init.lua")
		if isFile(path) {
			return path
		}
	}
	return ""
}

func discoverApp(home string) string {
	for _, app := range []string{
		filepath.Join(home, "Applications", "Raptor.app"),
		"/Applications/Raptor.app",
	} {
		if isFile(filepath.Join(app, "Contents", "MacOS", "Raptor")) {
			return app
		}
	}
	for _, prefix := range []string{os.Getenv("HOMEBREW_PREFIX"), "/opt/homebrew", "/usr/local"} {
		if prefix == "" {
			continue
		}
		app := filepath.Join(prefix, "opt", "raptor", "libexec", "Raptor.app")
		if isFile(filepath.Join(app, "Contents", "MacOS", "Raptor")) {
			return app
		}
	}
	return ""
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

// ConfigPath resolves the Rex configuration file: REX_CONFIG, then the
// account config directory. The file itself may not exist yet.
func ConfigPath() string {
	if path := os.Getenv("REX_CONFIG"); path != "" {
		return path
	}
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "rex", "init.lua")
}

// Block renders the managed Lua block for the discovered plugin.
func Block(plugin string, options Options) string {
	var b strings.Builder
	b.WriteString(beginMarker + "\n")
	if plugin != "" {
		fmt.Fprintf(&b, "local raptor = dofile(%q)\n", plugin)
	} else {
		b.WriteString("local raptor = require(\"raptor\")\n")
	}
	b.WriteString("raptor.setup{}\n")
	for _, binding := range options.Bindings {
		fmt.Fprintf(&b, "rex.bind(%q, %q)\n", binding[0], binding[1])
	}
	b.WriteString(endMarker + "\n")
	return b.String()
}

// Apply writes the managed block into the Rex configuration. It is
// idempotent: existing managed content is replaced in place. A config that
// wires raptor outside the managed block is refused unless force is set —
// silent duplication would leave two setups fighting over one action name.
func Apply(configPath, plugin string, options Options, force bool) (created bool, err error) {
	original, readErr := os.ReadFile(configPath)
	if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
		return false, readErr
	}
	text := string(original)
	block := Block(plugin, options)
	begin := strings.Index(text, beginMarker)
	end := strings.Index(text, endMarker)
	switch {
	case begin >= 0 && end > begin:
		rest := strings.TrimLeft(text[end+len(endMarker):], "\n")
		text = text[:begin] + block + rest
	case begin >= 0 || end >= 0:
		return false, fmt.Errorf("%s has a truncated raptor block; fix or remove the markers", configPath)
	default:
		// Outside references predate managed setup; never stack a second one.
		for _, line := range strings.Split(text, "\n") {
			trimmed := strings.TrimSpace(line)
			if strings.Contains(trimmed, "raptor") && !strings.HasPrefix(trimmed, "--") {
				if !force {
					return false, fmt.Errorf("%s already configures raptor at %q; remove those lines or pass --force",
						configPath, trimmed)
				}
			}
		}
		if text != "" && !strings.HasSuffix(text, "\n") {
			text += "\n"
		}
		text += "\n" + block
		created = true
	}
	if err := os.MkdirAll(filepath.Dir(configPath), 0o755); err != nil {
		return false, err
	}
	return created, os.WriteFile(configPath, []byte(text), 0o644)
}
