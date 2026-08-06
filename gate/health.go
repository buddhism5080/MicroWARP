package main

import (
	"bufio"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// HealthPool keeps an in-memory snapshot of healthy instance IDs.
// Hot path only reads memory; disk is polled on an interval or after gen bump.
type HealthPool struct {
	dir      string
	poll     time.Duration
	mu       sync.RWMutex
	healthy  []int
	rr       uint64
	lastGen  string
	lastScan time.Time
}

func NewHealthPool(dir string, poll time.Duration) *HealthPool {
	p := &HealthPool{dir: dir, poll: poll}
	p.refresh(true)
	return p
}

func (p *HealthPool) Start(stop <-chan struct{}) {
	t := time.NewTicker(p.poll)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			p.refresh(false)
		}
	}
}

func (p *HealthPool) snapshotPath() string {
	return filepath.Join(p.dir, "healthy.list")
}

func (p *HealthPool) genPath() string {
	return filepath.Join(p.dir, "pool.gen")
}

func (p *HealthPool) refresh(force bool) {
	genBytes, _ := os.ReadFile(p.genPath())
	gen := strings.TrimSpace(string(genBytes))

	p.mu.RLock()
	sameGen := !force && gen != "" && gen == p.lastGen
	p.mu.RUnlock()
	if sameGen {
		return
	}

	ids := p.loadIDs(gen)
	p.mu.Lock()
	p.healthy = ids
	p.lastGen = gen
	p.lastScan = time.Now()
	p.mu.Unlock()
}

func (p *HealthPool) loadIDs(gen string) []int {
	// Prefer healthy.list written by entrypoint.
	if b, err := os.ReadFile(p.snapshotPath()); err == nil {
		var ids []int
		for _, f := range strings.Fields(string(b)) {
			n, err := strconv.Atoi(f)
			if err == nil && n > 0 {
				ids = append(ids, n)
			}
		}
		if len(ids) > 0 || gen != "" {
			return ids
		}
	}

	// Fallback: scan inst*.status (rare path / first boot before snapshot).
	matches, _ := filepath.Glob(filepath.Join(p.dir, "inst*.status"))
	var ids []int
	for _, path := range matches {
		base := filepath.Base(path)
		// inst12.status
		s := strings.TrimPrefix(base, "inst")
		s = strings.TrimSuffix(s, ".status")
		n, err := strconv.Atoi(s)
		if err != nil || n <= 0 {
			continue
		}
		b, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		if strings.TrimSpace(string(b)) == "up" {
			ids = append(ids, n)
		}
	}
	return ids
}

// Pick returns a healthy instance id and true, or 0,false if none.
func (p *HealthPool) Pick() (int, bool) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	n := len(p.healthy)
	if n == 0 {
		return 0, false
	}
	i := atomic.AddUint64(&p.rr, 1)
	return p.healthy[int(i%uint64(n))], true
}

func (p *HealthPool) Len() int {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return len(p.healthy)
}

func (p *HealthPool) List() []int {
	p.mu.RLock()
	defer p.mu.RUnlock()
	out := make([]int, len(p.healthy))
	copy(out, p.healthy)
	return out
}

// WriteHealthySnapshot is used by tests; entrypoint writes this from shell.
func WriteHealthySnapshot(dir string, ids []int) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	var b strings.Builder
	for i, id := range ids {
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(strconv.Itoa(id))
	}
	b.WriteByte('\n')
	listPath := filepath.Join(dir, "healthy.list")
	if err := os.WriteFile(listPath, []byte(b.String()), 0o644); err != nil {
		return err
	}
	genPath := filepath.Join(dir, "pool.gen")
	prev, _ := os.ReadFile(genPath)
	n, _ := strconv.ParseUint(strings.TrimSpace(string(prev)), 10, 64)
	n++
	return os.WriteFile(genPath, []byte(strconv.FormatUint(n, 10)+"\n"), 0o644)
}

// RequestPunish drops a one-shot request file for entrypoint to consume.
func RequestPunish(dir string, instID int, reason string) error {
	if instID <= 0 {
		return nil
	}
	qdir := filepath.Join(dir, "punish_requests")
	if err := os.MkdirAll(qdir, 0o755); err != nil {
		return err
	}
	path := filepath.Join(qdir, strconv.Itoa(instID))
	// Include reason for logs; content is free-form.
	line := reason + "\n"
	if err := os.WriteFile(path, []byte(line), 0o644); err != nil {
		return err
	}
	log.Printf("punish requested inst=%d reason=%q", instID, truncate(reason, 160))
	return nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

// readFirstLine helper for tests
func readFirstLine(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	if sc.Scan() {
		return sc.Text()
	}
	return ""
}
