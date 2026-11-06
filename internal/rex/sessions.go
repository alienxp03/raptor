package rex

import (
	"encoding/json"
	"fmt"
	"time"
)

// SessionEntry describes one jump target for the Tabs & Sessions view.
// Kind "session" jumps to a session; kind "window" jumps to one of its tabs.
// Path mirrors ID so native clients can reuse their item decode shape.
type SessionEntry struct {
	Kind         string `json:"kind"` // "session" | "window"
	ID           string `json:"id"`
	Path         string `json:"path"`
	SessionID    string `json:"session_id"`
	Label        string `json:"label"`
	SessionLabel string `json:"session_label"`
	Active       bool   `json:"active"`
}

type apiSession struct {
	SessionID string `json:"session_id"`
	Label     string `json:"label"`
}

type apiWindow struct {
	WindowID string `json:"window_id"`
	Label    string `json:"label"`
	Active   bool
}

// SessionEntries lists sessions and their windows in sidebar order: each
// session is followed by its tabs. A window is active when it is the
// session's active window; a session is active when it is the origin session.
func SessionEntries(originSession string) ([]SessionEntry, error) {
	out, err := Run("ls", "--json")
	if err != nil {
		return nil, err
	}
	var data struct {
		Sessions []apiSession `json:"sessions"`
	}
	if err := json.Unmarshal([]byte(out), &data); err != nil {
		return nil, fmt.Errorf("could not parse the session list: %w", err)
	}
	entries := make([]SessionEntry, 0, len(data.Sessions)*2)
	for _, session := range data.Sessions {
		entries = append(entries, SessionEntry{
			Kind: "session", ID: session.SessionID, Path: session.SessionID, SessionID: session.SessionID,
			Label: session.Label, SessionLabel: session.Label,
			Active: session.SessionID == originSession,
		})
		windows, err := sessionWindows(session.SessionID)
		if err != nil {
			continue // A dead session must not hide the others.
		}
		for _, window := range windows {
			entries = append(entries, SessionEntry{
				Kind: "window", ID: window.WindowID, Path: window.WindowID, SessionID: session.SessionID,
				Label: window.Label, SessionLabel: session.Label, Active: window.Active,
			})
		}
	}
	return entries, nil
}

type sessionView struct {
	ActiveWindowID string      `json:"active_window_id"`
	Windows        []apiWindow `json:"windows"`
}

func sessionWindows(sessionID string) ([]apiWindow, error) {
	out, err := apiCall(sessionID, "session.view", map[string]string{"session_id": sessionID})
	if err != nil {
		return nil, err
	}
	var view sessionView
	if json.Unmarshal([]byte(out), &view) != nil {
		return nil, fmt.Errorf("could not parse the window list for %s", sessionID)
	}
	windows := make([]apiWindow, 0, len(view.Windows))
	for _, window := range view.Windows {
		windows = append(windows, apiWindow{WindowID: window.WindowID, Label: window.Label, Active: window.WindowID == view.ActiveWindowID})
	}
	return windows, nil
}

func apiCall(sessionID, method string, params any) (string, error) {
	args := []string{"api", "call"}
	if sessionID != "" {
		args = append(args, "-s", sessionID)
	}
	payload, err := json.Marshal(params)
	if err != nil {
		return "", err
	}
	args = append(args, method, string(payload))
	out, err := Run(args...)
	if err != nil {
		return "", err
	}
	return out, nil
}

// Jump activates a session or window for the requesting client, falling back
// to server-side focus when no client context exists.
func Jump(entry SessionEntry, client string) error {
	if client != "" {
		kv := []string{"session_id=" + entry.SessionID}
		if entry.Kind == "window" {
			kv = append(kv, "window_id="+entry.ID)
		}
		return Do(client, "session.select", kv...)
	}
	if entry.Kind == "window" {
		return FocusWindow(entry.SessionID, entry.ID)
	}
	windows, err := sessionWindows(entry.SessionID)
	if err != nil || len(windows) == 0 {
		return fmt.Errorf("session %s has no windows", entry.SessionLabel)
	}
	active := windows[0].WindowID
	for _, window := range windows {
		if window.Active {
			active = window.WindowID
			break
		}
	}
	return FocusWindow(entry.SessionID, active)
}

func FocusWindow(sessionID, windowID string) error {
	_, err := apiCall("", "session.focus_window", map[string]string{"session_id": sessionID, "window_id": windowID})
	return err
}

// CloseWindow closes one window; CloseSession destroys the whole session.
func CloseWindow(sessionID, windowID string) error {
	_, err := apiCall("", "session.close_window", map[string]string{"session_id": sessionID, "window_id": windowID})
	return err
}

func CloseSession(sessionID string) error {
	_, err := apiCall("", "session.destroy", map[string]string{"session_id": sessionID})
	return err
}

func SetWindowLabel(sessionID, windowID, label string) error {
	_, err := apiCall("", "session.set_window_label", map[string]string{"session_id": sessionID, "window_id": windowID, "label": label})
	return err
}

func SetSessionLabel(sessionID, label string) error {
	_, err := apiCall("", "session.set_label", map[string]string{"session_id": sessionID, "label": label})
	return err
}

// apiTimeout documents the shared rex call budget for session mutations.
const apiTimeout = 15 * time.Second
