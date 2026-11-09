package rex

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func isolateRecency(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	t.Setenv("XDG_CACHE_HOME", filepath.Join(dir, "cache"))
}

func readRecencyTest(t *testing.T) recencyDocument {
	t.Helper()
	doc, _, err := readRecency(recencyPath(), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return doc
}

func TestRecencyOrderingAndRestore(t *testing.T) {
	isolateRecency(t)
	now := time.Now()
	start := now.Add(-time.Minute)
	record := func(host, id string, at time.Time, initial bool) {
		t.Helper()
		if err := recordSessionVisit(host, id, at, initial, now, start); err != nil {
			t.Fatal(err)
		}
	}
	record("", "session:a", now.Add(-10*time.Second), false)
	snapshot := LoadSessionRecency()
	record("remote", "session:a", now.Add(-8*time.Second), false)
	record("This Mac", "session:b", now.Add(-5*time.Second), false)
	// Delayed reads do not undo the confirmed local choice, even with later
	// timestamps for an initial read delivered after a confirmed command.
	record("", "session:a", now.Add(-9*time.Second), false)
	record("", "session:a", now.Add(-time.Second), true)
	record("", "session:b", now.Add(-20*time.Second), false)
	ranks := LoadSessionRecency()
	if ranks.Rank("", "session:b") != 0 || ranks.Rank("remote", "session:a") != 1 || ranks.Rank(LocalHostLabel, "session:a") != 2 {
		t.Fatalf("ranks: %#v", ranks)
	}
	if snapshot.Rank("", "session:a") != 0 || snapshot.Rank("", "session:b") != int(^uint(0)>>1) {
		t.Fatal("snapshot changed")
	}
	if ranks.Rank("other", "session:a") != int(^uint(0)>>1) {
		t.Fatal("host keys collided")
	}
	doc := readRecencyTest(t)
	if len(doc.Visits) != 3 || !doc.Visits[0].At.Equal(now.Add(-5*time.Second)) {
		t.Fatalf("restored: %#v", doc)
	}
	info, err := os.Stat(recencyPath())
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("history permissions: %v, %v", info, err)
	}
}

func TestRecencyInitialRestoredAndCrossProcessBarrier(t *testing.T) {
	isolateRecency(t)
	now := time.Now()
	start := now.Add(-time.Minute)
	if err := recordSessionVisit("", "session:restored", start.Add(-time.Minute), false, now, start); err != nil {
		t.Fatal(err)
	}
	if err := recordSessionVisit("", "session:initial", start.Add(time.Second), true, now, start); err != nil {
		t.Fatal(err)
	}
	if LoadSessionRecency().Rank("", "session:initial") != 0 {
		t.Fatal("initial did not reconcile restored history")
	}
	// This also works after another process writes the confirmation: the
	// barrier is the persisted timestamp, not just a process-local boolean.
	if err := recordSessionVisit("", "session:confirmed", start.Add(2*time.Second), false, now, start); err != nil {
		t.Fatal(err)
	}
	if err := recordSessionVisit("", "session:queued", start.Add(3*time.Second), true, now, start); err != nil {
		t.Fatal(err)
	}
	if len(LoadSessionRecency()) != 3 || LoadSessionRecency().Rank("", "session:confirmed") != 0 {
		t.Fatal("initial replaced confirmed selection")
	}
	// Another host's focus has a separate initial-read barrier.
	if err := recordSessionVisit("remote", "session:remote", start.Add(4*time.Second), true, now, start); err != nil {
		t.Fatal(err)
	}
	if LoadSessionRecency().Rank("remote", "session:remote") != 0 {
		t.Fatal("hosts not scoped")
	}
}

func TestRecencyValidationAndTrimming(t *testing.T) {
	isolateRecency(t)
	now := time.Now()
	for _, tt := range []struct {
		host, id string
		at       time.Time
	}{
		{"", "short-fixture", now}, {"", "session:", now}, {"", "session:a\x00b", now},
		{"bad\x00host", "session:a", now}, {"", "session:a", time.Time{}},
		{"", "session:a", now.Add(time.Hour)}, {"", "session:a", time.Unix(-1, 0)},
	} {
		if err := recordSessionVisit(tt.host, tt.id, tt.at, false, now, now); err != nil {
			t.Fatal(err)
		}
	}
	if len(LoadSessionRecency()) != 0 {
		t.Fatal("invalid visit saved")
	}
	if _, err := os.Stat(recencyPath()); !os.IsNotExist(err) {
		t.Fatalf("invalid input created history: %v", err)
	}
	if err := RecordSessionVisit(" This Mac ", " session:trimmed ", now.Add(-time.Second), false); err != nil {
		t.Fatal(err)
	}
	if LoadSessionRecency().Rank("", "session:trimmed") != 0 {
		t.Fatal("trim failed")
	}
	if err := RecordSessionVisit("Work Mac", "session:spaced-host", now, false); err != nil {
		t.Fatal(err)
	}
	if LoadSessionRecency().Rank("Work Mac", "session:spaced-host") != 0 {
		t.Fatal("valid Rex host labels with spaces must retain recency")
	}
}

func TestRecencyBounded(t *testing.T) {
	isolateRecency(t)
	now := time.Now()
	for i := 0; i < recencyLimit+10; i++ {
		if err := recordSessionVisit("", fmt.Sprintf("session:%03d", i), now.Add(time.Duration(i-recencyLimit-10)*time.Second), false, now, now); err != nil {
			t.Fatal(err)
		}
	}
	doc := readRecencyTest(t)
	if len(doc.Visits) != recencyLimit || doc.Visits[0].SessionID != "session:265" || doc.Visits[255].SessionID != "session:010" {
		t.Fatalf("unexpected bounds: %#v", doc)
	}
}

func TestRecencyDamagedHistoryPreserved(t *testing.T) {
	for _, input := range []string{"{", "", `{"version":99,"visits":[]}`, `{"version":1,"visits":[{"session_id":"short"}]}`, `null`} {
		t.Run(fmt.Sprintf("input-%x", input), func(t *testing.T) {
			isolateRecency(t)
			path := recencyPath()
			if err := os.WriteFile(path, []byte(input), 0o600); err != nil {
				t.Fatal(err)
			}
			if len(LoadSessionRecency()) != 0 {
				t.Fatal("damaged history loaded")
			}
			unchanged, _ := os.ReadFile(path)
			if string(unchanged) != input {
				t.Fatal("read changed input")
			}
			if err := RecordSessionUse("", "session:new"); err != nil {
				t.Fatal(err)
			}
			backups, _ := filepath.Glob(path + ".backup-*")
			if len(backups) != 1 {
				t.Fatalf("backups: %v", backups)
			}
			original, err := os.ReadFile(backups[0])
			if err != nil || string(original) != input {
				t.Fatalf("backup: %q, %v", original, err)
			}
			if LoadSessionRecency().Rank("", "session:new") != 0 {
				t.Fatal("did not recover")
			}
		})
	}
}

func TestRecencySubprocessWriter(t *testing.T) {
	id := os.Getenv("RAPTOR_RECENCY_TEST_WRITER")
	if id == "" {
		return
	}
	if err := RecordSessionUse("", id); err != nil {
		t.Fatal(err)
	}
}

func TestRecencySubprocessLockHolder(t *testing.T) {
	if os.Getenv("RAPTOR_RECENCY_TEST_LOCK_HOLDER") != "1" {
		return
	}
	lock, err := os.OpenFile(recencyPath()+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	// Signal only after the other process owns the lock. Hold it until the
	// parent closes stdin or kills us, not for a scheduler-dependent sleep.
	if _, err := os.Stdout.Write([]byte{1}); err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(io.Discard, os.Stdin); err != nil {
		t.Fatal(err)
	}
}

func TestRecencyProcessLockContention(t *testing.T) {
	isolateRecency(t)
	log := fakeRecencyRex(t)
	if err := RecordSessionUse("", "session:existing"); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(recencyPath())
	if err != nil {
		t.Fatal(err)
	}
	lockInfo, err := os.Stat(recencyPath() + ".lock")
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestRecencySubprocessLockHolder$")
	cmd.Env = append(os.Environ(), "RAPTOR_RECENCY_TEST_LOCK_HOLDER=1")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	var stopOnce sync.Once
	stop := func() {
		stopOnce.Do(func() {
			_ = cmd.Process.Kill()
			_ = stdin.Close()
			_ = cmd.Wait()
		})
	}
	t.Cleanup(stop)
	ready := make(chan error, 1)
	go func() {
		_, err := io.ReadFull(stdout, make([]byte, 1))
		ready <- err
	}()
	select {
	case err := <-ready:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("lock holder did not become ready")
	}
	for _, tt := range []struct {
		name           string
		run            func() error
		wantContention bool
	}{
		{"RecordSessionUse", func() error { return RecordSessionUse("", "session:blocked") }, true},
		{"Do", func() error { return Do("client:test", "session.select", "session_id=session:local") }, false},
		{"DoOn", func() error { return DoOn("remote", "client:test", "session.select", "session_id=session:remote") }, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			started := time.Now()
			done := make(chan error, 1)
			go func() { done <- tt.run() }()
			select {
			case err := <-done:
				if tt.wantContention {
					if !errors.Is(err, syscall.EWOULDBLOCK) {
						t.Fatalf("expected lock contention, got %v", err)
					}
				} else if err != nil {
					t.Fatalf("optional history failed navigation: %v", err)
				}
				if elapsed := time.Since(started); elapsed > time.Second {
					t.Fatalf("lock wait exceeded deadline: %v", elapsed)
				}
			case <-time.After(time.Second):
				stop()
				<-done
				t.Fatal("lock contention blocked beyond deadline")
			}
		})
	}
	after, err := os.ReadFile(recencyPath())
	if err != nil || string(after) != string(before) {
		t.Fatalf("contention changed history: %q, %v", after, err)
	}
	afterLockInfo, err := os.Stat(recencyPath() + ".lock")
	if err != nil || !os.SameFile(lockInfo, afterLockInfo) {
		t.Fatalf("contention replaced the lock file: %v", err)
	}
	calls, err := os.ReadFile(log)
	if err != nil || strings.Count(string(calls), "\n") != 2 {
		t.Fatalf("expected two fake navigation calls: %q, %v", calls, err)
	}
	stop()
	if err := RecordSessionUse("", "session:after-release"); err != nil {
		t.Fatal(err)
	}
	if got := len(LoadSessionRecency()); got != 2 {
		t.Fatalf("history did not merge after lock release: %d visits", got)
	}
}

func TestRecencyConcurrentProcesses(t *testing.T) {
	isolateRecency(t)
	const writers = 12
	commands := make([]*exec.Cmd, writers)
	for i := range commands {
		cmd := exec.Command(os.Args[0], "-test.run=^TestRecencySubprocessWriter$")
		cmd.Env = append(os.Environ(), fmt.Sprintf("RAPTOR_RECENCY_TEST_WRITER=session:writer-%d", i))
		commands[i] = cmd
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
	}
	for _, cmd := range commands {
		if err := cmd.Wait(); err != nil {
			t.Fatal(err)
		}
	}
	if got := len(LoadSessionRecency()); got != writers {
		t.Fatalf("merged %d of %d writers", got, writers)
	}
	temps, _ := filepath.Glob(recencyPath() + ".tmp-*")
	if len(temps) != 0 {
		t.Fatalf("temporary files remain: %v", temps)
	}
}

func TestRecencyConcurrentGoroutines(t *testing.T) {
	isolateRecency(t)
	var wg sync.WaitGroup
	for i := 0; i < 24; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if err := RecordSessionUse("", fmt.Sprintf("session:goroutine-%d", i)); err != nil {
				t.Error(err)
			}
			_ = LoadSessionRecency()
		}(i)
	}
	wg.Wait()
	if len(LoadSessionRecency()) != 24 {
		t.Fatal("lost goroutine writes")
	}
}

func fakeRecencyRex(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$RECENCY_CALLS"
if [ "$1" = --autostart=false ]; then shift; fi
if [ "$1" = api ]; then printf '%s\n' "$RECENCY_CLIENTS"; fi
exit "${RECENCY_EXIT:-0}"
`
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("RECENCY_CALLS", log)
	t.Setenv("RECENCY_EXIT", "0")
	return log
}

func TestRecencyDoHooks(t *testing.T) {
	isolateRecency(t)
	log := fakeRecencyRex(t)
	t.Setenv("RECENCY_EXIT", "1")
	if Do("client:test", "session.select", "session_id=session:failed") == nil {
		t.Fatal("expected failure")
	}
	if DoOn("remote", "client:test", "session.select", "session_id=session:failed") == nil {
		t.Fatal("expected remote failure")
	}
	if len(LoadSessionRecency()) != 0 {
		t.Fatal("recorded failed actions")
	}
	t.Setenv("RECENCY_EXIT", "0")
	if err := Do("client:test", "session.select", "session_id=session:local"); err != nil {
		t.Fatal(err)
	}
	if visits := readRecencyTest(t).Visits; len(visits) != 1 || visits[0].SessionID != "session:local" {
		t.Fatalf("expected one acknowledged visit: %#v", visits)
	}
	if err := DoOn("remote", "client:test", "session.select", "session_id=session:remote"); err != nil {
		t.Fatal(err)
	}
	if err := Do("client:test", "block.focus", "session_id=session:not-selection"); err != nil {
		t.Fatal(err)
	}
	if _, err := Run("do", "session.select", "session_id=session:server-only"); err != nil {
		t.Fatal(err)
	}
	if err := Do("client:test", "session.select", "session_id=fixture"); err != nil {
		t.Fatal(err)
	}
	// Repeated selections remain one visit.
	if err := Do("client:test", "session.select", "session_id=session:local"); err != nil {
		t.Fatal(err)
	}
	if len(LoadSessionRecency()) != 2 || LoadSessionRecency().Rank("", "session:local") != 0 {
		t.Fatal("incorrect successful visits")
	}
	calls, err := os.ReadFile(log)
	if err != nil || strings.Count(string(calls), "\n") != 8 || strings.Contains(string(calls), "api call") {
		t.Fatalf("extra Rex calls: %s, %v", calls, err)
	}
	// An optional history write error must not fail acknowledged navigation.
	if err := os.Mkdir(recencyPath()+".lock.blocked", 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(recencyPath() + ".lock"); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(recencyPath()+".lock.blocked", recencyPath()+".lock"); err != nil {
		t.Fatal(err)
	}
	if err := Do("client:test", "session.select", "session_id=session:optional"); err != nil {
		t.Fatal(err)
	}
}

func TestValidateFocusClientPIDCancellation(t *testing.T) {
	isolateRecency(t)
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte("#!/bin/sh\nexec sleep 60\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	started := time.Now()
	if ValidateFocusClientPIDContext(ctx, 42) || time.Since(started) > time.Second {
		t.Fatal("shutdown did not cancel the native PID validator")
	}
}

func TestValidateFocusClientPID(t *testing.T) {
	isolateRecency(t)
	log := fakeRecencyRex(t)
	for _, tt := range []struct {
		kind, principal, transport, state string
		pid                               int
		want                              bool
	}{
		{"app", "peer", "unix", "connected", 42, true},
		{"app", "peer", "unix", "", 42, true},
		{"cli", "peer", "unix", "connected", 42, false},
		{"app", "tailscale", "unix", "connected", 42, false},
		{"app", "peer", "tcp", "connected", 42, false},
		{"app", "peer", "unix", "lost", 42, false},
		{"app", "peer", "unix", "connected", 43, false},
		{"app", "peer", "unix", "connected", 0, false},
	} {
		data, _ := json.Marshal(map[string]any{"clients": []any{map[string]any{
			"info": map[string]any{"kind": tt.kind}, "connection_state": tt.state,
			"principal": map[string]any{"kind": tt.principal, "transport": tt.transport, "pid": tt.pid},
		}}})
		t.Setenv("RECENCY_CLIENTS", string(data))
		if got := ValidateFocusClientPID(42); got != tt.want {
			t.Fatalf("%+v: got %v", tt, got)
		}
	}
	t.Setenv("RECENCY_CLIENTS", "{")
	if ValidateFocusClientPID(42) || ValidateFocusClientPID(0) || ValidateFocusClientPID(-1) {
		t.Fatal("accepted invalid response or pid")
	}
	t.Setenv("RECENCY_EXIT", "1")
	if ValidateFocusClientPID(42) {
		t.Fatal("accepted failed API call")
	}
	calls, _ := os.ReadFile(log)
	for _, call := range strings.Split(strings.TrimSpace(string(calls)), "\n") {
		if call != `--autostart=false api call client.list {"kinds":["app"]}` {
			t.Fatalf("unexpected call: %s", call)
		}
	}
	if len(LoadSessionRecency()) != 0 {
		t.Fatal("validation mutated history")
	}
}
