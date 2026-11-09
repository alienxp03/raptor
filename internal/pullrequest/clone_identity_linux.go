package pullrequest

import (
	"fmt"

	"golang.org/x/sys/unix"
)

func cloneIdentity(path string) (string, error) {
	var stat unix.Statx_t
	if err := unix.Statx(unix.AT_FDCWD, path, unix.AT_SYMLINK_NOFOLLOW, unix.STATX_INO|unix.STATX_BTIME, &stat); err == nil && stat.Mask&unix.STATX_BTIME != 0 {
		return fmt.Sprintf("%d:%d:%d:%d:%d", stat.Dev_major, stat.Dev_minor, stat.Ino, stat.Btime.Sec, stat.Btime.Nsec), nil
	}
	// Older filesystems do not expose birth time. Fail closed if directory
	// contents changed: an unchanged owned empty directory can still be retried.
	return fileIdentity(path)
}
