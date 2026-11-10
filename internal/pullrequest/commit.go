package pullrequest

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
)

var commitOID = regexp.MustCompile(`^[0-9a-f]{40}$`)

// headRef is nullable only when the PR's actual source ref no longer exists.
// Do not treat HTTP failures (including 404s) as evidence of deletion.
func resolveHead(info *Info, id string) error {
	parts := strings.Split(id, "/")
	raw, err := command("", "gh", "api", "--hostname", "github.com", "graphql",
		"-f", "query=query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state headRefOid headRef{name}}}}",
		"-f", "owner="+parts[0], "-f", "repo="+parts[1], "-F", fmt.Sprintf("number=%d", info.Number))
	if err != nil {
		return fmt.Errorf("verify PR head branch: %w", err)
	}
	var response struct {
		Errors json.RawMessage `json:"errors"`
		Data   struct {
			Repository struct {
				PR struct {
					State string          `json:"state"`
					OID   string          `json:"headRefOid"`
					Ref   json.RawMessage `json:"headRef"`
				} `json:"pullRequest"`
			} `json:"repository"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(raw), &response); err != nil {
		return fmt.Errorf("parse PR head metadata: %w", err)
	}
	pr := response.Data.Repository.PR
	if (len(response.Errors) > 0 && string(response.Errors) != "[]" && string(response.Errors) != "null") ||
		(pr.State != "OPEN" && pr.State != "CLOSED" && pr.State != "MERGED") ||
		pr.State != info.State || !commitOID.MatchString(pr.OID) || pr.OID != info.HeadOID || len(pr.Ref) == 0 {
		return fmt.Errorf("PR head metadata is incomplete or changed; resolve again")
	}
	info.HeadDeleted = string(pr.Ref) == "null"
	if !info.HeadDeleted {
		var ref struct {
			Name string `json:"name"`
		}
		if err := json.Unmarshal(pr.Ref, &ref); err != nil || ref.Name != info.Branch {
			return fmt.Errorf("PR head branch metadata is invalid or changed; resolve again")
		}
	}
	return nil
}

// Called only after the preparation journal is durable. Never update the PR's
// original branch or FETCH_HEAD. Private fetch refs are unique and short-lived.
func prepareCommit(info Info) (resultErr error) {
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return err
	}
	ref := "refs/raptor/pr-checkout/" + hex.EncodeToString(nonce[:])
	defer func() {
		_, err := command(info.Repo, "git", "update-ref", "-d", ref)
		resultErr = errors.Join(resultErr, err)
	}()
	id, _, err := parse(info.URL, "")
	if err != nil {
		return err
	}
	// Use the same GitHub account as metadata resolution. SSH-only clones may
	// have no HTTPS Git credentials; do not prompt or change global Git config.
	if _, err := command(info.Repo, "env", "GIT_TERMINAL_PROMPT=0", "git", "-c", "credential.helper=",
		"-c", "credential.helper=!gh auth git-credential", "fetch", "--no-tags", "--no-write-fetch-head",
		"https://github.com/"+id+".git", fmt.Sprintf("refs/pull/%d/head:%s", info.Number, ref)); err != nil {
		return fmt.Errorf("fetch retained PR head: %w", err)
	}
	oid, err := command(info.Repo, "git", "rev-parse", "--verify", ref)
	kind, typeErr := command(info.Repo, "git", "cat-file", "-t", ref)
	if err != nil || typeErr != nil || kind != "commit" || oid != info.HeadOID {
		return fmt.Errorf("retained PR head does not match source head OID %s; no checkout performed", info.HeadOID)
	}
	branchRef := "refs/heads/" + info.Branch
	// Compare-and-create: a concurrent or pre-existing branch must never be overwritten.
	if _, err := command(info.Repo, "git", "update-ref", "--no-deref", branchRef, oid, strings.Repeat("0", 40)); err != nil {
		existing, readErr := command(info.Repo, "git", "rev-parse", "--verify", branchRef)
		_, symbolicErr := command(info.Repo, "git", "symbolic-ref", "-q", branchRef)
		if readErr != nil || symbolicErr == nil || existing != oid {
			return fmt.Errorf("branch %s already exists at a different commit or cannot be created; preserved: %w", info.Branch, err)
		}
	}
	return nil
}
