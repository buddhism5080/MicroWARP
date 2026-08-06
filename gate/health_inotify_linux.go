//go:build linux

package main

import (
	"encoding/binary"
	"log"
	"os"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// startInotify watches the state dir for healthy.list / pool.gen / inst*.status
// writes and forces an immediate memory refresh. Returns false if setup failed.
func startInotify(p *HealthPool, stop <-chan struct{}) bool {
	if err := os.MkdirAll(p.dir, 0o755); err != nil {
		return false
	}
	fd, err := unix.InotifyInit1(unix.IN_CLOEXEC | unix.IN_NONBLOCK)
	if err != nil {
		return false
	}

	flags := uint32(unix.IN_CLOSE_WRITE | unix.IN_MOVED_TO | unix.IN_CREATE | unix.IN_MODIFY | unix.IN_ATTRIB)
	if _, err := unix.InotifyAddWatch(fd, p.dir, flags); err != nil {
		_ = unix.Close(fd)
		return false
	}

	go func() {
		defer unix.Close(fd)
		buf := make([]byte, 16*(unix.SizeofInotifyEvent+64))
		for {
			select {
			case <-stop:
				return
			default:
			}

			n, err := unix.Read(fd, buf)
			if err != nil {
				if err == unix.EAGAIN || err == unix.EWOULDBLOCK {
					select {
					case <-stop:
						return
					case <-time.After(15 * time.Millisecond):
					}
					continue
				}
				if err == unix.EINTR {
					continue
				}
				log.Printf("health pool: inotify read: %v (poll-only fallback)", err)
				return
			}
			if interestedInotify(buf[:n]) {
				p.refresh(true)
			}
		}
	}()
	return true
}

func interestedInotify(b []byte) bool {
	offset := 0
	const hdr = unix.SizeofInotifyEvent
	for offset+hdr <= len(b) {
		nameLen := int(binary.LittleEndian.Uint32(b[offset+12 : offset+16]))
		name := ""
		if nameLen > 0 && offset+hdr+nameLen <= len(b) {
			raw := b[offset+hdr : offset+hdr+nameLen]
			for i := len(raw) - 1; i >= 0; i-- {
				if raw[i] != 0 {
					raw = raw[:i+1]
					break
				}
				if i == 0 {
					raw = nil
				}
			}
			name = string(raw)
		}
		if name == "" || name == "pool.gen" || name == "healthy.list" || strings.HasPrefix(name, "inst") {
			return true
		}
		offset += hdr + nameLen
	}
	return false
}
