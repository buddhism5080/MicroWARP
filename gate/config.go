package main

import (
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Listen           string
	HAProxyAddr      string
	StateDir         string
	CADir            string
	Rules            []Rule
	BodyLimit        int
	HealthPoll       time.Duration
	DialTimeout      time.Duration
	EnabledMITM      bool
	SocksUser        string
	SocksPass        string
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

func loadConfig() Config {
	body := envInt("GATE_BODY_LIMIT", 4096)
	if body < 0 {
		body = 0
	}
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

	cfg := Config{
		Listen:      env("GATE_LISTEN", ""),
		HAProxyAddr: env("GATE_HAPROXY_ADDR", "127.0.0.1:1081"),
		StateDir:    env("INSTANCE_STATE_DIR", "/var/run/microwarp"),
		CADir:       env("GATE_CA_DIR", "/var/run/microwarp/gate-ca"),
		Rules:       parseRules(env("PUNISH_RULES", "")),
		BodyLimit:   body,
		HealthPoll:  time.Duration(pollMS) * time.Millisecond,
		DialTimeout: time.Duration(dialMS) * time.Millisecond,
		SocksUser:   os.Getenv("SOCKS_USER"),
		SocksPass:   os.Getenv("SOCKS_PASS"),
	}
	if cfg.Listen == "" {
		bind := env("BIND_ADDR", "0.0.0.0")
		port := env("BIND_PORT", "1080")
		cfg.Listen = bind + ":" + port
	}
	cfg.EnabledMITM = len(cfg.Rules) > 0
	return cfg
}
