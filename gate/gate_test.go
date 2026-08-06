package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseAndMatchRules(t *testing.T) {
	rules := parseRules("*.x.ai|429,403|rate limit;grok.com|429|;api.example.com|400-499|")
	if len(rules) != 3 {
		t.Fatalf("rules=%d", len(rules))
	}
	if !HostNeedsMITM(rules, "api.x.ai") {
		t.Fatal("expected mitm for api.x.ai")
	}
	if HostNeedsMITM(rules, "example.org") {
		t.Fatal("no mitm for example.org")
	}

	if _, ok := MatchPunish(rules, "foo.x.ai", 429, "error: rate limit exceeded"); !ok {
		t.Fatal("expected punish on host+status+text")
	}
	if _, ok := MatchPunish(rules, "foo.x.ai", 429, "something else"); ok {
		t.Fatal("text mismatch must not punish")
	}
	if _, ok := MatchPunish(rules, "grok.com", 429, ""); !ok {
		t.Fatal("empty text rule should match status only")
	}
	if _, ok := MatchPunish(rules, "grok.com", 200, ""); ok {
		t.Fatal("200 must not match 429 rule")
	}
	if _, ok := MatchPunish(rules, "api.example.com", 404, "x"); !ok {
		t.Fatal("range 400-499")
	}
}

func TestHostMatchPatterns(t *testing.T) {
	if !hostMatches("*.x.ai", "grok.x.ai") {
		t.Fatal("*.x.ai")
	}
	if !hostMatches(".x.ai", "a.x.ai") {
		t.Fatal(".x.ai suffix")
	}
	if hostMatches("x.ai", "evil-x.ai") {
		t.Fatal("exact should not suffix")
	}
}

func TestHealthPoolMemoryPick(t *testing.T) {
	dir := t.TempDir()
	if err := WriteHealthySnapshot(dir, []int{2, 5, 9}); err != nil {
		t.Fatal(err)
	}
	p := NewHealthPool(dir, 0)
	if p.Len() != 3 {
		t.Fatalf("len=%d", p.Len())
	}
	seen := map[int]bool{}
	for i := 0; i < 9; i++ {
		id, ok := p.Pick()
		if !ok {
			t.Fatal("pick")
		}
		seen[id] = true
	}
	if !seen[2] || !seen[5] || !seen[9] {
		t.Fatalf("seen=%v", seen)
	}
}

func TestHealthPoolFallbackScan(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "inst1.status"), []byte("up\n"), 0o644)
	_ = os.WriteFile(filepath.Join(dir, "inst2.status"), []byte("down\n"), 0o644)
	_ = os.WriteFile(filepath.Join(dir, "inst3.status"), []byte("up\n"), 0o644)
	p := NewHealthPool(dir, 0)
	if p.Len() != 2 {
		t.Fatalf("len=%d list=%v", p.Len(), p.List())
	}
}

func TestRequestPunish(t *testing.T) {
	dir := t.TempDir()
	if err := RequestPunish(dir, 4, "status=429"); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "punish_requests", "4")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) == "" {
		t.Fatal("empty")
	}
}

func TestParseHTTPStatus(t *testing.T) {
	if parseHTTPStatus("HTTP/1.1 429 Too Many\r\n") != 429 {
		t.Fatal()
	}
	if parseHTTPStatus("HTTP/2 200\r\n") != 200 {
		t.Fatal()
	}
}
