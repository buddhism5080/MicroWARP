package main

import (
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	logger := log.New(os.Stdout, "==> [MicroWARP-gate] ", log.LstdFlags|log.Lmsgprefix)
	cfg := loadConfig()

	if len(cfg.Rules) == 0 {
		logger.Printf("PUNISH_RULES empty: MITM off; passthrough direct=%v sock_buf=%d", cfg.PassDirect, cfg.SockBuf)
	} else {
		logger.Printf("loaded %d punish rule(s); MITM on matching host:443; passthrough direct=%v", len(cfg.Rules), cfg.PassDirect)
		for i, r := range cfg.Rules {
			logger.Printf("  rule[%d]=%s", i, r.Raw)
		}
	}

	pool := NewHealthPool(cfg.StateDir, cfg.HealthPoll)
	stop := make(chan struct{})
	go pool.Start(stop)
	defer close(stop)

	var ca *CA
	var err error
	if cfg.EnabledMITM {
		ca, err = LoadOrCreateCA(cfg.CADir)
		if err != nil {
			logger.Fatalf("CA: %v", err)
		}
		logger.Printf("MITM CA ready: %s (install on clients that use punish hosts)", ca.CertPEMPath())
	}

	g := &Gate{cfg: cfg, pool: pool, ca: ca, logger: logger}

	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		logger.Fatalf("listen %s: %v", cfg.Listen, err)
	}
	logger.Printf("SOCKS5 listening on %s (haproxy=%s healthy=%d)", cfg.Listen, cfg.HAProxyAddr, pool.Len())

	go func() {
		ch := make(chan os.Signal, 1)
		signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
		<-ch
		logger.Printf("signal received, closing")
		_ = ln.Close()
	}()

	if err := g.Serve(ln); err != nil {
		// closed listener
		logger.Printf("serve done: %v", err)
	}
}
