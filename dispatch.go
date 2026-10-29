package main

import (
	"encoding/json"
	"fmt"
	"strings"
)

// dispatch opens dir with the given target, mirroring the old shell script.
func dispatch(target, dir string, ctx Ctx, cfg Config) error {
	switch target {
	case "session":
		name := basename(dir)
		sid, ok := sessionByLabel(name)
		if !ok {
			out, err := rexRun("new", "--json", "-c", dir, name)
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
			writeLast(ctx.Session)
		}
		if ctx.Client != "" {
			_ = rexDo(ctx.Client, "session.select", "session_id="+sid)
		}
		return nil

	case "tab":
		if ctx.Session == "" {
			return fmt.Errorf("no session context")
		}
		out, err := rexRun("window", "new", "-s", ctx.Session, basename(dir), "-c", dir, "--json")
		if err != nil {
			return err
		}
		var res struct {
			WindowID string `json:"window_id"`
		}
		_ = json.Unmarshal([]byte(out), &res)
		if res.WindowID != "" {
			if ctx.Client != "" {
				_ = rexDo(ctx.Client, "session.select", "session_id="+ctx.Session, "window_id="+res.WindowID)
			} else {
				rexRunQuiet("focus", "-s", ctx.Session, res.WindowID)
			}
		}
		return nil

	case "pane", "pane_below":
		if ctx.Block == "" {
			return fmt.Errorf("no block context")
		}
		dirFlag := "--split=right"
		if target == "pane_below" {
			dirFlag = "--split=below"
		}
		out, err := rexRun("split", "-s", ctx.Session, "-b", ctx.Block, dirFlag, "-c", dir, "--json")
		if err != nil {
			return err
		}
		var res struct {
			BlockIDs []string `json:"block_ids"`
		}
		_ = json.Unmarshal([]byte(out), &res)
		if len(res.BlockIDs) > 0 {
			rexRunQuiet("focus", "-s", ctx.Session, "-b", res.BlockIDs[0])
		}
		return nil

	case "here":
		if ctx.Block == "" {
			return fmt.Errorf("no block context")
		}
		switch blockForeground(ctx.Block) {
		case "zsh", "bash", "sh", "dash", "ksh", "fish", "nu", "elvish":
			// text + newline so the shell runs it
			_, _ = rexRun("send", "-b", ctx.Block, "cd '"+dir+"'\n")
			return nil
		default:
			return fmt.Errorf("pane is not at a shell prompt")
		}

	default:
		return fmt.Errorf("unknown target %q", target)
	}
}

// targetLabel renders a target for the status bar.
func targetLabel(t string) string {
	switch t {
	case "session":
		return "session"
	case "tab":
		return "tab"
	case "pane":
		return "pane →"
	case "pane_below":
		return "pane ↓"
	case "here":
		return "cd here"
	default:
		return t
	}
}

var targetOrderHint = []string{"session", "tab", "pane", "pane_below", "here"}

// nextTarget cycles within cfg.Targets.
func nextTarget(cfg Config, cur string, forward bool) string {
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

// headerTargets renders the open-as bar with the current target highlighted.
func headerTargets(cfg Config, cur string) string {
	var parts []string
	for _, t := range cfg.Targets {
		lbl := targetLabel(t)
		if t == cur {
			lbl = "[" + lbl + "]"
		}
		parts = append(parts, lbl)
	}
	return strings.Join(parts, " ")
}
