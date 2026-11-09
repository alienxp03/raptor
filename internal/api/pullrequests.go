package api

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/pullrequest"
)

// PR requests remain separate from New worktree: PR refs already name a branch.
// Partial mutation failures are result data so native clients retain recovery.
func (h *Handler) pullRequest(method string, params json.RawMessage) (any, error) {
	var p struct {
		Repo   string `json:"repo"`
		Input  string `json:"input"`
		Path   string `json:"path"`
		Target string `json:"target"`
	}
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if method == "pullrequests.open" {
		if p.Path == "" {
			return nil, fmt.Errorf("worktree path is required")
		}
		if p.Target != "session" && p.Target != "tab" {
			return nil, fmt.Errorf("pull requests open in a session or tab")
		}
		result, err := pullrequest.Open(p.Path, p.Target, h.ctx)
		if err != nil {
			return struct {
				pullrequest.OpenResult
				Error string `json:"error"`
			}{result, err.Error()}, nil
		}
		return result, nil
	}
	if strings.TrimSpace(p.Input) == "" {
		return nil, fmt.Errorf("enter a GitHub pull request URL or number")
	}
	var repo string
	var err error
	// A URL supplies its own repository. Do not turn the origin pane's cwd
	// into a conflicting mandatory context for a cross-repository URL.
	if p.Repo != "" || !strings.HasPrefix(strings.TrimSpace(p.Input), "https://github.com/") {
		repo, err = catalog.ResolveRepo(h.ctx, p.Repo)
		if err != nil {
			return nil, err
		}
	}
	if method == "pullrequests.resolve" {
		return pullrequest.Resolve(repo, p.Input)
	}
	result, err := pullrequest.Prepare(repo, p.Input)
	if err != nil {
		// A prospective path or an existing registration is not enough: Open
		// also needs Prepare's valid setup journal. Otherwise retry Prepare.
		if !pullrequest.Ready(result.Path) {
			return nil, err
		}
		return struct {
			pullrequest.Info
			Error string `json:"error"`
		}{result, err.Error()}, nil
	}
	return result, nil
}
