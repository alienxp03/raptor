package api

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
)

func TestColdLauncherDoesNotRequireActivityAPI(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	log := filepath.Join(dir, "calls")
	t.Setenv("STATUS_FALLBACK_LOG", log)
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$STATUS_FALLBACK_LOG"
case "$*" in
 do*) exit 1 ;;
 'ls --json') echo '{"sessions":[{"session_id":"session:one","label":"One"}]}' ;;
 'api call hosts.list') echo '{"hosts":[]}' ;;
 *) echo '{}' ;;
esac
`
	for name, body := range map[string]string{"rex": script, "zoxide": "#!/bin/sh\nprintf '/work/project\\n'\n"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	h := New(rex.Ctx{}, config.Default())
	result, err := h.call("sessions", json.RawMessage(`{}`))
	if err != nil {
		t.Fatalf("optional activity failure hid the cold launcher: %v", err)
	}
	rows := result.(sessionsResult).Items
	if len(rows) != 2 || rows[0].Kind != "session" || rows[1].Path != "/work/project" {
		t.Fatalf("plain discovery rows missing: %+v", rows)
	}
	for _, row := range rows {
		if row.Working || row.State != "" {
			t.Fatalf("failed status scan invented activity: %+v", row)
		}
	}
	if h.activityLoaded {
		t.Fatal("failed activity scan must not become a successful empty snapshot")
	}
	calls, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(calls), "local result = { sessions = {} }") != 1 {
		t.Fatalf("cold fallback repeated the failed status scan: %s", calls)
	}
}
