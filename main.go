package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
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
		fmt.Fprintf(os.Stderr, "usage: raptor [dirs|wt|direct|last] [flags] [-- extra flags per command]\n")
		fs.PrintDefaults()
	}
	_ = fs.Parse(os.Args[1:])

	if len(fs.Args()) == 0 {
		fs.Usage()
		os.Exit(2)
	}

	fixPath()
	cfg := loadConfig()

	switch fs.Args()[0] {
	case "dirs":
		ctx := ctxFrom(session, block, client, title)
		os.Exit(runDirs(ctx, cfg))
	case "wt":
		rest := flag.NewFlagSet("wt", flag.ExitOnError)
		repo := rest.String("repo", "", "repo path (default: origin block's cwd, else picker)")
		_ = rest.Parse(fs.Args()[1:])
		ctx := ctxFrom(session, block, client, title)
		os.Exit(runWorktrees(ctx, cfg, *repo))
	case "direct":
		// raptor -session X -block Y -client Z direct <target> <dir>
		args := fs.Args()[1:]
		if len(args) < 2 {
			fmt.Fprintln(os.Stderr, "usage: raptor direct <target> <dir>")
			os.Exit(2)
		}
		ctx := ctxFrom(session, block, client, title)
		if err := dispatch(args[0], args[1], ctx, cfg); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	case "last":
		ctx := ctxFrom(session, block, client, title)
		sid, err := lastSession()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		swapLast(ctx.Session)
		if ctx.Client != "" {
			_ = rexDo(ctx.Client, "session.select", "session_id="+sid)
		}
		fmt.Println(sid)
	case "version":
		fmt.Println(version)
	default:
		fs.Usage()
		os.Exit(2)
	}
}

// Ctx carries where the action was invoked from.
type Ctx struct {
	Session string
	Block   string
	Client  string
	Title   string
}

func ctxFrom(session, block, client, title string) Ctx {
	return Ctx{Session: session, Block: block, Client: client, Title: title}
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
