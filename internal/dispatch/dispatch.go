package dispatch

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/paths"
	"github.com/alienxp03/raptor/internal/rex"
)

// Dispatch opens dir with the given target, mirroring the old shell script.
func Dispatch(target, dir string, ctx rex.Ctx, cfg config.Config) error {
	switch target {
	case "session":
		name := paths.Basename(dir)
		sid, ok := rex.SessionByLabel(name)
		if !ok {
			out, err := rex.Run("new", "--json", "-c", dir, name)
			if err != nil {
				return err
			}
			var res struct {
				SessionID string `json:"session_id"`
			}
			if json.Unmarshal([]byte(out), &res) != nil || res.SessionID == "" {
				return fmt.Errorf("could not create session for %s", dir)
			}
			sid = res.SessionID
		}
		if ctx.Session != "" && ctx.Session != sid {
			rex.WriteLast(ctx.Session)
		}
		if ctx.Client != "" {
			_ = rex.Do(ctx.Client, "session.select", "session_id="+sid)
		}
		return nil

	case "tab":
		if ctx.Session == "" {
			return fmt.Errorf("no session context")
		}
		out, err := rex.Run("window", "new", "-s", ctx.Session, paths.Basename(dir), "-c", dir, "--json")
		if err != nil {
			return err
		}
		var res struct {
			WindowID string `json:"window_id"`
		}
		_ = json.Unmarshal([]byte(out), &res)
		if res.WindowID != "" {
			if ctx.Client != "" {
				_ = rex.Do(ctx.Client, "session.select", "session_id="+ctx.Session, "window_id="+res.WindowID)
			} else {
				rex.RunQuiet("focus", "-s", ctx.Session, res.WindowID)
			}
		}
		return nil

	case "pane", "pane_left", "pane_above", "pane_below":
		if ctx.Block == "" {
			return fmt.Errorf("no block context")
		}
		dirFlag := "--split=" + SplitDirection(target)
		out, err := rex.Run("split", "-s", ctx.Session, "-b", ctx.Block, dirFlag, "-c", dir, "--json")
		if err != nil {
			return err
		}
		var res struct {
			BlockIDs []string `json:"block_ids"`
		}
		_ = json.Unmarshal([]byte(out), &res)
		if len(res.BlockIDs) > 0 {
			rex.RunQuiet("focus", "-s", ctx.Session, "-b", res.BlockIDs[0])
		}
		return nil

	case "here":
		if ctx.Block == "" {
			return fmt.Errorf("no block context")
		}
		switch rex.BlockForeground(ctx.Block) {
		case "zsh", "bash", "sh", "dash", "ksh", "fish", "nu", "elvish":
			_, _ = rex.Run("send", "-b", ctx.Block, "cd '"+dir+"'\n")
			return nil
		default:
			return fmt.Errorf("pane is not at a shell prompt")
		}

	default:
		return fmt.Errorf("unknown target %q", target)
	}
}

func TargetLabel(t string) string {
	switch t {
	case "session":
		return "session"
	case "tab":
		return "tab"
	case "pane":
		return "pane →"
	case "pane_left":
		return "pane ←"
	case "pane_above":
		return "pane ↑"
	case "pane_below":
		return "pane ↓"
	case "here":
		return "cd here"
	default:
		return t
	}
}

func SplitDirection(target string) string {
	switch target {
	case "pane":
		return "right"
	case "pane_left":
		return "left"
	case "pane_above":
		return "above"
	case "pane_below":
		return "below"
	default:
		return ""
	}
}

var targetOrderHint = []string{"tab", "here", "session"}

func NextTarget(cfg config.Config, cur string, forward bool) string {
	list := cfg.Targets
	if len(list) == 0 {
		list = targetOrderHint
	}
	idx := 0
	for i, t := range list {
		if t == cur {
			idx = i
			break
		}
	}
	step := 1
	if !forward {
		step = -1
	}
	idx = ((idx+step)%len(list) + len(list)) % len(list)
	return list[idx]
}

func HeaderTargets(cfg config.Config, cur string) string {
	var parts []string
	for _, t := range cfg.Targets {
		lbl := TargetLabel(t)
		if t == cur {
			lbl = "[" + lbl + "]"
		}
		parts = append(parts, lbl)
	}
	return strings.Join(parts, " ")
}
