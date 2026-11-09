package pullrequest

import (
	"fmt"
	"syscall"
)

func cloneIdentity(path string) (string, error) {
	var stat syscall.Stat_t
	if err := syscall.Lstat(path, &stat); err != nil {
		return "", err
	}
	return fmt.Sprintf("%d:%d:%d:%d", stat.Dev, stat.Ino, stat.Birthtimespec.Sec, stat.Birthtimespec.Nsec), nil
}
