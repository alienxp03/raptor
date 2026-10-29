package main

import (
	"os"
	"path/filepath"
	"strings"
)

// ---------- tiny helpers used across files ----------

func expandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, strings.TrimPrefix(strings.TrimPrefix(p, "~"), "/"))
	}
	return p
}

func homeRelative(p string) string {
	home, _ := os.UserHomeDir()
	if home != "" && strings.HasPrefix(p, home) {
		return "~" + strings.TrimPrefix(p, home)
	}
	return p
}

func basename(p string) string { return filepath.Base(strings.TrimRight(p, "/")) }

func trimSpace(s string) string { return strings.TrimSpace(s) }

func trimQuotes(s string) string {
	s = strings.TrimSpace(s)
	if len(s) >= 2 && (s[0] == '"' && s[len(s)-1] == '"' || s[0] == '\'' && s[len(s)-1] == '\'') {
		return s[1 : len(s)-1]
	}
	return s
}

func splitLines(s string) []string { return strings.Split(s, "\n") }

func splitComma(s string) []string {
	s = strings.TrimSpace(s)
	s = strings.Trim(s, "[]\"'")
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// slugify turns a title into a short branch-safe slug.
func slugify(s string, maxLen int) string {
	var b strings.Builder
	lastDash := true
	for _, r := range strings.ToLower(s) {
		switch {
		case r >= 'a' && r <= 'z' || r >= '0' && r <= '9':
			b.WriteRune(r)
			lastDash = false
		default:
			if !lastDash {
				b.WriteByte('-')
				lastDash = true
			}
		}
	}
	out := strings.Trim(b.String(), "-")
	if maxLen > 0 && len(out) > maxLen {
		out = out[:maxLen]
		out = strings.Trim(out, "-")
	}
	if out == "" {
		out = "work"
	}
	return out
}
