package rex

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func fakeHostDiscovery(t *testing.T) string {
	t.Helper()
	log := filepath.Join(t.TempDir(), "calls")
	t.Setenv("HOST_DISCOVERY_LOG", log)
	t.Setenv("HOST_DISCOVERY_CLIENTS", `{"clients":[]}`)
	t.Setenv("HOST_DISCOVERY_TARGET", `{"results":[]}`)
	t.Setenv("HOST_DISCOVERY_STATUS", `{}`)
	fakeRexWithHosts(t, `#!/bin/sh
printf '%s\n' "$*" >> "$HOST_DISCOVERY_LOG"
if [ "$1" = '-S' ]; then
  [ "$2" = 'remote' ] || exit 1
  shift 2
fi
case "$*" in
  'api call client.list {"kinds":["app"]}') printf '%s\n' "$HOST_DISCOVERY_CLIENTS" ;;
  'api call target.resolve '*) printf '%s\n' "$HOST_DISCOVERY_TARGET" ;;
  'api call server.status') printf '%s\n' "$HOST_DISCOVERY_STATUS" ;;
  *) exit 1 ;;
esac
`)
	return log
}

func discoveryCalls(t *testing.T, log string) string {
	t.Helper()
	data, err := os.ReadFile(log)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return string(data)
}

func TestAppClientOnRequiresUniqueAppLabel(t *testing.T) {
	for _, tt := range []struct {
		name, label, clients, want string
	}{
		{"unique among unrelated", "studio", `{"clients":[{"client_id":"client:other","info":{"kind":"app","label":"other"}},{"client_id":"client:cli","info":{"kind":"cli","label":"studio"}},{"client_id":"client:remote","info":{"kind":"app","label":"studio"}}]}`, "client:remote"},
		{"duplicate", "studio", `{"clients":[{"client_id":"client:one","info":{"kind":"app","label":"studio"}},{"client_id":"client:two","info":{"kind":"app","label":"studio"}}]}`, ""},
		{"lost duplicate", "studio", `{"clients":[{"client_id":"client:one","info":{"kind":"app","label":"studio"}},{"client_id":"client:two","connection_state":"lost","info":{"kind":"app","label":"studio"}}]}`, ""},
		{"unrelated only", "studio", `{"clients":[{"client_id":"client:other","info":{"kind":"app","label":"other"}}]}`, ""},
		{"no label fallback", "", `{"clients":[{"client_id":"client:other","info":{"kind":"app","label":"other"}}]}`, ""},
		{"missing id", "studio", `{"clients":[{"info":{"kind":"app","label":"studio"}}]}`, ""},
		{"malformed", "studio", `{`, ""},
	} {
		t.Run(tt.name, func(t *testing.T) {
			log := fakeHostDiscovery(t)
			t.Setenv("HOST_DISCOVERY_CLIENTS", tt.clients)
			if got := appClientOn("remote", tt.label); got != tt.want {
				t.Fatalf("appClientOn = %q, want %q", got, tt.want)
			}
			calls := discoveryCalls(t, log)
			if tt.label == "" {
				if calls != "" {
					t.Fatalf("empty label performed discovery: %s", calls)
				}
			} else if calls != "-S remote api call client.list {\"kinds\":[\"app\"]}\n" {
				t.Fatalf("remote discovery = %s", calls)
			}
		})
	}
}

func TestClientLabelChecksOriginAndLocalUniqueness(t *testing.T) {
	const unique = `{"clients":[{"client_id":"client:origin","info":{"kind":"app","label":"studio"}},{"client_id":"client:other","info":{"kind":"app","label":"other"}}]}`
	for _, tt := range []struct {
		name, ref, resolution, clients, want string
	}{
		{"full id", "client:origin", ``, unique, "studio"},
		{"unknown origin", "client:absent", ``, unique, ""},
		{"suffix", "abcd", `{"results":[{"query":"abcd","status":"resolved","target":{"kind":"client","client_id":"client:origin"}}]}`, unique, "studio"},
		{"ambiguous origin", "studio", `{"results":[{"query":"studio","status":"ambiguous"}]}`, unique, ""},
		{"multiple apps no origin", "", `{"results":[{"query":"","status":"ambiguous"}]}`, unique, ""},
		{"unique default", "", `{"results":[{"query":"","status":"resolved","target":{"kind":"client","client_id":"client:origin"}}]}`, `{"clients":[{"client_id":"client:origin","info":{"kind":"app","label":"studio"}}]}`, "studio"},
		{"duplicate origin label", "client:origin", ``, `{"clients":[{"client_id":"client:origin","info":{"kind":"app","label":"studio"}},{"client_id":"client:other","info":{"kind":"app","label":"studio"}}]}`, ""},
		{"cli origin", "client:origin", ``, `{"clients":[{"client_id":"client:origin","info":{"kind":"cli","label":"studio"}}]}`, ""},
		{"lost origin", "client:origin", ``, `{"clients":[{"client_id":"client:origin","connection_state":"lost","info":{"kind":"app","label":"studio"}}]}`, ""},
	} {
		t.Run(tt.name, func(t *testing.T) {
			log := fakeHostDiscovery(t)
			t.Setenv("HOST_DISCOVERY_CLIENTS", tt.clients)
			t.Setenv("HOST_DISCOVERY_TARGET", tt.resolution)
			if got := ClientLabel(tt.ref); got != tt.want {
				t.Fatalf("ClientLabel(%q) = %q, want %q", tt.ref, got, tt.want)
			}
			calls := discoveryCalls(t, log)
			if strings.Contains(calls, "-S ") || strings.Contains(calls, "client.inspect") {
				t.Fatalf("unexpected origin discovery: %s", calls)
			}
			if strings.HasPrefix(tt.ref, "client:") && strings.Contains(calls, "target.resolve") {
				t.Fatalf("full origin ID required resolution: %s", calls)
			}
		})
	}
}

func TestSameSessionUsesNativeAmbiguityRules(t *testing.T) {
	for _, tt := range []struct {
		name, full, ref, result string
		want                    bool
	}{
		{"exact", "session:1234abcd", "session:1234abcd", "", true},
		{"different full", "session:1234abcd", "session:5678abcd", "", false},
		{"empty origin", "session:1234abcd", "", "", false},
		{"blank origin", "session:1234abcd", "  ", "", false},
		{"empty full", "", "abcd", "", false},
		{"unique suffix", "session:1234abcd", "abcd", `{"results":[{"query":"abcd","status":"resolved","target":{"kind":"session","session_id":"session:1234abcd"}}]}`, true},
		{"ambiguous suffix", "session:1234abcd", "abcd", `{"results":[{"query":"abcd","status":"ambiguous","candidates":[{"kind":"session","session_id":"session:1234abcd"},{"kind":"session","session_id":"session:5678abcd"}]}]}`, false},
		{"label wins over suffix", "session:1234abcd", "abcd", `{"results":[{"query":"abcd","status":"resolved","target":{"kind":"session","session_id":"session:other"}}]}`, false},
		{"not found", "session:1234abcd", "abcd", `{"results":[{"query":"abcd","status":"not_found"}]}`, false},
		{"unknown status", "session:1234abcd", "abcd", `{"results":[{"query":"abcd","status":"new","target":{"kind":"session","session_id":"session:1234abcd"}}]}`, false},
		{"wrong kind", "session:1234abcd", "abcd", `{"results":[{"query":"abcd","status":"resolved","target":{"kind":"block","session_id":"session:1234abcd"}}]}`, false},
		{"wrong query", "session:1234abcd", "abcd", `{"results":[{"query":"other","status":"resolved","target":{"kind":"session","session_id":"session:1234abcd"}}]}`, false},
		{"malformed", "session:1234abcd", "abcd", `{`, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			log := fakeHostDiscovery(t)
			t.Setenv("HOST_DISCOVERY_TARGET", tt.result)
			if got := SameSession(tt.full, tt.ref); got != tt.want {
				t.Fatalf("SameSession(%q, %q) = %v", tt.full, tt.ref, got)
			}
			calls := discoveryCalls(t, log)
			if tt.result == "" && calls != "" {
				t.Fatalf("exact/empty references performed RPC: %s", calls)
			}
			if tt.result != "" && calls != "api call target.resolve {\"kinds\":[\"session\"],\"queries\":[\"abcd\"]}\n" {
				t.Fatalf("unexpected resolution: %s", calls)
			}
		})
	}
}

func TestSameSessionOnResolvesOnlyOnRemote(t *testing.T) {
	log := fakeHostDiscovery(t)
	t.Setenv("HOST_DISCOVERY_TARGET", `{"results":[{"query":"abcd","status":"resolved","target":{"kind":"session","session_id":"session:remoteabcd"}}]}`)
	if !SameSessionOn("remote", "session:remoteabcd", "abcd") {
		t.Fatal("remote session did not resolve")
	}
	if got := discoveryCalls(t, log); got != "-S remote api call target.resolve {\"kinds\":[\"session\"],\"queries\":[\"abcd\"]}\n" {
		t.Fatalf("unexpected remote resolution: %s", got)
	}
}

func TestHostDiscoveryFailsClosedWhenRexFails(t *testing.T) {
	fakeRexWithHosts(t, "#!/bin/sh\nexit 1\n")
	if SameSession("session:1234abcd", "abcd") || ClientLabel("abcd") != "" || appClientOn("remote", "studio") != "" {
		t.Fatal("failed discovery must not guess a target")
	}
}

func TestLocalHostnameUsesSupportedDisplaySources(t *testing.T) {
	for _, tt := range []struct {
		name, status, want string
	}{
		{"tailscale", `{"hostname":"unsupported","tailscale":{"dns_name":"studio.tail123.ts.net."}}`, "studio"},
		{"os fallback", `{"hostname":"unsupported"}`, ""},
		{"malformed fallback", `{`, ""},
	} {
		t.Run(tt.name, func(t *testing.T) {
			log := fakeHostDiscovery(t)
			t.Setenv("HOST_DISCOVERY_STATUS", tt.status)
			localHostnameOnce = sync.Once{}
			localHostnameName = ""
			t.Cleanup(func() {
				localHostnameOnce = sync.Once{}
				localHostnameName = ""
			})
			want := tt.want
			if want == "" {
				name, err := os.Hostname()
				want = strings.TrimSpace(name)
				if err != nil || want == "" {
					want = LocalHostLabel
				}
			}
			if got := LocalHostname(); got != want {
				t.Fatalf("LocalHostname = %q, want %q", got, want)
			}
			_ = LocalHostname()
			if calls := discoveryCalls(t, log); calls != "api call server.status\n" {
				t.Fatalf("unsupported or repeated hostname discovery: %s", calls)
			}
		})
	}
}
