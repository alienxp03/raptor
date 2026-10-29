package execx

import (
	"bytes"
	"fmt"
	"os/exec"
	"time"
)

type Result struct {
	Stdout string
	Stderr string
	Code   int
}

func Run(dir string, timeout time.Duration, name string, args ...string) (Result, error) {
	cmd := exec.Command(name, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	done := make(chan error, 1)
	if err := cmd.Start(); err != nil {
		return Result{}, err
	}
	go func() { done <- cmd.Wait() }()
	if timeout > 0 {
		select {
		case err := <-done:
			return finish(err, out.String(), errb.String())
		case <-time.After(timeout):
			_ = cmd.Process.Kill()
			<-done
			return Result{Stdout: out.String(), Stderr: "timed out"}, fmt.Errorf("%s timed out", name)
		}
	}
	err := <-done
	return finish(err, out.String(), errb.String())
}

func finish(err error, out, errOut string) (Result, error) {
	code := 0
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else {
			return Result{Stdout: out, Stderr: errOut}, err
		}
	}
	return Result{Stdout: out, Stderr: errOut, Code: code}, nil
}
