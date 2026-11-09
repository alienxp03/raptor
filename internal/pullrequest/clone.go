package pullrequest

import (
	"fmt"
	"os"
	"path/filepath"
)

// Ownership is outside the clone: gh requires an empty destination. Never clean
// a failed clone. A valid nonempty clone is discovered and validated by Resolve.
func claimClone(path string) error {
	key := "clone:" + prospectivePath(path)
	owner, err := load(key)
	if err != nil {
		return err
	}
	if _, err := os.Lstat(path); os.IsNotExist(err) {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			return err
		}
		if err := os.Mkdir(path, 0700); err != nil {
			return err
		}
		id, err := cloneIdentity(path)
		if err != nil {
			return err
		}
		return save(key, setupState{Path: path, Instance: id})
	}
	id, err := cloneIdentity(path)
	if err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() || owner.Path != path || owner.Instance != id {
		return fmt.Errorf("clone destination is occupied and ownership is not verified: %s", path)
	}
	entries, err := os.ReadDir(path)
	if err != nil {
		return err
	}
	if len(entries) != 0 {
		return fmt.Errorf("partial clone contains data; inspect before retry: %s", path)
	}
	return nil
}
