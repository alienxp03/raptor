package paths

import (
	"os"
	"path/filepath"
	"strings"
)

// CacheDir returns the raptor cache directory, creating it when missing.
func CacheDir() string {
	base := os.Getenv("XDG_CACHE_HOME")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, "Library", "Caches")
	}
	dir := filepath.Join(base, "raptor")
	_ = os.MkdirAll(dir, 0o700)
	return dir
}

// PanelSocket is the unix socket the resident panel host listens on.
func PanelSocket() string {
	return filepath.Join(CacheDir(), "panel.sock")
}

// Canonical resolves symlinks and makes a path absolute for stable comparison.
func Canonical(path string) string {
	if path == "" {
		return ""
	}
	if real, err := filepath.EvalSymlinks(path); err == nil {
		path = real
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return filepath.Clean(path)
	}
	return absolute
}

func ExpandHome(path string) string {
	if path == "~" || strings.HasPrefix(path, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, strings.TrimPrefix(strings.TrimPrefix(path, "~"), "/"))
	}
	return path
}

func HomeRelative(path string) string {
	home, _ := os.UserHomeDir()
	if home != "" && strings.HasPrefix(path, home) {
		return "~" + strings.TrimPrefix(path, home)
	}
	return path
}

func Basename(path string) string {
	return filepath.Base(strings.TrimRight(path, "/"))
}
