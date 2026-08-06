package main

import (
	"errors"
	"io"
	"net"
	"sync"
	"time"
)

// copyBufSize is the user-space pump buffer for passthrough/MITM bulk copy.
// Larger than io.Copy's default 32KiB cuts syscall rate on fat flows.
const defaultCopyBufSize = 256 << 10 // 256 KiB

var copyBufPool = sync.Pool{
	New: func() any {
		b := make([]byte, defaultCopyBufSize)
		return &b
	},
}

func unwrapTCP(c net.Conn) (*net.TCPConn, bool) {
	switch t := c.(type) {
	case *net.TCPConn:
		return t, true
	default:
		// tls.Conn and others are not TCP — buffered path only
		return nil, false
	}
}

func tuneTCP(c net.Conn, readBuf, writeBuf int) {
	tc, ok := unwrapTCP(c)
	if !ok {
		return
	}
	_ = tc.SetNoDelay(true)
	_ = tc.SetKeepAlive(true)
	_ = tc.SetKeepAlivePeriod(30 * time.Second)
	if readBuf > 0 {
		_ = tc.SetReadBuffer(readBuf)
	}
	if writeBuf > 0 {
		_ = tc.SetWriteBuffer(writeBuf)
	}
}

func copyBuffered(dst io.Writer, src io.Reader) error {
	bp := copyBufPool.Get().(*[]byte)
	defer copyBufPool.Put(bp)
	_, err := io.CopyBuffer(dst, src, *bp)
	if err != nil && !errors.Is(err, io.EOF) && !isClosedConn(err) {
		return err
	}
	return nil
}

func isClosedConn(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	// avoid importing net.ErrClosed string match only
	return errors.Is(err, net.ErrClosed) ||
		s == "use of closed network connection" ||
		s == "read/write on closed pipe"
}

// bidirectionalRelay pumps both directions until either side EOF/errors.
// On Linux with two *net.TCPConn, uses kernel splice (zero-copy) when available.
func bidirectionalRelay(a, b net.Conn) error {
	errc := make(chan error, 2)
	go func() { errc <- relayOneDirection(b, a) }()
	go func() { errc <- relayOneDirection(a, b) }()

	err := <-errc
	// Unblock the peer copy.
	_ = closeWrite(a)
	_ = closeWrite(b)
	_ = a.Close()
	_ = b.Close()
	err2 := <-errc

	if err != nil && !errors.Is(err, io.EOF) && !isClosedConn(err) {
		return err
	}
	if err2 != nil && !errors.Is(err2, io.EOF) && !isClosedConn(err2) {
		return err2
	}
	return nil
}

func closeWrite(c net.Conn) error {
	type cw interface{ CloseWrite() error }
	if x, ok := c.(cw); ok {
		return x.CloseWrite()
	}
	return nil
}
