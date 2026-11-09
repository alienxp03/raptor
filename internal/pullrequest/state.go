package pullrequest

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

type setupState struct {
	Instance    string     `json:"instance,omitempty"`
	Config      string     `json:"config"`
	Path        string     `json:"path"`
	Source      string     `json:"source"`
	Branch      string     `json:"branch"`
	Base        string     `json:"base"`
	BasePath    string     `json:"base_path,omitempty"`
	URL         string     `json:"url"`
	New         bool       `json:"new"`
	Stage       int        `json:"stage"`
	Complete    bool       `json:"complete"`
	Failed      string     `json:"failed,omitempty"`
	Released    bool       `json:"released"`
	Opening     bool       `json:"opening"`
	RetryCreate bool       `json:"retry_create,omitempty"`
	Target      string     `json:"target,omitempty"`
	Result      OpenResult `json:"result"`
}

func stateFile(key, suffix string) (string, error) {
	root := os.Getenv("XDG_STATE_HOME")
	if root == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		root = filepath.Join(home, ".local", "state")
	}
	root = filepath.Join(root, "raptor", "pullrequest")
	if err := os.MkdirAll(root, 0700); err != nil {
		return "", err
	}
	// Normalize existing ancestors too, so a prospective path keeps its identity
	// after creation beneath a symlink (for example /tmp on macOS).
	if p, err := filepath.Abs(key); err == nil {
		key = prospectivePath(p)
	}
	sum := sha256.Sum256([]byte(key))
	return filepath.Join(root, hex.EncodeToString(sum[:])+suffix), nil
}

func prospectivePath(path string) string {
	if p, err := canonical(path); err == nil {
		return p
	}
	parent := filepath.Dir(path)
	if parent == path {
		return path
	}
	return filepath.Join(prospectivePath(parent), filepath.Base(path))
}

func lock(key string, wait bool) (func(), error) {
	path, err := stateFile(key, ".lock")
	if err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	flags := syscall.LOCK_EX
	if !wait {
		flags |= syscall.LOCK_NB
	}
	if err := syscall.Flock(int(file.Fd()), flags); err != nil {
		file.Close()
		return nil, fmt.Errorf("operation already running: %w", err)
	}
	return func() { _ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN); _ = file.Close() }, nil
}

func load(path string) (setupState, error) {
	var state setupState
	name, err := stateFile(path, ".json")
	if err != nil {
		return state, err
	}
	data, err := os.ReadFile(name)
	if os.IsNotExist(err) {
		return state, nil
	}
	if err != nil {
		return state, err
	}
	err = json.Unmarshal(data, &state)
	return state, err
}

func save(path string, state setupState) error {
	name, err := stateFile(path, ".json")
	if err != nil {
		return err
	}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(name), ".state-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err := os.Rename(file.Name(), name); err != nil {
		return err
	}
	// Persist the rename as well as the bytes (ownership and pre-mutation
	// journals must survive a crash before a subsequent command starts).
	dir, err := os.Open(filepath.Dir(name))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
