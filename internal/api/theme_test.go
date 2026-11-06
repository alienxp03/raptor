package api

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	"github.com/alienxp03/raptor/internal/theme"
)

func TestThemeResponseEnvelope(t *testing.T) {
	t.Setenv("RAPTOR_THEME", "")
	fakeTool(t, "defaults", `printf '%s' '<plist version="1.0"><dict>
<key>Workspace.appearance</key><string>dark</string>
<key>Workspace.interfaceStyle</key><string>blendTheme</string>
<key>Workspace.darkThemeID</key><string>wire-forest</string>
</dict></plist>'`)
	app := t.TempDir()
	t.Setenv("RAPTOR_REX_APP", app)
	path := filepath.Join(app, "Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json")
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	palette := map[string]any{
		"background": "#102030", "foreground": "#e0e0e0", "cursor": "#aabbcc",
		"selectionBackground": "#456789", "selectionForeground": "#ddeeff",
		"ansi": strings.Fields(strings.Repeat("#112233 ", 16)),
	}
	gray := func(value float64) map[string]any {
		return map[string]any{"colorSpace": "display-p3", "red": value, "green": value, "blue": value, "alpha": 1}
	}
	semantic := map[string]any{
		"surfaceRaised": gray(0.2), "content": gray(0.9), "selection": gray(0.75),
		"selectionForeground": gray(0.1), "controlOnOverlay": gray(0.3),
	}
	catalog, err := json.Marshal([]map[string]any{{"id": "wire-forest", "name": "Wire Forest", "source": palette, "semantic": semantic}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, catalog, 0644); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	h := New(rex.Ctx{}, config.Default())
	if err := h.Serve(strings.NewReader(`{"id":1,"method":"theme","params":{}}`), &output); err != nil {
		t.Fatal(err)
	}
	var response struct {
		ID     int64 `json:"id"`
		Result struct {
			Theme *theme.Theme `json:"theme"`
		} `json:"result"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(output.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	th := response.Result.Theme
	if response.ID != 1 || response.Error != "" || th == nil {
		t.Fatalf("native API requires result.theme, got %s", output.Bytes())
	}
	if th.UI == nil || th.UI.Background != "#333333" || th.UI.Selection != "#bfbfbf" || th.UI.SelectionForeground != "#1a191a" || th.InterfaceStyle != "blendTheme" {
		t.Fatalf("missing native UI roles: theme=%+v ui=%+v", th, th.UI)
	}
	if th.Name != "Wire Forest" || th.Background != "#102030" || th.Selection != "#456789" || th.SelectionForeground != "#ddeeff" || len(th.ANSI) != 16 {
		t.Fatalf("unexpected wire palette: %+v", th)
	}
}
