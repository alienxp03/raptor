// Package panel is the client side of the resident host IPC. One short-lived
// connection per open: write a request, read a reply, close. The host lives in
// the Raptor app (serve mode) and keeps the panel plus backend pre-created.
package panel

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"time"

	"github.com/alienxp03/raptor/internal/paths"
	"github.com/alienxp03/raptor/internal/service"
)

// Request opens (or toggles) the panel. Empty fields keep their defaults.
type Request struct {
	Action  string `json:"action"` // "open" or "ping"
	Mode    string `json:"mode,omitempty"`
	Session string `json:"session,omitempty"`
	Block   string `json:"block,omitempty"`
	Client  string `json:"client,omitempty"`
	Title   string `json:"title,omitempty"`
	Repo    string `json:"repo,omitempty"`
}

// Reply is the host's one-line answer.
type Reply struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

// ErrUnavailable says no resident host answered; callers may fall back.
var ErrUnavailable = errors.New("panel host is not running")

// Call sends one request and reads one reply.
func Call(req Request) (Reply, error) {
	if req.Action == "" {
		req.Action = "open"
	}
	conn, err := net.DialTimeout("unix", paths.PanelSocket(), time.Second)
	if err != nil {
		return Reply{}, ErrUnavailable
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	payload, err := json.Marshal(req)
	if err != nil {
		return Reply{}, err
	}
	if _, err := conn.Write(append(payload, '\n')); err != nil {
		return Reply{}, ErrUnavailable
	}
	var reply Reply
	line, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil {
		return Reply{}, fmt.Errorf("panel host closed the connection: %w", err)
	}
	if err := json.Unmarshal(line, &reply); err != nil {
		return Reply{}, fmt.Errorf("invalid panel host reply: %w", err)
	}
	return reply, nil
}

// Open opens the panel, starting the resident host once when it is down.
// ErrUnavailable propagates when even the restart fails so callers can fall
// back to Launch Services.
func Open(req Request) error {
	reply, err := Call(req)
	if errors.Is(err, ErrUnavailable) {
		if kickErr := service.Kickstart(); kickErr != nil {
			return ErrUnavailable
		}
		deadline := time.Now().Add(3 * time.Second)
		for {
			reply, err = Call(req)
			if err == nil || !errors.Is(err, ErrUnavailable) || time.Now().After(deadline) {
				break
			}
			time.Sleep(100 * time.Millisecond)
		}
	}
	if err != nil {
		return err
	}
	if !reply.OK {
		return errors.New(reply.Error)
	}
	return nil
}
