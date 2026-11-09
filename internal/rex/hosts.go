package rex

import (
	"encoding/json"
	"os"
	"strings"
	"sync"
)

// LocalHostLabel is the display name of the server this picker runs against.
const LocalHostLabel = "This Mac"

// Host is one selectable group header in the Sessions view. The local server
// is always first and unnamed in rex terms: its sessions need no -S flag.
type Host struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Local bool   `json:"local,omitempty"`
}

type hostsResult struct {
	Hosts []struct {
		ID    string `json:"id"`
		Label string `json:"label"`
	} `json:"hosts"`
}

// Hosts lists the local server plus every remote Rex server it knows. Failures
// keep the local entry: a sessions view without hosts still lists local work.
func Hosts() []Host {
	hosts := []Host{{Label: LocalHostLabel, Local: true}}
	out, err := Run("api", "call", "hosts.list")
	if err != nil {
		return hosts
	}
	var data hostsResult
	if json.Unmarshal([]byte(out), &data) != nil {
		return hosts
	}
	seen := map[string]bool{LocalHostLabel: true}
	for _, h := range data.Hosts {
		label := strings.TrimSpace(h.Label)
		if label == "" || seen[label] {
			continue
		}
		seen[label] = true
		hosts = append(hosts, Host{ID: h.ID, Label: label})
	}
	return hosts
}

// LocalHostLabelOr normalizes the empty host to the local display label.
func LocalHostLabelOr(host string) string {
	if host == "" || host == LocalHostLabel {
		return LocalHostLabel
	}
	return host
}

// ClientLabel returns a unique app label on the local server. A label is only
// a cross-host routing hint, not device identity. Refuse ambiguous origins.
func ClientLabel(clientID string) string {
	if !strings.HasPrefix(clientID, "client:") {
		clientID = resolveHostTarget("", "client", clientID)
	}
	if clientID == "" {
		return ""
	}
	clients := appClientsOn("")
	for _, client := range clients {
		if client.ClientID == clientID && client.ConnectionState != "lost" {
			label := strings.TrimSpace(client.Info.Label)
			if label != "" && uniqueAppClient(clients, label) == clientID {
				return label
			}
			return ""
		}
	}
	return ""
}

// appClientOn returns a full ID only for one app with this exact label on the
// target host. Never reuse a local client ID or choose the first duplicate.
func appClientOn(host, label string) string {
	label = strings.TrimSpace(label)
	if label == "" {
		return ""
	}
	return uniqueAppClient(appClientsOn(host), label)
}

type hostAppClient struct {
	ClientID        string `json:"client_id"`
	ConnectionState string `json:"connection_state"`
	Info            struct {
		Kind  string `json:"kind"`
		Label string `json:"label"`
	} `json:"info"`
}

func appClientsOn(host string) []hostAppClient {
	out, err := RunOn(host, "api", "call", "client.list", `{"kinds":["app"]}`)
	if err != nil {
		return nil
	}
	var data struct {
		Clients []hostAppClient `json:"clients"`
	}
	if json.Unmarshal([]byte(out), &data) != nil {
		return nil
	}
	return data.Clients
}

func uniqueAppClient(clients []hostAppClient, label string) string {
	var id string
	for _, client := range clients {
		if client.Info.Kind != "app" || strings.TrimSpace(client.Info.Label) != label {
			continue
		}
		// A lost duplicate may reconnect. It still makes this label unsafe.
		if id != "" || !strings.HasPrefix(client.ClientID, "client:") || client.ConnectionState == "lost" {
			return ""
		}
		id = client.ClientID
	}
	return id
}

// resolveHostTarget uses the named server's ambiguity rules, without inherited
// local session/client context. Unknown statuses and malformed replies fail shut.
func resolveHostTarget(host, kind, query string) string {
	payload, err := json.Marshal(map[string]any{"kinds": []string{kind}, "queries": []string{query}})
	if err != nil {
		return ""
	}
	out, err := RunOn(host, "api", "call", "target.resolve", string(payload))
	if err != nil {
		return ""
	}
	var data struct {
		Results []struct {
			Query  string `json:"query"`
			Status string `json:"status"`
			Target struct {
				Kind      string `json:"kind"`
				ClientID  string `json:"client_id"`
				SessionID string `json:"session_id"`
			} `json:"target"`
		} `json:"results"`
	}
	if json.Unmarshal([]byte(out), &data) != nil || len(data.Results) != 1 {
		return ""
	}
	result := data.Results[0]
	if result.Query != query || result.Status != "resolved" || result.Target.Kind != kind {
		return ""
	}
	if kind == "client" && strings.HasPrefix(result.Target.ClientID, "client:") {
		return result.Target.ClientID
	}
	if kind == "session" && strings.HasPrefix(result.Target.SessionID, "session:") {
		return result.Target.SessionID
	}
	return ""
}

var (
	localHostnameOnce sync.Once
	localHostnameName string
)

// LocalHostname resolves a display name, not server identity: Rex's Tailscale
// DNS label when available, else the OS hostname, else the generic
// label. Cached for the process lifetime — badges render it on every row.
func LocalHostname() string {
	localHostnameOnce.Do(func() {
		if out, err := RunOnBounded("", 2, "api", "call", "server.status"); err == nil {
			var data struct {
				Tailscale struct {
					DNSName string `json:"dns_name"`
				} `json:"tailscale"`
			}
			if json.Unmarshal([]byte(out), &data) == nil {
				if label := strings.SplitN(strings.TrimSpace(data.Tailscale.DNSName), ".", 2)[0]; label != "" {
					localHostnameName = label
				}
			}
		}
		if localHostnameName == "" {
			if name, err := os.Hostname(); err == nil {
				localHostnameName = strings.TrimSpace(name)
			}
		}
		if localHostnameName == "" {
			localHostnameName = LocalHostLabel
		}
	})
	return localHostnameName
}

// IsLocalHost reports whether a host label refers to the local server.
// Rows carry the display hostname; actions must treat it as local.
func IsLocalHost(host string) bool {
	if host == "" || host == LocalHostLabel {
		return true
	}
	return strings.EqualFold(host, LocalHostname())
}

// SameSession compares a local session ID with an origin reference. Non-exact
// references must resolve uniquely on the local server, never by suffix alone.
func SameSession(full, origin string) bool {
	return SameSessionOn("", full, origin)
}

// SameSessionOn resolves references only on host. Callers must supply IDs from
// that host; inherited local origin IDs must not be used for remote sessions.
func SameSessionOn(host, full, origin string) bool {
	if strings.TrimSpace(origin) == "" || full == "" {
		return false
	}
	if full == origin {
		return true
	}
	if strings.HasPrefix(origin, "session:") {
		return false
	}
	return full == resolveHostTarget(host, "session", origin)
}

// NormalizeHost collapses a local display name to the empty host so actions
// take the local code path.
func NormalizeHost(host string) string {
	if IsLocalHost(host) {
		return ""
	}
	return host
}

// hostWorkers bounds concurrent rex processes across host listing.
const hostWorkers = 4

// mapHosts runs one job per host in parallel and keeps Hosts() order.
func mapHosts(hosts []Host, job func(host Host)) {
	jobs := make(chan Host)
	var workers sync.WaitGroup
	for range min(hostWorkers, len(hosts)) {
		workers.Go(func() {
			for host := range jobs {
				job(host)
			}
		})
	}
	for _, host := range hosts {
		jobs <- host
	}
	close(jobs)
	workers.Wait()
}
