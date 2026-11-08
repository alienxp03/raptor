package rex

import (
	"encoding/json"
	"fmt"
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

// ClientLabel resolves the calling client's label on its own server. The label
// is the stable identity across hosts: the same app registers with the same
// label on every server it joins.
func ClientLabel(clientID string) string {
	var payload string
	if clientID != "" {
		payload = fmt.Sprintf(`{"client_id":%q}`, clientID)
	}
	out, err := Run("api", "call", "client.inspect", payload)
	if err != nil {
		return ""
	}
	var data struct {
		Client struct {
			ClientID string `json:"client_id"`
			Info     struct {
				Kind     string `json:"kind"`
				Platform string `json:"platform"`
				Label    string `json:"label"`
			} `json:"info"`
		} `json:"client"`
	}
	if json.Unmarshal([]byte(out), &data) != nil {
		return ""
	}
	if data.Client.ClientID != "" && clientID != "" && data.Client.ClientID != clientID {
		return ""
	}
	return strings.TrimSpace(data.Client.Info.Label)
}

// appClientOn finds the Mac app's client id on one host. Clients match by
// label, which rex guarantees unique per principal on each server.
func appClientOn(host, label string) string {
	if label == "" {
		return ""
	}
	out, err := RunOn(host, "api", "call", "client.list")
	if err != nil {
		return ""
	}
	var data struct {
		Clients []struct {
			ClientID string `json:"client_id"`
			Info     struct {
				Kind  string `json:"kind"`
				Label string `json:"label"`
			} `json:"info"`
		} `json:"clients"`
	}
	if json.Unmarshal([]byte(out), &data) != nil {
		return ""
	}
	for _, client := range data.Clients {
		if client.Info.Kind == "app" && strings.TrimSpace(client.Info.Label) == label {
			return client.ClientID
		}
	}
	return ""
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
