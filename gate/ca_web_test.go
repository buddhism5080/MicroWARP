package main

import (
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLoadOrCreateCAGenerates(t *testing.T) {
	dir := t.TempDir()
	ca, err := LoadOrCreateCA(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !ca.Created {
		t.Fatal("expected Created")
	}
	if !fileExists(caCertPath(dir)) || !fileExists(caKeyPath(dir)) {
		t.Fatal("expected crt+key on disk")
	}
	// second load
	ca2, err := LoadOrCreateCA(dir)
	if err != nil {
		t.Fatal(err)
	}
	if ca2.Created {
		t.Fatal("second load should not regenerate")
	}
	leaf, err := ca2.leafFor("test.example.com")
	if err != nil || leaf == nil {
		t.Fatalf("leaf: %v", err)
	}
}

func TestCAWebOnceShutsAfterDownload(t *testing.T) {
	dir := t.TempDir()
	ca, err := LoadOrCreateCA(dir)
	if err != nil {
		t.Fatal(err)
	}
	// pick free port
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	_ = ln.Close()

	stop, started := StartCACertWeb(addr, CAWebOnce, ca, nil)
	if !started {
		t.Fatal("expected start")
	}
	defer stop()

	url := "http://" + addr + "/ca.crt"
	var body []byte
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := http.Get(url)
		if err != nil {
			time.Sleep(20 * time.Millisecond)
			continue
		}
		body, _ = io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if resp.StatusCode == 200 && len(body) > 0 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if len(body) == 0 {
		t.Fatal("download failed")
	}
	if !CADownloadDone(dir) {
		// allow brief delay for mark+shutdown
		time.Sleep(100 * time.Millisecond)
	}
	if !CADownloadDone(dir) {
		t.Fatal("expected download done flag")
	}

	// server should stop accepting soon
	deadline = time.Now().Add(2 * time.Second)
	stopped := false
	for time.Now().Before(deadline) {
		_, err := http.Get(url)
		if err != nil {
			stopped = true
			break
		}
		time.Sleep(30 * time.Millisecond)
	}
	if !stopped {
		t.Fatal("expected one-shot server to stop")
	}

	// restart with once should not start
	stop2, started2 := StartCACertWeb(addr, CAWebOnce, ca, nil)
	defer stop2()
	if started2 {
		t.Fatal("once mode must not restart after download done")
	}

	// force on should start
	stop3, started3 := StartCACertWeb(addr, CAWebOn, ca, nil)
	defer stop3()
	if !started3 {
		t.Fatal("on mode should start")
	}
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("status=%d", resp.StatusCode)
	}
}

func TestParseCAWeb(t *testing.T) {
	if parseCAWeb("off") != CAWebOff {
		t.Fatal()
	}
	if parseCAWeb("1") != CAWebOn {
		t.Fatal()
	}
	if parseCAWeb("") != CAWebOnce {
		t.Fatal()
	}
}

func TestNewCAClearsDownloadFlag(t *testing.T) {
	dir := t.TempDir()
	// fake old done + incomplete ca → regenerate path: only done flag
	_ = MarkCADownloaded(dir)
	// remove to force generate after writing empty? Load with no files
	_ = os.Remove(filepath.Join(dir, "ca.crt"))
	ca, err := LoadOrCreateCA(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !ca.Created {
		t.Fatal()
	}
	if CADownloadDone(dir) {
		t.Fatal("new CA should clear download-done flag")
	}
}
