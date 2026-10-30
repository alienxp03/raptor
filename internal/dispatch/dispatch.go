package dispatch

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode"

	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/paths"
	"github.com/alienxp03/raptor/internal/rex"
)

// Dispatch opens dir with the given target, mirroring the old shell script.
func Dispatch(target, dir string, ctx rex.Ctx, cfg config.Config) error {
	switch target {
	case "session":
		if ctx.Client == "" {
			return fmt.Errorf("no client context")
		}
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
		return rex.SelectSession(ctx, sid)

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
		if json.Unmarshal([]byte(out), &res) != nil || res.WindowID == "" {
			return fmt.Errorf("could not identify the new tab")
		}
		if ctx.Client != "" {
			if err := rex.Do(ctx.Client, "session.select", "session_id="+ctx.Session, "window_id="+res.WindowID); err != nil {
				return err
			}
		} else if _, err := rex.Run("focus", "-s", ctx.Session, res.WindowID); err != nil {
			return err
		}
		rex.WriteLastPane(ctx)
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
		if json.Unmarshal([]byte(out), &res) != nil || len(res.BlockIDs) == 0 {
			return fmt.Errorf("could not identify the new pane")
		}
		if _, err := rex.Run("focus", "-s", ctx.Session, res.BlockIDs[0]); err != nil {
			return err
		}
		if ctx.Client != "" {
			// Server focus alone does not select the pane's window on the
			// requesting app, particularly while the native picker has focus.
			args, _ := json.Marshal(map[string]string{"block_id": res.BlockIDs[0]})
			out, err := rex.Run("api", "call", "-s", ctx.Session, "session.describe_block", string(args))
			if err != nil {
				return err
			}
			var placement struct {
				Block struct {
					WindowID string `json:"window_id"`
				} `json:"block"`
			}
			if json.Unmarshal([]byte(out), &placement) != nil || placement.Block.WindowID == "" {
				return fmt.Errorf("could not identify the new pane's window")
			}
			if err := rex.Do(ctx.Client, "session.select", "session_id="+ctx.Session, "window_id="+placement.Block.WindowID); err != nil {
				return err
			}
		}
		rex.WriteLastPane(ctx)
		return nil

	case "here":
		if ctx.Block == "" {
			return fmt.Errorf("no block context")
		}
		shell := rex.BlockForeground(ctx.Block)
		switch shell {
		case "zsh", "bash", "sh", "dash", "ksh", "fish", "nu", "elvish":
			command, err := shellCD(shell, dir)
			if err != nil {
				return err
			}
			_, err = rex.Run("send", "-b", ctx.Block, command)
			return err
		default:
			return fmt.Errorf("pane is not at a shell prompt")
		}

	default:
		return fmt.Errorf("unknown target %q", target)
	}
}

// shellCD quotes paths as data, never as executable shell input.
func shellCD(shell, dir string) (string, error) {
	if strings.IndexFunc(dir, unicode.IsControl) >= 0 {
		return "", fmt.Errorf("directory contains terminal control characters")
	}
	if shell == "nu" || shell == "elvish" {
		// These shells do not use POSIX quote concatenation. Keep their existing
		// simple-path support, but do not guess an escaping syntax.
		if strings.Contains(dir, "'") {
			return "", fmt.Errorf("directory contains quotes unsupported by cd here in %s; use a new tab", shell)
		}
		if strings.HasPrefix(dir, "-") {
			dir = "./" + dir
		}
		return "cd '" + dir + "'\n", nil
	}
	return "cd -- '" + strings.ReplaceAll(dir, "'", "'\\''") + "'\n", nil
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

func NextTarget(cfg config.Config, cur string, forward bool) string {
	list := cfg.Targets
	if len(list) == 0 {
		list = config.Default().Targets
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
