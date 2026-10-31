// Package theme resolves the active Rex theme from the Rex app bundle and
// its macOS preferences. Both interfaces (terminal picker and native app)
// consume the resolved palette; on any failure callers keep their built-in
// colors.
package theme

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"

	"howett.net/plist"
)

// Rex preference domain and bundle identifier for theme lookups.
const (
	prefDomain    = "com.superlogical.rex"
	tokensRelPath = "Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json"
)

// ErrUnavailable reports that no Rex theme could be resolved. Callers fall
// back to their built-in palettes.
var ErrUnavailable = errors.New("rex theme unavailable")

// Color is one sRGB color with components in 0..1.
type Color struct {
	R, G, B float64
}

// Hex renders the color as #rrggbb.
func (c Color) Hex() string {
	to := func(v float64) int { return int(math.Round(clamp01(v) * 255)) }
	return fmt.Sprintf("#%02x%02x%02x", to(c.R), to(c.G), to(c.B))
}

// Theme is the resolved Rex palette in sRGB. Hex strings feed lipgloss and
// the native-app protocol; ANSI holds the terminal palette, indices 0-15.
type Theme struct {
	Name                string   `json:"name"`
	IsDark              bool     `json:"isDark"`
	Background          string   `json:"background"`
	Foreground          string   `json:"foreground"`
	Cursor              string   `json:"cursor"`
	Selection           string   `json:"selection"`
	SelectionForeground string   `json:"selectionForeground"`
	Surface             string   `json:"surface"`
	Accent              string   `json:"accent"`
	ANSI                []string `json:"ansi"`
}

// Options make resolution testable. Zero fields use the real machine state.
type Options struct {
	// RexApp overrides Rex application discovery (directory containing
	// Contents/Resources).
	RexApp string
	// DefaultsOutput replaces `defaults export com.superlogical.rex -`.
	DefaultsOutput func() ([]byte, error)
	// SystemIsDark replaces the global appearance probe.
	SystemIsDark func() bool
}

var (
	mu     sync.Mutex
	cached *Theme
)

// Resolve returns the active Rex theme, or ErrUnavailable. Results are
// cached per process; each picker run is a fresh process.
func Resolve(opts Options) (*Theme, error) {
	mu.Lock()
	defer mu.Unlock()
	if cached != nil {
		return cached, nil
	}
	t, err := resolve(opts)
	if err != nil {
		return nil, err
	}
	cached = t
	return t, nil
}

func resolve(opts Options) (*Theme, error) {
	prefs, err := readPrefs(opts)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	appearance, _ := prefs["Workspace.appearance"].(string)
	if appearance == "" {
		appearance = "system"
	}
	style, _ := prefs["Workspace.interfaceStyle"].(string)
	if style == "" {
		style = "modern"
	}
	if appearance != "system" && appearance != "light" && appearance != "dark" {
		return nil, fmt.Errorf("%w: unsupported appearance %q", ErrUnavailable, appearance)
	}
	// Tinted interface styles redraw UI chrome from the wallpaper, so the
	// theme file no longer describes what is on screen.
	if style == "blendTheme" || style == "useTheme" {
		return nil, fmt.Errorf("%w: interface style %q", ErrUnavailable, style)
	}
	dark := appearance == "dark" || (appearance == "system" && systemIsDark(opts))
	key := "Workspace.lightThemeID"
	if dark {
		key = "Workspace.darkThemeID"
	}
	id, _ := prefs[key].(string)
	if id == "" {
		return nil, fmt.Errorf("%w: no %s", ErrUnavailable, key)
	}

	if custom := parseCustomThemes(prefs["Workspace.customThemes"], id); custom != nil {
		return custom, nil
	}
	data, err := builtinThemes(opts)
	if err != nil {
		return nil, err
	}
	return builtinTheme(data, id, dark)
}

func systemIsDark(opts Options) bool {
	if opts.SystemIsDark != nil {
		return opts.SystemIsDark()
	}
	out, err := exec.Command("defaults", "read", "-g", "AppleInterfaceStyle").Output()
	return err == nil && strings.TrimSpace(string(out)) == "Dark"
}

func readPrefs(opts Options) (map[string]any, error) {
	var data []byte
	if opts.DefaultsOutput != nil {
		var err error
		if data, err = opts.DefaultsOutput(); err != nil {
			return nil, err
		}
	} else {
		var err error
		if data, err = exec.Command("defaults", "export", prefDomain, "-").Output(); err != nil {
			return nil, err
		}
	}
	// `defaults export` writes an XML plist. howett.net/plist handles the
	// date and data values that JSON conversion rejects.
	var prefs map[string]any
	if err := plist.NewDecoder(bytes.NewReader(data)).Decode(&prefs); err != nil {
		return nil, err
	}
	return prefs, nil
}

func builtinThemes(opts Options) ([]map[string]any, error) {
	path := tokensPath(opts)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	var entries []map[string]any
	if err := json.Unmarshal(data, &entries); err != nil {
		return nil, fmt.Errorf("%w: theme catalog: %v", ErrUnavailable, err)
	}
	return entries, nil
}

func tokensPath(opts Options) string {
	if opts.RexApp != "" {
		return filepath.Join(opts.RexApp, tokensRelPath)
	}
	for _, app := range rexAppCandidates() {
		p := filepath.Join(app, tokensRelPath)
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return filepath.Join("/Applications/Rex.app", tokensRelPath)
}

func rexAppCandidates() []string {
	var dirs []string
	if env := os.Getenv("RAPTOR_REX_APP"); env != "" {
		dirs = append(dirs, env)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		home = ""
	}
	for _, base := range []string{"/Applications", filepath.Join(home, "Applications")} {
		if base == "/" {
			continue
		}
		dirs = append(dirs,
			filepath.Join(base, "Rex.app"),
			filepath.Join(base, "Rex Beta.app"),
		)
	}
	return dirs
}

// parseCustomThemes decodes Workspace.customThemes (a plist data blob
// holding a JSON document) and returns the theme with the given id, if any.
// Custom themes ship a terminal palette rather than UI tokens.
func parseCustomThemes(value any, id string) *Theme {
	var blob []byte
	switch raw := value.(type) {
	case []byte:
		blob = raw
	case string:
		blob = []byte(raw)
	default:
		return nil
	}
	var entries []map[string]any
	if err := json.Unmarshal(blob, &entries); err != nil {
		return nil
	}
	for _, entry := range entries {
		if entry["id"] != id {
			continue
		}
		palette, _ := entry["palette"].(map[string]any)
		if palette == nil {
			return nil
		}
		ansi := hexList(palette["ansi"], 16)
		if len(ansi) < 16 {
			return nil
		}
		background := hexString(palette["background"])
		foreground := hexString(palette["foreground"])
		selection := hexString(palette["selectionBackground"])
		if background == "" || foreground == "" || selection == "" {
			return nil
		}
		accent := hexString(palette["cursor"])
		selFg := hexString(palette["selectionForeground"])
		if selFg == "" {
			selFg = background
		}
		dark := isDarkHex(background)
		surface := mixHex(background, foreground, 0.12)
		name, _ := entry["name"].(string)
		if name == "" {
			name = id
		}
		return &Theme{Name: name, IsDark: dark, Background: background,
			Foreground: foreground, Cursor: accent, Selection: selection,
			SelectionForeground: selFg, Surface: surface, Accent: accent, ANSI: ansi}
	}
	return nil
}

func builtinTheme(entries []map[string]any, id string, dark bool) (*Theme, error) {
	for _, entry := range entries {
		if entry["id"] != id {
			continue
		}
		semantic, _ := entry["semantic"].(map[string]any)
		source, _ := entry["source"].(map[string]any)
		if source == nil {
			return nil, fmt.Errorf("%w: theme %q has no palette", ErrUnavailable, id)
		}
		ansi := make([]string, 16)
		for i := 0; i < 16; i++ {
			c := p3Color(semantic[fmt.Sprintf("terminalAnsi%d", i)])
			if c == nil {
				ansi = hexList(source["ansi"], 16)
				if len(ansi) < 16 {
					return nil, fmt.Errorf("%w: theme %q has no ANSI palette", ErrUnavailable, id)
				}
				break
			}
			ansi[i] = c.Hex()
		}
		pick := func(semanticKey string, sourceKey string) (string, error) {
			if semantic != nil {
				if c := p3Color(semantic[semanticKey]); c != nil {
					return c.Hex(), nil
				}
			}
			if hex := hexString(source[sourceKey]); hex != "" {
				return hex, nil
			}
			return "", fmt.Errorf("%w: theme %q has no %s", ErrUnavailable, id, semanticKey)
		}
		background, err := pick("terminalBackground", "background")
		if err != nil {
			return nil, err
		}
		foreground, err := pick("terminalForeground", "foreground")
		if err != nil {
			return nil, err
		}
		cursor, err := pick("terminalCursor", "cursor")
		if err != nil {
			return nil, err
		}
		selection, err := pick("terminalSelection", "selectionBackground")
		if err != nil {
			return nil, err
		}
		selectionForeground, err := pick("terminalSelectionForeground", "selectionForeground")
		if err != nil {
			return nil, err
		}
		surface := ""
		if c := p3Color(semantic["surfaceRaised"]); c != nil {
			surface = c.Hex()
		} else {
			surface = mixHex(background, foreground, 0.12)
		}
		accent := cursor
		if c := p3Color(semantic["accentSolid"]); c != nil {
			accent = c.Hex()
		}
		name, _ := entry["name"].(string)
		if name == "" {
			name = id
		}
		return &Theme{Name: name, IsDark: dark, Background: background,
			Foreground: foreground, Cursor: cursor, Selection: selection,
			SelectionForeground: selectionForeground, Surface: surface, Accent: accent, ANSI: ansi}, nil
	}
	return nil, fmt.Errorf("%w: theme %q not found", ErrUnavailable, id)
}

// p3Color reads one Rex semantic color (display-p3 floats) and converts it
// to sRGB.
func p3Color(value any) *Color {
	object, ok := value.(map[string]any)
	if !ok {
		return nil
	}
	red, okR := object["red"].(float64)
	green, okG := object["green"].(float64)
	blue, okB := object["blue"].(float64)
	if !okR || !okG || !okB {
		return nil
	}
	c := p3ToSRGB(Color{R: red, G: green, B: blue})
	return &c
}

func hexString(value any) string {
	switch v := value.(type) {
	case string:
		return normalizeHex(v)
	case map[string]any:
		if c := p3Color(v); c != nil {
			return c.Hex()
		}
	}
	return ""
}

func hexList(value any, want int) []string {
	items, ok := value.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(items))
	for _, item := range items {
		if hex := hexString(item); hex != "" {
			out = append(out, hex)
		}
	}
	if len(out) < want {
		return nil
	}
	return out
}

func normalizeHex(value string) string {
	value = strings.TrimPrefix(value, "#")
	if len(value) != 6 {
		return ""
	}
	for _, r := range value {
		if !strings.ContainsRune("0123456789abcdefABCDEF", r) {
			return ""
		}
	}
	return "#" + strings.ToLower(value)
}

func parseHex(value string) (Color, bool) {
	normalized := normalizeHex(value)
	if normalized == "" {
		return Color{}, false
	}
	var n int32
	fmt.Sscanf(normalized[1:], "%6x", &n)
	return Color{
		R: float64((n>>16)&0xff) / 255,
		G: float64((n>>8)&0xff) / 255,
		B: float64(n&0xff) / 255,
	}, true
}

func isDarkHex(value string) bool {
	c, ok := parseHex(value)
	if !ok {
		return true
	}
	// Rec. 709 luma.
	return 0.2126*c.R+0.7152*c.G+0.0722*c.B < 0.5
}

// mixHex blends two hex colors by fraction t of the second.
func mixHex(base, overlay string, t float64) string {
	a, okA := parseHex(base)
	b, okB := parseHex(overlay)
	if !okA {
		return base
	}
	if !okB {
		return base
	}
	return Color{
		R: a.R + (b.R-a.R)*t,
		G: a.G + (b.G-a.G)*t,
		B: a.B + (b.B-a.B)*t,
	}.Hex()
}

func clamp01(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}

// p3ToSRGB converts linear-light display-P3 primaries to sRGB and applies
// the sRGB transfer function.
func p3ToSRGB(c Color) Color {
	r, g, b := c.R, c.G, c.B
	// Linearize display P3 (sRGB-like 2.2 gamma piecewise).
	r, g, b = p3EOTF(r), p3EOTF(g), p3EOTF(b)
	// Display P3 -> sRGB linear matrix.
	rr := clamp01(1.224940*r - 0.224734*g + 0.0*b)
	gg := clamp01(-0.042056*r + 1.041858*g + 0.0*b)
	bb := clamp01(-0.019638*r - 0.078637*g + 1.098275*b)
	return Color{R: sRGBEncode(rr), G: sRGBEncode(gg), B: sRGBEncode(bb)}
}

func p3EOTF(v float64) float64 {
	// Display P3 uses the sRGB transfer function.
	if v <= 0.04045 {
		return v / 12.92
	}
	return math.Pow((v+0.055)/1.055, 2.4)
}

func sRGBEncode(v float64) float64 {
	if v <= 0.0031308 {
		return v * 12.92
	}
	return 1.055*math.Pow(v, 1/2.4) - 0.055
}
