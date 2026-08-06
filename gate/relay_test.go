package main

import (
	"bytes"
	"io"
	"net"
	"sync"
	"testing"
	"time"
)

func TestBidirectionalRelayLocal(t *testing.T) {
	// client <-> left ; right <-> server
	left, right := net.Pipe()
	defer left.Close()
	defer right.Close()

	// server side: echo
	serverLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer serverLn.Close()

	go func() {
		c, err := serverLn.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		_, _ = io.Copy(c, c)
	}()

	up, err := net.Dial("tcp", serverLn.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer up.Close()

	// Bridge pipe "right" to upstream TCP — use TCP pair instead for splice path.
	a, b := localTCPPair(t)
	defer a.Close()
	defer b.Close()

	done := make(chan error, 1)
	go func() { done <- bidirectionalRelay(a, up) }()

	msg := []byte("hello-pass-perf-0123456789")
	if _, err := b.Write(msg); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, len(msg))
	_ = b.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := io.ReadFull(b, buf); err != nil {
		t.Fatal(err)
	}
	if string(buf) != string(msg) {
		t.Fatalf("got %q", buf)
	}
	_ = b.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("relay hang")
	}
}

func localTCPPair(t *testing.T) (net.Conn, net.Conn) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	var wg sync.WaitGroup
	var client net.Conn
	var cerr error
	wg.Add(1)
	go func() {
		defer wg.Done()
		client, cerr = net.Dial("tcp", ln.Addr().String())
	}()
	server, err := ln.Accept()
	if err != nil {
		t.Fatal(err)
	}
	wg.Wait()
	if cerr != nil {
		t.Fatal(cerr)
	}
	return client, server
}

func TestCopyBufferedPool(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	go func() {
		_, _ = a.Write([]byte("abc"))
		_ = a.Close()
	}()
	buf := &bytes.Buffer{}
	// net.Pipe is unbuffered: must read b while writer fills a
	if err := copyBuffered(buf, b); err != nil {
		t.Fatal(err)
	}
	if buf.String() != "abc" {
		t.Fatalf("got %q", buf.String())
	}
}

func TestEnvPassDirectDefault(t *testing.T) {
	t.Setenv("GATE_PASS_DIRECT", "")
	t.Setenv("PUNISH_RULES", "")
	cfg := loadConfig()
	if !cfg.PassDirect {
		t.Fatal("PassDirect should default true")
	}
	if cfg.SockBuf < 64<<10 {
		t.Fatalf("SockBuf=%d", cfg.SockBuf)
	}
}
