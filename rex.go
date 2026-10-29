package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// ---------- exec helpers ----------

type cmdResult struct {
	Stdout string
	Stderr string
	Code   int
}

func runCmd(dir string, timeout time.Duration, name string, args ...string) (cmdResult, error) {
	cmd := exec.Command(name, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	done := make(chan error, 1)
	if err := cmd.Start(); err != nil {
		return cmdResult{}, err
	}
	go func() { done <- cmd.Wait() }()
	if timeout > 0 {
		select {
		case err := <-done:
			return finish(err, out.String(), errb.String())
		case <-time.After(timeout):
			_ = cmd.Process.Kill()
			<-done
			return cmdResult{Stdout: out.String(), Stderr: "timed out"}, fmt.Errorf("%s timed out", name)
		}
	}
	err := <-done
	return finish(err, out.String(), errb.String())
}

func finish(err error, out, errOut string) (cmdResult, error) {
	code := 0
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else {
			return cmdResult{Stdout: out, Stderr: errOut}, err
		}
	}
	return cmdResult{Stdout: out, Stderr: errOut, Code: code}, nil
}

// ---------- rex CLI wrappers ----------

func rexRun(args ...string) (string, error) {
	r, err := runCmd("", 15*time.Second, "rex", args...)
	if err != nil {
		return r.Stdout, err
	}
	if r.Code != 0 {
		return r.Stdout, fmt.Errorf("rex %s: %s", strings.Join(args, " "), strings.TrimSpace(r.Stderr))
	}
	return r.Stdout, nil
}

func rexRunQuiet(args ...string) {
	_, _ = rexRun(args...)
}

// rexDo targets a client (e.g. session.select). Remote Control required.
func rexDo(client, action string, kv ...string) error {
	args := []string{"-C", client, "do", action}
	for _, s := range kv {
		args = append(args, s)
	}
	_, err := rexRun(args...)
	return err
}

type rexSession struct {
	SessionID string `json:"session_id"`
	Label     string `json:"label"`
}

func rexSessions() []rexSession {
	out, err := rexRun("ls", "--json")
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

func sessionByLabel(label string) (string, bool) {
	for _, s := range rexSessions() {
		if s.Label == label {
			return s.SessionID, true
		}
	}
	return "", false
}

// blockPwd returns the cwd a block last reported, via rex do.
func blockPwd(blockID string) string {
	if blockID == "" {
		return ""
	}
	script := fmt.Sprintf(
		"local r = rex.block.call('com.superlogical.terminal', 'pwd', { block_id = '%s' }) print(r and r.pwd or '')",
		blockID)
	out, err := rexRun("do", "-e", script)
	if err != nil {
		return ""
	}
	pwd := strings.TrimSpace(out)
	pwd = strings.TrimPrefix(pwd, "file://")
	return pwd
}

// blockCwd returns the cwd of a block's foreground process (works even when
// the terminal never reported OSC 7, e.g. while a TUI app owns the pane).
func blockCwd(blockID string) string {
	if blockID == "" {
		return ""
	}
	if p := blockPwd(blockID); p != "" {
		return p
	}
	script := fmt.Sprintf(
		"local r = rex.block.call('com.superlogical.terminal', 'process', { block_id = '%s' }) print(r and r.foreground and r.foreground.cwd or '')",
		blockID)
	out, err := rexRun("do", "-e", script)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

// blockForeground returns the foreground process name of a block.
func blockForeground(blockID string) string {
	if blockID == "" {
		return ""
	}
	script := fmt.Sprintf(
		"local r = rex.block.call('com.superlogical.terminal', 'process', { block_id = '%s' }) print(r and r.foreground and r.foreground.name or '')",
		blockID)
	out, err := rexRun("do", "-e", script)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

// ---------- zoxide ----------

func zoxideList() []string {
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
	return filepath.Join(cache, "rex", "zpick-last")
}

func lastSession() (string, error) {
	data, err := os.ReadFile(statePath())
	if err != nil {
		return "", fmt.Errorf("no previous session recorded yet")
	}
	s := strings.TrimSpace(string(data))
	if s == "" {
		return "", fmt.Errorf("no previous session recorded yet")
	}
	for _, sess := range rexSessions() {
		if sess.SessionID == s {
			return s, nil
		}
	}
	return "", fmt.Errorf("the last session is gone")
}

func writeLast(sid string) {
	if sid == "" {
		return
	}
	_ = os.MkdirAll(filepath.Dir(statePath()), 0o755)
	_ = os.WriteFile(statePath(), []byte(sid+"\n"), 0o644)
}

func swapLast(current string) { writeLast(current) }
