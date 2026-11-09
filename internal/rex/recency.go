package rex

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
	"unicode"

	"github.com/alienxp03/raptor/internal/paths"
)

const (
	recencyLimit       = 256
	recencyLockTimeout = 250 * time.Millisecond
	recencyLockRetry   = time.Millisecond
)

var recencyStartedAt = time.Now()

// SessionRecency is a detached rank snapshot. Treat it as immutable.
type SessionRecency map[string]int

func recencyKey(host, sessionID string) string { return host + "\x00" + sessionID }

func recencyTarget(host, sessionID string) (string, string, bool) {
	host, sessionID = strings.TrimSpace(host), strings.TrimSpace(sessionID)
	if host == LocalHostLabel {
		host = ""
	}
	valid := func(s string, allowSpaces bool) bool {
		return len(s) <= 4096 && !strings.ContainsFunc(s, func(r rune) bool {
			return unicode.IsControl(r) || (!allowSpaces && unicode.IsSpace(r))
		})
	}
	// Rex host labels can contain spaces; session IDs cannot.
	return host, sessionID, valid(host, true) && valid(sessionID, false) && strings.HasPrefix(sessionID, "session:") && len(sessionID) > len("session:")
}

// Rank returns zero for the newest visit and max int for unknown sessions.
func (r SessionRecency) Rank(host, sessionID string) int {
	host, sessionID, ok := recencyTarget(host, sessionID)
	if ok {
		if rank, found := r[recencyKey(host, sessionID)]; found {
			return rank
		}
	}
	return int(^uint(0) >> 1)
}

type recencyVisit struct {
	Host      string    `json:"host"`
	SessionID string    `json:"session_id"`
	At        time.Time `json:"at"`
}

type recencyDocument struct {
	Version int            `json:"version"`
	Visits  []recencyVisit `json:"visits"`
}

func recencyPath() string { return filepath.Join(paths.CacheDir(), "session-recency.json") }

// LoadSessionRecency reads history only. It never calls Rex or changes history.
func LoadSessionRecency() SessionRecency {
	doc, _, err := readRecency(recencyPath(), time.Now())
	ranks := SessionRecency{}
	if err != nil {
		return ranks
	}
	for i, visit := range doc.Visits {
		ranks[recencyKey(visit.Host, visit.SessionID)] = i
	}
	return ranks
}

func readRecency(path string, now time.Time) (recencyDocument, []byte, error) {
	doc := recencyDocument{Version: 1}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return doc, nil, nil
	}
	if err != nil {
		return doc, nil, err
	}
	doc = recencyDocument{}
	if err = json.Unmarshal(data, &doc); err != nil {
		return doc, data, err
	}
	if doc.Version != 1 {
		return doc, data, fmt.Errorf("unsupported session history version %d", doc.Version)
	}
	seen := map[string]bool{}
	for _, visit := range doc.Visits {
		host, id, ok := recencyTarget(visit.Host, visit.SessionID)
		key := recencyKey(host, id)
		if !ok || host != visit.Host || id != visit.SessionID || !validRecencyTime(visit.At, now) || seen[key] {
			return doc, data, errors.New("invalid session history visit")
		}
		seen[key] = true
	}
	sortRecency(&doc)
	return doc, data, nil
}

func validRecencyTime(at, now time.Time) bool { return at.After(time.Unix(0, 0)) && !at.After(now) }

func sortRecency(doc *recencyDocument) {
	sort.Slice(doc.Visits, func(i, j int) bool {
		a, b := doc.Visits[i], doc.Visits[j]
		if !a.At.Equal(b.At) {
			return a.At.After(b.At)
		}
		return recencyKey(a.Host, a.SessionID) < recencyKey(b.Host, b.SessionID)
	})
	if len(doc.Visits) > recencyLimit {
		doc.Visits = doc.Visits[:recencyLimit]
	}
}

// RecordSessionVisit merges a validated focus observation. Times must describe
// when focus was read, not when a queued observation was delivered. An initial
// read cannot replace same-host visits recorded during this process's lifetime.
// Older observations retain their chronological position; they cannot promote
// a session above a newer visit or replace its newer timestamp.
// Lock contention returns an error after a short wait; history is optional.
func RecordSessionVisit(host, sessionID string, observedAt time.Time, initial bool) error {
	return recordSessionVisit(host, sessionID, observedAt, initial, time.Now(), recencyStartedAt)
}

// RecordSessionUse records an acknowledged selection, without additional Rex calls.
func RecordSessionUse(host, sessionID string) error {
	now := time.Now()
	return recordSessionVisit(host, sessionID, now, false, now, recencyStartedAt)
}

func recordSessionVisit(host, sessionID string, at time.Time, initial bool, now, startedAt time.Time) error {
	host, sessionID, ok := recencyTarget(host, sessionID)
	// Short fixture IDs must never enter the user's real history.
	if !ok || !validRecencyTime(at, now) {
		return nil
	}
	path := recencyPath()
	lock, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err = lockRecency(lock); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	// Other writers may have committed after this call captured its timestamp.
	// Validate disk timestamps against the clock after acquiring the lock.
	readNow := time.Now()
	if now.After(readNow) {
		readNow = now
	}
	doc, damaged, err := readRecency(path, readNow)
	if err != nil {
		if damaged == nil {
			return err
		}
		// Preserve the exact original, including unsupported future documents.
		if err = saveRecencyFile(path+".backup-", damaged, false); err != nil {
			return err
		}
		doc = recencyDocument{Version: 1}
	}
	for _, visit := range doc.Visits {
		if visit.Host != host {
			continue
		}
		if (visit.SessionID == sessionID && !at.After(visit.At)) || (initial && !visit.At.Before(startedAt)) {
			return nil
		}
	}
	visits := doc.Visits[:0]
	for _, visit := range doc.Visits {
		if visit.Host != host || visit.SessionID != sessionID {
			visits = append(visits, visit)
		}
	}
	doc.Visits = append(visits, recencyVisit{Host: host, SessionID: sessionID, At: at.UTC()})
	sortRecency(&doc)
	data, err := json.Marshal(doc)
	if err != nil {
		return err
	}
	return saveRecencyFile(path, data, true)
}

// Keep the same lock inode across writers, including after a timeout. The lock
// covers the complete read/merge/rename so concurrent updates remain atomic.
func lockRecency(lock *os.File) error {
	deadline := time.Now().Add(recencyLockTimeout)
	for {
		err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return nil
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EINTR) {
			return err
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return fmt.Errorf("session history lock timeout: %w", err)
		}
		time.Sleep(min(recencyLockRetry, remaining))
	}
}

func saveRecencyFile(path string, data []byte, replace bool) error {
	pattern := filepath.Base(path)
	if replace {
		pattern += ".tmp-"
	}
	file, err := os.CreateTemp(filepath.Dir(path), pattern)
	if err != nil {
		return err
	}
	name := file.Name()
	keep := false
	defer func() {
		file.Close()
		if !keep {
			_ = os.Remove(name)
		}
	}()
	if _, err = file.Write(data); err != nil {
		return err
	}
	if err = file.Sync(); err != nil {
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	if replace {
		return os.Rename(name, path)
	}
	keep = true
	return nil
}

func recordSelectedSession(host, action string, kv []string) {
	if action != "session.select" {
		return
	}
	var id string
	for _, arg := range kv {
		if value, ok := strings.CutPrefix(arg, "session_id="); ok {
			id = value
		}
	}
	if id != "" {
		_ = RecordSessionUse(host, id)
	}
}

// ValidateFocusClientPID accepts only a connected local Unix app peer with the
// exact PID. Call it from a background focus worker, never a ranking query.
func ValidateFocusClientPID(pid int) bool {
	return ValidateFocusClientPIDContext(context.Background(), pid)
}

// ValidateFocusClientPIDContext lets the observer owner cancel native I/O at
// shutdown. Validation must never start a missing Rex server.
func ValidateFocusClientPIDContext(parent context.Context, pid int) bool {
	if pid <= 0 {
		return false
	}
	ctx, cancel := context.WithTimeout(parent, 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "rex", "--autostart=false", "api", "call", "client.list", `{"kinds":["app"]}`)
	cmd.WaitDelay = 100 * time.Millisecond
	out, err := cmd.Output()
	if err != nil {
		return false
	}
	var data struct {
		Clients []struct {
			ConnectionState string `json:"connection_state"`
			Info            struct {
				Kind string `json:"kind"`
			} `json:"info"`
			Principal struct {
				Kind      string `json:"kind"`
				Transport string `json:"transport"`
				PID       int    `json:"pid"`
			} `json:"principal"`
		} `json:"clients"`
	}
	if json.Unmarshal(out, &data) != nil {
		return false
	}
	for _, client := range data.Clients {
		if client.Info.Kind == "app" && client.ConnectionState != "lost" && client.Principal.Kind == "peer" && client.Principal.Transport == "unix" && client.Principal.PID == pid {
			return true
		}
	}
	return false
}
