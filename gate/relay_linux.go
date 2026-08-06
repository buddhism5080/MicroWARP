//go:build linux

package main

import (
	"io"
	"net"
	"syscall"

	"golang.org/x/sys/unix"
)

// relayOneDirection on Linux: kernel splice src→pipe→dst (no user-space payload copy).
// Falls back to pooled CopyBuffer if either side is not TCP or splice is unavailable.
func relayOneDirection(dst, src net.Conn) error {
	srcTCP, ok1 := unwrapTCP(src)
	dstTCP, ok2 := unwrapTCP(dst)
	if !ok1 || !ok2 {
		return copyBuffered(dst, src)
	}

	if err := spliceLoop(dstTCP, srcTCP); err != nil {
		if err == errNoSplice {
			return copyBuffered(dst, src)
		}
		return err
	}
	return nil
}

var errNoSplice = syscall.ENOSYS

func spliceLoop(dst, src *net.TCPConn) error {
	rawSrc, err := src.SyscallConn()
	if err != nil {
		return errNoSplice
	}
	rawDst, err := dst.SyscallConn()
	if err != nil {
		return errNoSplice
	}

	var p [2]int
	if err := unix.Pipe2(p[:], unix.O_CLOEXEC); err != nil {
		return errNoSplice
	}
	pr, pw := p[0], p[1]
	defer unix.Close(pr)
	defer unix.Close(pw)

	const maxChunk = 1 << 20 // 1 MiB

	for {
		var n int64
		var sErr error
		waitErr := rawSrc.Read(func(fd uintptr) bool {
			n, sErr = unix.Splice(int(fd), nil, pw, nil, maxChunk, unix.SPLICE_F_MOVE)
			return true
		})
		if waitErr != nil {
			return waitErr
		}
		if sErr != nil {
			if sErr == unix.EINTR || sErr == unix.EAGAIN {
				continue
			}
			if sErr == unix.ECONNRESET || sErr == unix.EPIPE || sErr == unix.ENOTCONN {
				return nil
			}
			return sErr
		}
		if n == 0 {
			return nil // EOF
		}

		left := n
		for left > 0 {
			var m int64
			var dErr error
			waitErr = rawDst.Write(func(fd uintptr) bool {
				m, dErr = unix.Splice(pr, nil, int(fd), nil, int(left), unix.SPLICE_F_MOVE)
				return true
			})
			if waitErr != nil {
				return waitErr
			}
			if dErr != nil {
				if dErr == unix.EINTR || dErr == unix.EAGAIN {
					continue
				}
				if dErr == unix.EPIPE || dErr == unix.ECONNRESET || dErr == unix.ENOTCONN {
					return nil
				}
				return dErr
			}
			if m <= 0 {
				return io.ErrUnexpectedEOF
			}
			left -= m
		}
	}
}
