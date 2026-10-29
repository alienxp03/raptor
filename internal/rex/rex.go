package rex

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/alienxp03/raptor/internal/execx"
)

type cmdResult = execx.Result

type Ctx struct {
	Session string
	Block   string
	Client  string
	Title   string
}

func NewContext(session, block, client, title string) Ctx {
	return Ctx{Session: session, Block: block, Client: client, Title: title}
}

func runCmd(dir string, timeout time.Duration, name string, args ...string) (cmdResult, error) {
	return execx.Run(dir, timeout, name, args...)
}

// ---------- rex CLI wrappers ----------

func Run(args ...string) (string, error) {
	r, err := runCmd("", 15*time.Second, "rex", args...)
	if err != nil {
		return r.Stdout, err
	}
	if r.Code != 0 {
		return r.Stdout, fmt.Errorf("rex %s: %s", strings.Join(args, " "), strings.TrimSpace(r.Stderr))
	}
	return r.Stdout, nil
}

func RunQuiet(args ...string) {
	_, _ = Run(args...)
}

// Do targets a client (e.g. session.select). Remote Control required.
func Do(client, action string, kv ...string) error {
	args := []string{"-C", client, "do", action}
	for _, s := range kv {
		args = append(args, s)
	}
	_, err := Run(args...)
	return err
}

type rexSession struct {
	SessionID string `json:"session_id"`
	Label     string `json:"label"`
}

func Sessions() []rexSession {
	out, err := Run("ls", "--json")
	if err != nil {
		return nil
	}
	var data struct {
		Sessions []rexSession `json:"sessions"`
	}
	if json.Unmarshal([]byte(out), &data) != nil {
		return nil
	}
	return data.Sessions
}

func SessionByLabel(label string) (string, bool) {
	for _, s := range Sessions() {
		if s.Label == label {
			return s.SessionID, true
		}
	}
	return "", false
}

// BlockPwd returns the cwd a block last reported, via rex do.
func BlockPwd(blockID string) string {
	if blockID == "" {
		return ""
	}
	script := fmt.Sprintf(
		"local r = rex.block.call('com.superlogical.terminal', 'pwd', { block_id = '%s' }) print(r and r.pwd or '')",
		blockID)
	out, err := Run("do", "-e", script)
	if err != nil {
		return ""
	}
	pwd := strings.TrimSpace(out)
	pwd = strings.TrimPrefix(pwd, "file://")
	return pwd
}

// blockCwd returns the cwd of a block's foreground process (works even when
// the terminal never reported OSC 7, e.g. while a TUI app owns the pane).
func BlockCwd(blockID string) string {
	if blockID == "" {
		return ""
	}
	if p := BlockPwd(blockID); p != "" {
		return p
	}
	script := fmt.Sprintf(
		"local r = rex.block.call('com.superlogical.terminal', 'process', { block_id = '%s' }) print(r and r.foreground and r.foreground.cwd or '')",
		blockID)
	out, err := Run("do", "-e", script)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

// blockForeground returns the foreground process name of a block.
func BlockForeground(blockID string) string {
	if blockID == "" {
		return ""
	}
	script := fmt.Sprintf(
		"local r = rex.block.call('com.superlogical.terminal', 'process', { block_id = '%s' }) print(r and r.foreground and r.foreground.name or '')",
		blockID)
	out, err := Run("do", "-e", script)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

// ---------- zoxide ----------

func ZoxideList() []string {
	r, err := runCmd("", 5*time.Second, "zoxide", "query", "-l")
	if err != nil {
		return nil
	}
	var dirs []string
	for _, line := range strings.Split(strings.TrimSpace(r.Stdout), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			dirs = append(dirs, line)
		}
	}
	return dirs
}

// ---------- last-session state ----------

func statePath() string {
	cache := os.Getenv("XDG_CACHE_HOME")
	if cache == "" {
		home, _ := os.UserHomeDir()
		cache = filepath.Join(home, ".cache")
	}
	return filepath.Join(cache, "rex", "raptor-last")
}

func LastSession() (string, error) {
	data, err := os.ReadFile(statePath())
	if err != nil {
		return "", fmt.Errorf("no previous session recorded yet")
	}
	s := strings.TrimSpace(string(data))
	if s == "" {
		return "", fmt.Errorf("no previous session recorded yet")
	}
	for _, sess := range Sessions() {
		if sess.SessionID == s {
			return s, nil
		}
	}
	return "", fmt.Errorf("the last session is gone")
}

func WriteLast(sid string) {
	if sid == "" {
		return
	}
	_ = os.MkdirAll(filepath.Dir(statePath()), 0o755)
	_ = os.WriteFile(statePath(), []byte(sid+"\n"), 0o644)
}

func SwapLast(current string) { WriteLast(current) }
