package catalog

import (
	"path"
	"sort"
	"strings"

	"github.com/alienxp03/raptor/internal/paths"
	"github.com/sahilm/fuzzy"
)

// LauncherMatchName uses the final directory component, not its parent path.
// Session rows pass an empty directory and use their visible label instead.
func LauncherMatchName(label, directory string) string {
	if directory == "" {
		return label
	}
	return path.Base(strings.TrimRight(directory, "/"))
}

// RankLauncherMatches ranks exact names first, then fuzzy quality. A leading
// dot does not prevent an exact hidden-folder match. Equal scores retain the
// input order, including the presentation's fixed session recency order.
func RankLauncherMatches(query string, texts, names []string) []fuzzy.Match {
	matches := fuzzy.FindFromNoSort(query, launcherTexts(texts))
	exact := func(match fuzzy.Match) bool {
		name := names[match.Index]
		return strings.EqualFold(name, query) || strings.EqualFold(strings.TrimPrefix(name, "."), query)
	}
	score := func(match fuzzy.Match) int {
		// Keep the existing capped length penalty for non-exact matches.
		penalty := len(match.MatchedIndexes) - len(match.Str)
		return match.Score - penalty + max(penalty, -5)
	}
	sort.SliceStable(matches, func(i, j int) bool {
		if a, b := exact(matches[i]), exact(matches[j]); a != b {
			return a
		}
		return score(matches[i]) > score(matches[j])
	})
	return matches
}

func rankLauncherItems(items []LauncherItem, query string) []fuzzy.Match {
	texts, names := make([]string, len(items)), make([]string, len(items))
	for i, item := range items {
		directory := item.Path
		if item.Kind == "session" {
			directory = ""
		}
		texts[i] = item.Label + " " + paths.HomeRelative(directory) + " " + item.Host
		names[i] = LauncherMatchName(item.Label, directory)
	}
	return RankLauncherMatches(query, texts, names)
}
