package rex

import (
	"encoding/json"
	"fmt"
	"net/url"
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

// RunOn targets a host's Rex server. The empty host and the local label are
// the local server: its sessions need no -S flag.
func RunOn(host string, args ...string) (string, error) {
	if host == "" || host == LocalHostLabel {
		return Run(args...)
	}
	return Run(append([]string{"-S", host}, args...)...)
}

// RunOnBounded bounds a host call. Remote calls pass rex's own --timeout so a
// down host cannot stall the sessions view: rex otherwise waits its default
// 10s per connection. Local calls only get the process kill as a backstop.
// The extra second covers process startup and shutdown.
func RunOnBounded(host string, seconds int, args ...string) (string, error) {
	timeout := time.Duration(seconds+1) * time.Second
	if host == "" || host == LocalHostLabel {
		r, err := runCmd("", timeout, "rex", args...)
		if err != nil {
			return r.Stdout, err
		}
		if r.Code != 0 {
			return r.Stdout, fmt.Errorf("rex %s: %s", strings.Join(args, " "), strings.TrimSpace(r.Stderr))
		}
		return r.Stdout, nil
	}
	full := append([]string{"-S", host, "--timeout", fmt.Sprintf("%ds", seconds)}, args...)
	r, err := runCmd("", timeout, "rex", full...)
	if err != nil {
		return r.Stdout, err
	}
	if r.Code != 0 {
		return r.Stdout, fmt.Errorf("rex %s: %s", strings.Join(full, " "), strings.TrimSpace(r.Stderr))
	}
	return r.Stdout, nil
}

// DoOn targets a client on one host's server.
func DoOn(host, client, action string, kv ...string) error {
	args := []string{"-C", client, "do", action}
	for _, s := range kv {
		args = append(args, s)
	}
	_, err := RunOn(host, args...)
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
	out, err := Run("do", "-b", blockID, "-e", script)
	if err != nil {
		return ""
	}
	return reportedDirectory(strings.TrimSpace(out))
}

// blockCwd returns the cwd of a block's foreground process (works even when
// the terminal never reported OSC 7, e.g. while a TUI app owns the pane).
func BlockCwd(blockID string) string {
	return BlockCwdInSession("", blockID)
}

// BlockCwdInSession avoids inheriting an unrelated caller's REX_SESSION when
// a backend was explicitly given context for another session.
func BlockCwdInSession(sessionID, blockID string) string {
	if blockID == "" {
		return ""
	}
	// Resolve reported cwd and foreground fallback in one Rex invocation.
	script := fmt.Sprintf(
		"local ok, r = pcall(rex.block.call, 'com.superlogical.terminal', 'pwd', { block_id = '%s' }) "+
			"local pwd = ok and r and r.pwd "+
			"if pwd and pwd ~= '' then print(pwd) else "+
			"local p = rex.block.call('com.superlogical.terminal', 'process', { block_id = '%s' }) "+
			"print(p and p.foreground and p.foreground.cwd or '') end",
		blockID, blockID)
	args := []string{"do"}
	if sessionID != "" {
		args = append(args, "-s", sessionID)
	}
	args = append(args, "-b", blockID, "-e", script)
	out, err := Run(args...)
	if err != nil {
		return ""
	}
	return reportedDirectory(strings.TrimSpace(out))
}

// reportedDirectory decodes the file URL returned by Rex's pwd method (OSC 7).
// URL authorities are metadata, not a path prefix. Plain paths stay unchanged.
func reportedDirectory(value string) string {
	if !strings.HasPrefix(value, "file:") {
		return value
	}
	u, err := url.Parse(value)
	if err != nil || u.Scheme != "file" || u.Opaque != "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || !filepath.IsAbs(u.Path) {
		return ""
	}
	return u.Path
}

// blockForeground returns the foreground process name of a block.
func BlockForeground(blockID string) string {
	if blockID == "" {
		return ""
	}
	script := fmt.Sprintf(
		"local r = rex.block.call('com.superlogical.terminal', 'process', { block_id = '%s' }) print(r and r.foreground and r.foreground.name or '')",
		blockID)
	out, err := Run("do", "-b", blockID, "-e", script)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

// ---------- zoxide ----------

func ZoxideList() []string {
	return parseZoxide(zoxideOut(""))
}

// ZoxideListOn lists one host's frecency directories. Remote hosts answer over
// SSH; a non-interactive login may not carry zoxide on PATH, so well-known
// install locations are tried before giving up.
func ZoxideListOn(host string) []string {
	if host == "" || host == LocalHostLabel {
		return ZoxideList()
	}
	return parseZoxide(remoteZoxideOut(host))
}

func parseZoxide(out string, err error) []string {
	if err != nil {
		return nil
	}
	var dirs []string
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			dirs = append(dirs, line)
		}
	}
	return dirs
}

func zoxideOut(host string) (string, error) {
	r, err := runCmd("", 5*time.Second, "zoxide", "query", "-l")
	return r.Stdout, err
}

// remoteZoxideCandidates keeps unexpanded tilde paths: the remote shell expands them.
var remoteZoxideCandidates = []string{
	"zoxide",
	"~/.local/share/mise/shims/zoxide",
	"~/.local/bin/zoxide",
	"~/.cargo/bin/zoxide",
	"/usr/local/bin/zoxide",
}

func remoteZoxideOut(host string) (string, error) {
	for _, zoxide := range remoteZoxideCandidates {
		r, err := runCmd("", 8*time.Second, "ssh",
			"-o", "BatchMode=yes", "-o", "ConnectTimeout=4", host,
			zoxide+" query -l")
		if err == nil && r.Code == 0 {
			return r.Stdout, nil
		}
	}
	return "", fmt.Errorf("zoxide is unavailable on %s", host)
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

// SelectLast switches the Rex client to the saved session, then remembers the
// current session so the action toggles on its next use.
func SelectLast(ctx Ctx) (string, error) {
	if ctx.Client == "" {
		return "", fmt.Errorf("no client context")
	}
	sid, err := LastSession()
	if err != nil {
		return "", err
	}
	if sid == ctx.Session {
		return "", fmt.Errorf("the previous session is already selected; switch sessions with Raptor first")
	}
	if err := SelectSession(ctx, sid); err != nil {
		return "", err
	}
	return sid, nil
}
