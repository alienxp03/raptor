// Package launcherupdate is a small cross-process creation journal, not a session
// database. Only authoritative successful creations belong here.
package launcherupdate

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/alienxp03/raptor/internal/paths"
)

// TTL bounds recovery when a session is removed/renamed outside Raptor and no
// successful post-creation discovery has yet reached a warm reader.
const TTL = 2 * time.Minute

type Session struct {
	ID      string    `json:"id"`
	Label   string    `json:"label"`
	Host    string    `json:"host"`
	Path    string    `json:"path"`
	Local   bool      `json:"local"`
	Created time.Time `json:"created"`
}

func directory() string { return filepath.Join(paths.CacheDir(), "launcher-creations") }

// Record is best effort, like the launcher cache. Atomic per-identity files
// avoid lost updates between CLI processes without holding locks over Rex calls.
func Record(s Session) {
	if s.ID == "" || s.Label == "" {
		return
	}
	s.Created = time.Now()
	data, err := json.Marshal(s)
	if err != nil {
		return
	}
	dir := directory()
	if os.MkdirAll(dir, 0o755) != nil {
		return
	}
	f, err := os.CreateTemp(dir, ".creation-*")
	if err != nil {
		return
	}
	defer os.Remove(f.Name())
	_, err = f.Write(data)
	closeErr := f.Close()
	if err != nil || closeErr != nil {
		return
	}
	key := sha256.Sum256([]byte(s.Host + "\x00" + s.ID))
	_ = os.Rename(f.Name(), filepath.Join(dir, hex.EncodeToString(key[:])+".json"))
}

// Since returns creations not covered by a snapshot whose scan STARTED at at.
// A later completed scan is authoritative even if a created ID is absent.
func Since(at time.Time) []Session {
	entries, _ := os.ReadDir(directory())
	var result []Session
	now := time.Now()
	for _, entry := range entries {
		if filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		path := filepath.Join(directory(), entry.Name())
		data, err := os.ReadFile(path)
		var s Session
		if err != nil || json.Unmarshal(data, &s) != nil {
			continue
		}
		if now.Sub(s.Created) > TTL {
			continue
		}
		if s.ID != "" && s.Created.After(at) {
			result = append(result, s)
		}
	}
	return result
}
