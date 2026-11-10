import Foundation
import RaptorLauncherupdate

public extension Rex {
    /// RecordLauncherCreation publishes only an actual returned session identity.
    static func recordLauncherCreation(_ host: String, _ id: String, _ label: String, _ path: String) {
        var host = normalizeHost(host)
        let local = host.isEmpty || host == localHostLabel
        if local {
            host = localHostname()
        }
        Launcherupdate.record(Session(id: id, label: label, host: host, local: local, path: path))
    }
}
