package theme

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const fixtureThemes = `[
  {
    "id": "test-dusk",
    "name": "Test Dusk",
    "appearance": "dark",
    "source": {
      "background": "#171412",
      "foreground": "#ddd0bf",
      "cursor": "#e8a860",
      "selectionBackground": "#423528",
      "selectionForeground": "#f2e9dc",
      "ansi": ["#26201c", "#d96e56", "#a0b06a", "#e0a45c", "#8598b0", "#bd8aa2", "#92b39c", "#c2b4a3",
               "#6e6355", "#e88a72", "#b8c786", "#efbc7c", "#a0b2c8", "#d1a5b8", "#accab4", "#f2e9dc"]
    },
    "semantic": {
      "terminalBackground": {"colorSpace": "display-p3", "red": 0.08834, "green": 0.0788, "blue": 0.0714, "alpha": 1},
      "terminalForeground": {"colorSpace": "display-p3", "red": 0.85, "green": 0.8, "blue": 0.72, "alpha": 1},
      "terminalCursor": {"colorSpace": "display-p3", "red": 0.92, "green": 0.66, "blue": 0.36, "alpha": 1},
      "terminalSelection": {"colorSpace": "display-p3", "red": 0.27, "green": 0.21, "blue": 0.16, "alpha": 1},
      "terminalSelectionForeground": {"colorSpace": "display-p3", "red": 0.94, "green": 0.9, "blue": 0.85, "alpha": 1},
      "surfaceRaised": {"colorSpace": "display-p3", "red": 0.152, "green": 0.143, "blue": 0.135, "alpha": 1},
      "accentSolid": {"colorSpace": "display-p3", "red": 0.72, "green": 0.51, "blue": 0.26, "alpha": 1},
      "terminalAnsi0": {"colorSpace": "display-p3", "red": 0.149, "green": 0.125, "blue": 0.11, "alpha": 1},
      "terminalAnsi1": {"colorSpace": "display-p3", "red": 0.85, "green": 0.43, "blue": 0.34, "alpha": 1},
      "terminalAnsi2": {"colorSpace": "display-p3", "red": 0.72, "green": 0.78, "blue": 0.53, "alpha": 1},
      "terminalAnsi3": {"colorSpace": "display-p3", "red": 0.94, "green": 0.74, "blue": 0.49, "alpha": 1},
      "terminalAnsi4": {"colorSpace": "display-p3", "red": 0.63, "green": 0.7, "blue": 0.79, "alpha": 1},
      "terminalAnsi5": {"colorSpace": "display-p3", "red": 0.83, "green": 0.54, "blue": 0.72, "alpha": 1},
      "terminalAnsi6": {"colorSpace": "display-p3", "red": 0.67, "green": 0.79, "blue": 0.71, "alpha": 1},
      "terminalAnsi7": {"colorSpace": "display-p3", "red": 0.76, "green": 0.71, "blue": 0.64, "alpha": 1},
      "terminalAnsi8": {"colorSpace": "display-p3", "red": 0.43, "green": 0.39, "blue": 0.33, "alpha": 1},
      "terminalAnsi9": {"colorSpace": "display-p3", "red": 0.91, "green": 0.54, "blue": 0.45, "alpha": 1},
      "terminalAnsi10": {"colorSpace": "display-p3", "red": 0.72, "green": 0.78, "blue": 0.53, "alpha": 1},
      "terminalAnsi11": {"colorSpace": "display-p3", "red": 0.94, "green": 0.74, "blue": 0.49, "alpha": 1},
      "terminalAnsi12": {"colorSpace": "display-p3", "red": 0.63, "green": 0.7, "blue": 0.79, "alpha": 1},
      "terminalAnsi13": {"colorSpace": "display-p3", "red": 0.82, "green": 0.65, "blue": 0.72, "alpha": 1},
      "terminalAnsi14": {"colorSpace": "display-p3", "red": 0.67, "green": 0.79, "blue": 0.71, "alpha": 1},
      "terminalAnsi15": {"colorSpace": "display-p3", "red": 0.95, "green": 0.91, "blue": 0.86, "alpha": 1}
    }
  },
  {
    "id": "test-dawn",
    "name": "Test Dawn",
    "appearance": "light",
    "source": {
      "background": "#fafafa",
      "foreground": "#333940",
      "cursor": "#4a90d9",
      "selectionBackground": "#d6e6f7",
      "selectionForeground": "#333940",
      "ansi": ["#333940", "#c94f46", "#4a9256", "#b28422", "#3d7cc9", "#8a5fb0", "#2e8fa0", "#d7dade",
               "#757d86", "#e0655b", "#58ab66", "#c9982e", "#5292dd", "#a075c6", "#3ba6b8", "#ffffff"]
    }
  }
]`

// fixture installs a fake Rex app bundle and preference export.
func fixture(t *testing.T, prefsPlist string, customJSON string) Options {
	t.Helper()
	app := t.TempDir()
	dir := filepath.Join(app, "Contents", "Resources", "SuperUI_SuperDesignTokens.bundle", "Contents", "Resources")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "themes.json"), []byte(fixtureThemes), 0o644); err != nil {
		t.Fatal(err)
	}
	if customJSON != "" {
		prefsPlist = strings.Replace(prefsPlist, "</dict>",
			"<key>Workspace.customThemes</key><data>"+customJSON+"</data></dict>", 1)
	}
	return Options{
		RexApp: app,
		DefaultsOutput: func() ([]byte, error) {
			return []byte(prefsPlist), nil
		},
		SystemIsDark: func() bool { return true },
	}
}

const basePrefs = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Workspace.darkThemeID</key><string>test-dusk</string>
<key>Workspace.lightThemeID</key><string>test-dawn</string>
</dict></plist>`

func resolveOpts(t *testing.T, opts Options) (*Theme, error) {
	t.Helper()
	// Resolve caches per process; tests need fresh state each call.
	mu.Lock()
	cached = nil
	mu.Unlock()
	return Resolve(opts)
}

func TestResolveDarkViaSystemAppearance(t *testing.T) {
	th, err := resolveOpts(t, fixture(t, basePrefs, ""))
	if err != nil {
		t.Fatal(err)
	}
	if th.Name != "Test Dusk" || !th.IsDark {
		t.Fatalf("unexpected theme: %+v", th)
	}
	if th.Background != "#171412" || th.Surface != "#272422" {
		t.Fatalf("background/surface mismatch: %s %s", th.Background, th.Surface)
	}
	if len(th.ANSI) != 16 {
		t.Fatalf("ansi palette incomplete: %d", len(th.ANSI))
	}
	if !strings.HasPrefix(th.ANSI[9], "#") {
		t.Fatalf("ansi entry not hex: %s", th.ANSI[9])
	}
	if th.SelectionForeground == "" || th.Accent == "" {
		t.Fatalf("missing selection foreground or accent: %+v", th)
	}
}

func TestResolveSelectsLightWhenSystemLight(t *testing.T) {
	opts := fixture(t, basePrefs, "")
	opts.SystemIsDark = func() bool { return false }
	th, err := resolveOpts(t, opts)
	if err != nil {
		t.Fatal(err)
	}
	// test-dawn has no semantic block: resolution must fall back to source.
	if th.Name != "Test Dawn" || th.IsDark {
		t.Fatalf("unexpected theme: %+v", th)
	}
	if th.Background != "#fafafa" || th.ANSI[15] != "#ffffff" {
		t.Fatalf("source fallback broken: %+v", th)
	}
}

func TestResolveAppearanceOverridesSystem(t *testing.T) {
	prefs := strings.Replace(basePrefs, "<dict>",
		"<dict><key>Workspace.appearance</key><string>light</string>", 1)
	th, err := resolveOpts(t, fixture(t, prefs, ""))
	if err != nil {
		t.Fatal(err)
	}
	if th.Name != "Test Dawn" {
		t.Fatalf("appearance override ignored: %+v", th)
	}
}

func TestResolveRejectsTintedStyles(t *testing.T) {
	prefs := strings.Replace(basePrefs, "<dict>",
		"<dict><key>Workspace.interfaceStyle</key><string>useTheme</string>", 1)
	if _, err := resolveOpts(t, fixture(t, prefs, "")); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("want ErrUnavailable, got %v", err)
	}
}

func TestResolveMissingTheme(t *testing.T) {
	prefs := strings.Replace(basePrefs, "test-dusk", "no-such-theme", 1)
	if _, err := resolveOpts(t, fixture(t, prefs, "")); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("want ErrUnavailable, got %v", err)
	}
}

func TestResolveCustomTheme(t *testing.T) {
	custom, err := json.Marshal([]map[string]any{{
		"id":   "test-dusk",
		"name": "My Custom",
		"palette": map[string]any{
			"background":          "#101010",
			"foreground":          "#eeeeee",
			"cursor":              "#ff8800",
			"selectionBackground": "#333333",
			"selectionForeground": "#ffffff",
			"ansi": []string{"#101010", "#ff5555", "#50fa7b", "#f1fa8d",
				"#bd93f9", "#ff79c6", "#8be9fd", "#bfbfbf",
				"#6272a4", "#ff6e6e", "#69ff94", "#ffffa5",
				"#d6acff", "#ff92df", "#a8ffff", "#ffffff",
				"#extra"},
		},
	}})
	if err != nil {
		t.Fatal(err)
	}
	th, err := resolveOpts(t, fixture(t, basePrefs, customLabel(custom)))
	if err != nil {
		t.Fatal(err)
	}
	if th.Name != "My Custom" || th.Background != "#101010" {
		t.Fatalf("custom theme not used: %+v", th)
	}
	if th.Selection != "#333333" || th.SelectionForeground != "#ffffff" {
		t.Fatalf("custom selection broken: %+v", th)
	}
	if th.Surface == th.Background {
		t.Fatalf("surface should derive from background mix: %s", th.Surface)
	}
}

// customLabel wraps JSON bytes as a plist <data> payload (base64).
func customLabel(jsonBytes []byte) string {
	return base64.StdEncoding.EncodeToString(jsonBytes)
}

func TestHexHelpers(t *testing.T) {
	if normalizeHex("#ABCDEF") != "#abcdef" {
		t.Fatal("normalizeHex case")
	}
	if normalizeHex("xyz") != "" {
		t.Fatal("normalizeHex rejects junk")
	}
	if !isDarkHex("#171412") || isDarkHex("#fafafa") {
		t.Fatal("isDarkHex luma")
	}
	// Mid blend of black and white must be a mid gray.
	if got := mixHex("#000000", "#ffffff", 0.5); got != "#808080" && got != "#7f7f7f" {
		t.Fatalf("mixHex: %s", got)
	}
	c, ok := parseHex("#B88242")
	if !ok || c.Hex() != "#b88242" {
		t.Fatalf("parseHex round trip: %+v %v", c, ok)
	}
}
