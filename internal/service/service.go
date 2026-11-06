// Package service manages the resident panel host: a launchd gui-domain job
// that keeps the Raptor app running with a pre-created panel. Open requests
// travel over a unix socket (package panel), so opening never spawns a process.
package service

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/alienxp03/raptor/internal/paths"
)

// Label is the launchd job label for the resident panel host.
const Label = "com.alienxp03.raptor.panel"

// PlistPath keeps the job definition in the cache directory, mirroring the
// app's transient, per-user nature. Nothing is installed system-wide.
func PlistPath() string { return filepath.Join(paths.CacheDir(), "launcher.plist") }

// Definition builds the launchd job. KeepAlive restarts the host if it exits;
// ThrottleInterval prevents crash loops from spinning.
func Definition(appExecutable string) map[string]any {
	return map[string]any{
		"Label":             Label,
		"ProgramArguments":  []string{appExecutable, "serve"},
		"EnvironmentVariables": map[string]any{
			"PATH": servicePath(),
		},
		"KeepAlive":          true, // Always keep the panel host up; stop = bootout.
		"ThrottleInterval":   2,
		"ExitTimeOut":        1,
		"ProcessType":        "Interactive",
        "StandardOutPath":    "/dev/null",
		"StandardErrorPath":  filepath.Join(paths.CacheDir(), "service.log"),
	}
}

// DiscoverApp finds an installed Raptor.app, preferring the same discovery
// order init.lua uses.
func DiscoverApp() (string, error) {
	home, _ := os.UserHomeDir()
	candidates := []string{
		filepath.Join(home, "Applications", "Raptor.app"),
		"/Applications/Raptor.app",
	}
	for _, prefix := range []string{os.Getenv("HOMEBREW_PREFIX"), "/opt/homebrew", "/usr/local"} {
		if prefix == "" {
			continue
		}
		candidates = append(candidates, filepath.Join(prefix, "opt", "raptor", "libexec", "Raptor.app"))
	}
	for _, app := range candidates {
		executable := filepath.Join(app, "Contents", "MacOS", "Raptor")
		if info, err := os.Stat(executable); err == nil && !info.IsDir() {
			return app, nil // The .app path; Install joins the executable itself.
		}
	}
	return "", errors.New("Raptor.app not found; pass --app /path/to/Raptor.app")
}

// Install writes the job definition and loads it, replacing any previous job.
func Install(appPath string) error {
	if appPath == "" {
		discovered, err := DiscoverApp()
		if err != nil {
			return err
		}
		appPath = discovered
	}
	executable, err := filepath.Abs(filepath.Join(appPath, "Contents", "MacOS", "Raptor"))
	if err != nil {
		return err
	}
	if info, err := os.Stat(executable); err != nil || info.IsDir() {
		return fmt.Errorf("not a Raptor app executable: %s", executable)
	}
	data, err := marshalPlist(Definition(executable))
	if err != nil {
		return err
	}
	if err := os.WriteFile(PlistPath(), data, 0o644); err != nil {
		return err
	}
	_ = launchctl("bootout", domain()+"/"+Label) // Ignore: may not be loaded.
	return launchctl("bootstrap", domain(), PlistPath())
}

// Uninstall stops the host and removes the job definition and socket.
func Uninstall() error {
	err := launchctl("bootout", domain()+"/"+Label)
	_ = os.Remove(PlistPath())
	_ = os.Remove(paths.PanelSocket())
	if err != nil {
		return fmt.Errorf("service stop: %w", err)
	}
	return nil
}

// Start loads (if needed) and starts the job without restarting a running one.
func Start() error {
	if !loaded() {
		if _, err := os.Stat(PlistPath()); err != nil {
			return errors.New("service is not installed; run raptor service install first")
		}
		if err := launchctl("bootstrap", domain(), PlistPath()); err != nil {
			return err
		}
	}
	return launchctl("kickstart", domain()+"/"+Label)
}

// Kickstart (re)starts the job regardless of state; used by panel open when
// the host socket is missing.
func Kickstart() error {
	if _, err := os.Stat(PlistPath()); err != nil {
		return errors.New("service is not installed")
	}
	_ = launchctl("bootout", domain()+"/"+Label)
	if err := launchctl("bootstrap", domain(), PlistPath()); err != nil {
		return err
	}
	return launchctl("kickstart", domain()+"/"+Label)
}

// Stop unloads the job. The socket file disappears with the host.
func Stop() error {
	return launchctl("bootout", domain()+"/"+Label)
}

// Status reports whether launchd currently has the job loaded.
func Status() (bool, error) { return loaded(), nil }

func loaded() bool {
	return launchctl("print", domain()+"/"+Label) == nil
}

func domain() string { return fmt.Sprintf("gui/%d", os.Getuid()) }

func launchctl(args ...string) error {
	cmd := exec.Command("launchctl", args...)
	cmd.Stderr = nil
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("launchctl %s: %s", strings.Join(args, " "), strings.TrimSpace(string(out)))
	}
	return nil
}

func servicePath() string {
	home, _ := os.UserHomeDir()
	parts := []string{
		filepath.Join(home, ".local", "share", "mise", "shims"),
		"/opt/homebrew/bin",
		"/usr/local/bin",
		"/usr/bin",
		"/bin",
	}
	return strings.Join(parts, ":")
}

func marshalPlist(value map[string]any) ([]byte, error) {
	var b strings.Builder
	b.WriteString("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n")
	if err := writePlistValue(&b, value); err != nil {
		return nil, err
	}
	b.WriteString("</plist>\n")
	return []byte(b.String()), nil
}

// writePlistValue covers the small value set the job definition uses:
// maps, string slices, strings, bools, and integers.
func writePlistValue(b *strings.Builder, value any) error {
	switch v := value.(type) {
	case string:
		fmt.Fprintf(b, "<string>%s</string>\n", xmlEscape(v))
	case bool:
		fmt.Fprintf(b, "<%t/>\n", v)
	case int:
		fmt.Fprintf(b, "<integer>%d</integer>\n", v)
	case []string:
		b.WriteString("<array>\n")
		for _, item := range v {
			fmt.Fprintf(b, "<string>%s</string>\n", xmlEscape(item))
		}
		b.WriteString("</array>\n")
	case []any:
		b.WriteString("<array>\n")
		for _, item := range v {
			if err := writePlistValue(b, item); err != nil {
				return err
			}
		}
		b.WriteString("</array>\n")
	case map[string]any:
		b.WriteString("<dict>\n")
		keys := make([]string, 0, len(v))
		for key := range v {
			keys = append(keys, key)
		}
		sortStrings(keys)
		for _, key := range keys {
			fmt.Fprintf(b, "<key>%s</key>\n", xmlEscape(key))
			if err := writePlistValue(b, v[key]); err != nil {
				return err
			}
		}
		b.WriteString("</dict>\n")
	default:
		return fmt.Errorf("unsupported plist value type %T", value)
	}
	return nil
}

func xmlEscape(s string) string {
	replacer := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;")
	return replacer.Replace(s)
}

func sortStrings(values []string) {
	for i := 1; i < len(values); i++ {
		for j := i; j > 0 && values[j] < values[j-1]; j-- {
			values[j], values[j-1] = values[j-1], values[j]
		}
	}
}
