package main

import (
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Listen      string
	HAProxyAddr string
	StateDir    string
	CADir       string
	Rules       []Rule
	BodyLimit   int
	HealthPoll  time.Duration
	DialTimeout time.Duration
	EnabledMITM bool
	SocksUser   string
	SocksPass   string
	// PassDirect: passthrough dials healthy inst directly (skip HAProxy hop).
	PassDirect bool
	// SockBuf: SO_RCVBUF/SO_SNDBUF hint (bytes). 0 = OS default.
	SockBuf int
	// LogPassVia: log each passthrough backend choice (noisy; debug only).
	LogPassVia bool
	// CAWeb: off | once | on — bootstrap HTTP for ca.crt download.
	CAWeb CAWebMode
	// CAWebAddr: listen address for CA cert HTTP (default 0.0.0.0:9180).
	CAWebAddr string
}

func env(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int) int {
	v := strings.TrimSpace(os.Getenv(k))
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		return def
	}
	return n
}

func envBool(k string, def bool) bool {
	v := strings.TrimSpace(os.Getenv(k))
	if v == "" {
		return def
	}
	switch strings.ToLower(v) {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return def
	}
}

// parseCAWeb: GATE_CA_WEB=
//   unset/auto → once when MITM enabled (caller may still skip if already downloaded)
//   0/false/off → off
//   1/true/on/always → on (keep serving)
//   once → once
func parseCAWeb(raw string) CAWebMode {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "0", "false", "no", "off":
		return CAWebOff
	case "1", "true", "yes", "on", "always":
		return CAWebOn
	case "once":
		return CAWebOnce
	case "", "auto":
		return CAWebOnce // default intent; main disables if MITM off
	default:
		return CAWebOnce
	}
}

func loadConfig() Config {
	body := envInt("GATE_BODY_LIMIT", 4096)
	if body > 1<<20 {
		body = 1 << 20
	}
	pollMS := envInt("GATE_HEALTH_POLL_MS", 500)
	if pollMS < 50 {
		pollMS = 50
	}
	dialMS := envInt("GATE_DIAL_TIMEOUT_MS", 10000)
	if dialMS < 1000 {
		dialMS = 1000
	}
	sockBuf := envInt("GATE_SOCK_BUF", 512<<10) // 512 KiB default
	if sockBuf > 4<<20 {
		sockBuf = 4 << 20
	}

	cfg := Config{
		Listen:      env("GATE_LISTEN", ""),
		HAProxyAddr: env("GATE_HAPROXY_ADDR", "127.0.0.1:1081"),
		StateDir:    env("INSTANCE_STATE_DIR", "/var/run/microwarp"),
		CADir:       env("GATE_CA_DIR", "/etc/wireguard/gate-ca"),
		Rules:       parseRules(env("PUNISH_RULES", "")),
		BodyLimit:   body,
		HealthPoll:  time.Duration(pollMS) * time.Millisecond,
		DialTimeout: time.Duration(dialMS) * time.Millisecond,
		SocksUser:   os.Getenv("SOCKS_USER"),
		SocksPass:   os.Getenv("SOCKS_PASS"),
		PassDirect:  envBool("GATE_PASS_DIRECT", true),
		SockBuf:     sockBuf,
		LogPassVia:  envBool("GATE_LOG_PASS_VIA", false),
		CAWeb:       parseCAWeb(os.Getenv("GATE_CA_WEB")),
		CAWebAddr:   env("GATE_CA_WEB_ADDR", "0.0.0.0:9180"),
	}
	if cfg.Listen == "" {
		bind := env("BIND_ADDR", "0.0.0.0")
		port := env("BIND_PORT", "1080")
		cfg.Listen = bind + ":" + port
	}
	cfg.EnabledMITM = len(cfg.Rules) > 0
	// No MITM → no CA web unless forced on (still useless without rules, keep off).
	if !cfg.EnabledMITM && cfg.CAWeb != CAWebOn {
		cfg.CAWeb = CAWebOff
	}
	return cfg
}
