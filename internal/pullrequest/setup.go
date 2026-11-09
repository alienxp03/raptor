package pullrequest

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// checkPreSwitch fails closed: Prepare has no interactive destination yet. A
// source pre-switch hook must never be moved after creation or auto-approved.
func checkPreSwitch(repo string) error {
	out, err := command(repo, "wt", "hook", "show", "pre-switch", "--format=json")
	if err != nil {
		return fmt.Errorf("Worktrunk manual-hook support required: %w", err)
	}
	var hooks []json.RawMessage
	if err := json.Unmarshal([]byte(out), &hooks); err != nil {
		return err
	}
	if len(hooks) != 0 {
		return fmt.Errorf("source has pre-switch hooks; run wt switch interactively before Prepare (automatic pre-switch approval is unsafe)")
	}
	return nil
}

// Include effective user/system config, not guessed platform config paths.
func configStamp(path string) (string, error) {
	out, err := command(path, "wt", "config", "show", "--format=json")
	if err != nil {
		return "", err
	}
	var cfg map[string]json.RawMessage
	if err := json.Unmarshal([]byte(out), &cfg); err != nil {
		return "", err
	}
	// Hash both effective metadata and file bytes. Config JSON alone can omit
	// comments or content not represented by the parsed configuration.
	contents := map[string]string{}
	for _, kind := range []string{"user", "system", "project"} {
		data, err := configBytes(cfg[kind])
		if err != nil {
			return "", err
		}
		contents[kind] = fmt.Sprintf("%x", sha256.Sum256(data))
	}
	data, err := json.Marshal(struct {
		Config   map[string]json.RawMessage
		Contents map[string]string
	}{cfg, contents})
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", sha256.Sum256(data)), nil
}

func sameProjectConfig(source, destination string) error {
	read := func(root string) ([]byte, error) {
		out, err := command(root, "wt", "config", "show", "--format=json")
		if err != nil {
			return nil, err
		}
		var cfg map[string]json.RawMessage
		if err := json.Unmarshal([]byte(out), &cfg); err != nil {
			return nil, err
		}
		return configBytes(cfg["project"])
	}
	a, err := read(source)
	if err != nil {
		return err
	}
	b, err := read(destination)
	if err != nil {
		return err
	}
	if !bytes.Equal(a, b) {
		return fmt.Errorf("source and destination effective project configs differ; deferred hooks cannot preserve source config safely; run setup manually")
	}
	return nil
}

func configBytes(raw json.RawMessage) ([]byte, error) {
	var entry struct {
		Path   string
		Exists bool
	}
	if len(raw) == 0 || string(raw) == "null" {
		return nil, fmt.Errorf("effective config path unavailable")
	}
	if err := json.Unmarshal(raw, &entry); err != nil {
		return nil, err
	}
	if entry.Path == "" {
		return nil, fmt.Errorf("effective config path unavailable")
	}
	data, err := os.ReadFile(entry.Path)
	if os.IsNotExist(err) && !entry.Exists {
		return nil, nil
	}
	return data, err
}

func interactive(path string, args ...string) error {
	cmd := exec.Command("wt", args...)
	cmd.Dir, cmd.Stdin, cmd.Stdout, cmd.Stderr = path, os.Stdin, os.Stdout, os.Stderr
	// Interactive installs have no arbitrary timeout. The caller can interrupt.
	return cmd.Run()
}

func approvals(path, phase string) error {
	out, err := command(path, "wt", "config", "approvals", "list", "--format=json")
	if err != nil {
		return err
	}
	var data struct {
		Commands []struct {
			Phase    string `json:"phase"`
			Approved bool   `json:"approved"`
		} `json:"commands"`
	}
	if err := json.Unmarshal([]byte(out), &data); err != nil {
		return err
	}
	for _, c := range data.Commands {
		if c.Phase == phase && !c.Approved {
			return fmt.Errorf("%s approval declined or not saved; setup is incomplete", phase)
		}
	}
	return nil
}

// Setup runs in the destination terminal. The parent CLI must return its error,
// not exec this runner: Open's shell wrapper then starts a usable login shell.
// Retry resumes the failed/interrupted stage, never recreates resources.
func Setup(path string, retry bool) (err error) {
	original := path
	defer func() {
		if err != nil {
			exe, _ := os.Executable()
			fmt.Fprintf(os.Stderr, "Worktree setup failed: %v\nRetry: %s setup --path %s --retry\n", err, quote(exe), quote(original))
		}
	}()
	path, err = canonical(path)
	if err != nil {
		return err
	}
	// The setup process itself is the terminal-readiness signal. It waits until
	// Open persists release AFTER requesting selection; no visual ack is assumed.
	deadline := time.Now().Add(2 * time.Minute)
	for {
		unlock, lockErr := lock(path, false)
		if lockErr == nil {
			s, readErr := load(path)
			unlock()
			if readErr != nil {
				return readErr
			}
			if !validState(path, s) {
				return fmt.Errorf("no valid setup state for this worktree instance: %s; call Prepare", path)
			}
			if s.Released {
				break
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("destination not released; retry Open, then retry setup")
		}
		time.Sleep(100 * time.Millisecond)
	}
	unlock, err := lock(path, false)
	if err != nil {
		return err
	}
	defer unlock()
	s, err := load(path)
	if err != nil {
		return err
	}
	if !validState(path, s) {
		return fmt.Errorf("worktree instance changed; call Prepare")
	}
	if s.Complete {
		fmt.Fprintln(os.Stdout, "Worktree setup already complete.")
		return nil
	}
	if strings.HasSuffix(s.Failed, " interrupted") && s.Stage < 3 && s.New && s.Stage > 0 {
		return fmt.Errorf("background launch status is uncertain; inspect wt config state logs before manual recovery (not replayed)")
	}
	if !s.New && s.Failed == "post-switch interrupted" {
		return fmt.Errorf("background launch status is uncertain; inspect wt config state logs before manual recovery (not replayed)")
	}
	if s.Failed != "" && !retry {
		return fmt.Errorf("previous setup failed or was interrupted: %s; use --retry", s.Failed)
	}
	stamp, err := configStamp(s.Source)
	if err != nil {
		return err
	}
	if stamp != s.Config {
		return fmt.Errorf("hook config changed since Prepare; inspect and run setup manually")
	}
	if err := sameProjectConfig(s.Source, path); err != nil {
		return err
	}
	stages := []string{"post-switch"}
	if s.New {
		stages = []string{"pre-start", "post-start", "post-switch"}
	}
	for s.Stage < len(stages) {
		phase := stages[s.Stage]
		args := []string{"hook", phase}
		if phase == "pre-start" {
			args = append(args, "--foreground")
		}
		// Manual hooks run in destination cwd with destination config. Identical
		// project config is required above. Preserve source/base and PR variables.
		// --KEY=VALUE forwards UNUSED keys into {{ args }}. Use the verified
		// explicit --var form instead: it binds without changing hook arguments.
		values := []string{"branch=" + s.Branch, "worktree_path=" + path,
			"target=" + s.Branch, "target_worktree_path=" + path}
		if s.URL != "" {
			parts := strings.Split(s.URL, "/")
			values = append(values, "base_worktree_path="+s.Source,
				"pr_url="+s.URL, "pr_number="+parts[len(parts)-1])
		} else if s.BasePath != "" {
			values = append(values, "base_worktree_path="+s.BasePath)
		} else {
			// Manual hook context supplies the current worktree as a default.
			// Native creation has no base_worktree_path when the base ref has
			// no checkout. Stop if a hook uses it; never supply a wrong path.
			hooks, inspectErr := command(path, "wt", "hook", "show", phase, "--format=json")
			if inspectErr != nil {
				return inspectErr
			}
			if strings.Contains(hooks, "base_worktree_path") {
				return fmt.Errorf("%s uses base_worktree_path but the base has no worktree; run this setup manually", phase)
			}
		}
		for _, value := range values {
			args = append(args, "--var", value)
		}
		if s.Base != "" {
			args = append(args, "--var", "base="+s.Base)
		}
		fmt.Fprintf(os.Stdout, "Worktree setup: %s\n", phase)
		s.Failed = phase + " interrupted"
		if err = save(path, s); err != nil {
			return err
		}
		stageErr := interactive(path, args...)
		if stageErr == nil {
			stageErr = approvals(path, phase)
		}
		if stageErr != nil {
			s.Failed = phase + ": " + stageErr.Error()
			if saveErr := save(path, s); saveErr != nil {
				return fmt.Errorf("%s; state: %w", s.Failed, saveErr)
			}
			return fmt.Errorf("%s", s.Failed)
		}
		s.Stage++
		s.Failed = ""
		if err = save(path, s); err != nil {
			return err
		}
		if phase != "pre-start" {
			fmt.Fprintln(os.Stdout, "Background hooks launched. Logs: wt config state logs")
		}
	}
	s.Complete = true
	if err = save(path, s); err != nil {
		return err
	}
	fmt.Fprintln(os.Stdout, "Worktree setup complete (background hooks can still be running).")
	return nil
}
