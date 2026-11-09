package rex

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"
)

// SelectSession records both ends only after the client accepts the switch.
func SelectSession(ctx Ctx, sid string) error {
	if ctx.Client == "" {
		return fmt.Errorf("no client context")
	}
	return selectHistorySession(ctx, "", ctx.Client, sid)
}

func selectHistorySession(ctx Ctx, host, client, sid string) error {
	if _, err := RunOn(host, "-C", client, "do", "session.select", "session_id="+sid); err != nil {
		return err
	}
	if ctx.Session != sid {
		_ = RecordSessionUse("", ctx.Session)
	}
	_ = RecordSessionUse(host, sid)
	return nil
}

// SelectLast uses the same history as both pickers. Failed host queries and
// selections stop navigation; they must not turn an unavailable session into
// a deleted session or report a server-only focus as a successful app switch.
func SelectLast(ctx Ctx) (string, error) {
	if ctx.Client == "" || ctx.Session == "" {
		return "", fmt.Errorf("no client or session context")
	}
	doc, _, err := readRecency(recencyPath(), time.Now())
	if err != nil {
		return "", fmt.Errorf("could not read session history: %w", err)
	}
	// Old installations have a single local ID. Check it only after the shared
	// history, and never let a stale legacy ID block newer valid visits.
	if data, err := os.ReadFile(statePath()); err == nil {
		id := strings.TrimSpace(string(data))
		if id != "" {
			doc.Visits = append(doc.Visits, recencyVisit{SessionID: id})
		}
	}
	listings := map[string]map[string]bool{}
	for _, visit := range doc.Visits {
		if visit.SessionID == ctx.Session {
			continue
		}
		sessions, ok := listings[visit.Host]
		if !ok {
			sessions, err = historySessions(visit.Host)
			if err != nil {
				return "", err
			}
			listings[visit.Host] = sessions
		}
		if !sessions[visit.SessionID] {
			continue
		}
		client := ctx.Client
		if visit.Host != "" {
			client = appClientOn(visit.Host, ClientLabel(ctx.Client))
			if client == "" {
				return "", fmt.Errorf("cannot identify the requesting app on %s", visit.Host)
			}
		}
		if err := selectHistorySession(ctx, visit.Host, client, visit.SessionID); err != nil {
			return "", err
		}
		return visit.SessionID, nil
	}
	return "", fmt.Errorf("no previous live session recorded; switch sessions first")
}

func historySessions(host string) (map[string]bool, error) {
	out, err := RunOnBounded(host, remoteListTimeout, "ls", "--json")
	if err != nil {
		return nil, fmt.Errorf("could not check previous sessions on %s: %w", LocalHostLabelOr(host), err)
	}
	var data struct {
		Sessions []apiSession `json:"sessions"`
	}
	if err := json.Unmarshal([]byte(out), &data); err != nil || data.Sessions == nil {
		return nil, fmt.Errorf("could not parse previous sessions on %s", LocalHostLabelOr(host))
	}
	sessions := make(map[string]bool, len(data.Sessions))
	for _, session := range data.Sessions {
		sessions[session.SessionID] = true
	}
	return sessions, nil
}
