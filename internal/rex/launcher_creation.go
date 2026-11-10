package rex

import "github.com/alienxp03/raptor/internal/launcherupdate"

// RecordLauncherCreation publishes only an actual returned session identity.
func RecordLauncherCreation(host, id, label, path string) {
	host = NormalizeHost(host)
	local := host == "" || host == LocalHostLabel
	if local {
		host = LocalHostname()
	}
	launcherupdate.Record(launcherupdate.Session{ID: id, Label: label, Host: host, Local: local, Path: path})
}
