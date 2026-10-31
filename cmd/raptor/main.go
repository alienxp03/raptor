package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/alienxp03/raptor/internal/api"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/dispatch"
	"github.com/alienxp03/raptor/internal/picker"
	"github.com/alienxp03/raptor/internal/rex"
	"github.com/alienxp03/raptor/internal/task"
)

// version is set at build time.
var version = "0.0.1"

func main() {
	// Rex passes context as flags on every subcommand.
	var session, block, client, title string
	fs := flag.NewFlagSet("raptor", flag.ExitOnError)
	fs.StringVar(&session, "session", os.Getenv("REX_SESSION"), "origin session id")
	fs.StringVar(&block, "block", os.Getenv("REX_BLOCK"), "origin block id")
	fs.StringVar(&client, "client", "", "origin client id")
	fs.StringVar(&title, "title", "", "origin terminal title")
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "usage: raptor [context flags] <dirs|launcher|wt|task|api|direct|last-session|last-pane> [command flags]\n")
		fs.PrintDefaults()
	}
	_ = fs.Parse(os.Args[1:])

	if len(fs.Args()) == 0 {
		fs.Usage()
		os.Exit(2)
	}

	fixPath()
	cfg := config.Load()
	ctx := rex.NewContext(session, block, client, title)

	switch fs.Args()[0] {
	case "api":
		if err := api.New(ctx, cfg).Serve(os.Stdin, os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	case "dirs":
		picker.ApplyTheme()
		os.Exit(picker.RunDirs(ctx, cfg))
	case "launcher":
		picker.ApplyTheme()
		os.Exit(picker.RunLauncher(ctx, cfg))
	case "wt":
		rest := flag.NewFlagSet("wt", flag.ExitOnError)
		repo := rest.String("repo", "", "repo path (default: origin block's cwd, else picker)")
		create := rest.Bool("create", false, "open the create-worktree form directly")
		_ = rest.Parse(fs.Args()[1:])
		if *create {
			picker.ApplyTheme()
			os.Exit(picker.RunCreateWorktree(ctx, cfg, *repo))
		}
		picker.ApplyTheme()
		os.Exit(picker.RunWorktrees(ctx, cfg, *repo))
	case "task":
		rest := flag.NewFlagSet("task", flag.ExitOnError)
		repo := rest.String("repo", "", "origin repository (default: current pane)")
		resume := rest.String("resume", "", "reuse an existing worktree after a tab-open failure")
		_ = rest.Parse(fs.Args()[1:])
		result, err := task.Start(ctx, cfg, *repo, *resume)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		_ = json.NewEncoder(os.Stdout).Encode(result)
	case "direct":
		// raptor -session X -block Y -client Z direct <target> <dir>
		args := fs.Args()[1:]
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "usage: raptor direct <target> <dir>")
			os.Exit(2)
		}
		if err := dispatch.Dispatch(args[0], args[1], ctx, cfg); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	case "last", "last-session":
		sid, err := rex.SelectLast(ctx)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println(sid)
	case "last-pane":
		pane, err := rex.SelectLastPane(ctx)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println(pane.Block)
	case "version":
		fmt.Println(version)
	default:
		fs.Usage()
		os.Exit(2)
	}
}

// fixPath makes rex, gh, git, eza findable when launched from the Rex
// server, whose PATH is minimal.
func fixPath() {
	home, _ := os.UserHomeDir()
	extra := []string{
		filepath.Join(home, ".local/share/mise/shims"),
		"/opt/homebrew/bin",
		"/usr/local/bin",
		"/usr/bin",
		"/bin",
		filepath.Join(home, "Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS"),
	}
	cur := os.Getenv("PATH")
	for _, p := range extra {
		if !strings.Contains(cur, p) {
			cur = p + ":" + cur
		}
	}
	_ = os.Setenv("PATH", cur)
}
