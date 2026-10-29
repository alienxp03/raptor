package rex

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Pane identifies a terminal across sessions. Window placement is resolved on
// use, so a pane can move to another tab without invalidating its history.
type Pane struct {
	Session string `json:"session_id"`
	Block   string `json:"block_id"`
}

func paneStatePath() string {
	return filepath.Join(filepath.Dir(statePath()), "raptor-last-pane")
}

func WriteLastPane(ctx Ctx) {
	if ctx.Session == "" || ctx.Block == "" {
		return
	}
	data, _ := json.Marshal(Pane{Session: ctx.Session, Block: ctx.Block})
	_ = os.MkdirAll(filepath.Dir(paneStatePath()), 0o755)
	_ = os.WriteFile(paneStatePath(), data, 0o644)
}

func LastPane() (Pane, error) {
	data, err := os.ReadFile(paneStatePath())
	if err != nil {
		return Pane{}, fmt.Errorf("no previous pane recorded yet")
	}
	var pane Pane
	if json.Unmarshal(data, &pane) != nil || pane.Session == "" || pane.Block == "" {
		return Pane{}, fmt.Errorf("invalid previous pane record")
	}
	return pane, nil
}

// SelectSession changes the client session before updating either history.
func SelectSession(ctx Ctx, sid string) error {
	if ctx.Client == "" {
		return fmt.Errorf("no client context")
	}
	if err := Do(ctx.Client, "session.select", "session_id="+sid); err != nil {
		return err
	}
	if ctx.Session != sid {
		WriteLast(ctx.Session)
		WriteLastPane(ctx)
	}
	return nil
}

// SelectLastPane restores a pane's current window, including in another session.
// It records the origin only after both focus and client selection succeed.
func SelectLastPane(ctx Ctx) (Pane, error) {
	if ctx.Client == "" || ctx.Session == "" || ctx.Block == "" {
		return Pane{}, fmt.Errorf("no client, session, or pane context")
	}
	pane, err := LastPane()
	if err != nil {
		return Pane{}, err
	}
	if pane.Session == ctx.Session && pane.Block == ctx.Block {
		return Pane{}, fmt.Errorf("the previous pane is already focused; open another pane with Raptor first")
	}
	args, _ := json.Marshal(map[string]string{"block_id": pane.Block})
	out, err := Run("api", "call", "-s", pane.Session, "session.describe_block", string(args))
	if err != nil {
		return Pane{}, fmt.Errorf("previous pane is unavailable: %w", err)
	}
	var result struct {
		Block struct {
			WindowID string `json:"window_id"`
		} `json:"block"`
	}
	if json.Unmarshal([]byte(out), &result) != nil || result.Block.WindowID == "" {
		return Pane{}, fmt.Errorf("previous pane is not in a window")
	}
	if _, err := Run("api", "call", "-s", pane.Session, "session.focus_block", string(args)); err != nil {
		return Pane{}, err
	}
	if err := Do(ctx.Client, "session.select", "session_id="+pane.Session, "window_id="+result.Block.WindowID); err != nil {
		return Pane{}, err
	}
	WriteLastPane(ctx)
	if ctx.Session != pane.Session {
		WriteLast(ctx.Session)
	}
	return pane, nil
}
