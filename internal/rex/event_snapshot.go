package rex

import "time"

// AgentEntriesOn reads native status records on the host that owns the paths.
// Remote paths must never be matched against local agents.
func AgentEntriesOn(host, originSession string) ([]AgentEntry, error) {
	if host == "" || host == LocalHostLabel {
		return AgentEntries(originSession)
	}
	out, err := RunOnBounded(host, 2, "do", "-e", agentsScript, "--json")
	if err != nil {
		return nil, err
	}
	return decodeAgentEntriesWithNames([]byte(out), "", time.Now(), false)
}
