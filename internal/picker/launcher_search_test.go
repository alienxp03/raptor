package picker

import (
	"path/filepath"
	"testing"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/paths"
)

func TestLauncherSearchPrefersExactFolderNames(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	var dirs []catalog.Directory
	for _, relative := range []string{"workspace/projects/VoiceInk", "workspace/webmono/projects/frontier/ios/App", ".pi", ".dotfiles/pi", "workspace/piza", ".pi/agent"} {
		p := filepath.Join(home, relative)
		dirs = append(dirs, catalog.Directory{Path: p, Label: paths.HomeRelative(p)})
	}
	m := &dirModel{}
	for i := range dirs {
		m.launcher = append(m.launcher, launcherRow{dir: &dirs[i], host: "Mac", local: true})
	}
	for _, query := range []string{"pi", "PI", ".pi"} {
		m.filter = query
		m.filterLauncher()
		if len(m.launcherView) == 0 || m.launcher[m.launcherView[0].index].dir.Path != filepath.Join(home, ".pi") {
			t.Fatalf("query %q: exact hidden folder did not lead", query)
		}
		if query != ".pi" && m.launcher[m.launcherView[1].index].dir.Path != filepath.Join(home, ".dotfiles/pi") {
			t.Fatalf("query %q: exact folder basename did not precede fuzzy paths", query)
		}
	}
	m.filter = ""
	m.filterLauncher()
	for i, match := range m.launcherView {
		if match.index != i {
			t.Fatal("clearing search must restore cached order")
		}
	}
}
