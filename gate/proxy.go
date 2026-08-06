package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"fmt"
	"io"
	"log"
	"net"
	"strconv"
	"strings"
	"time"
)

type Gate struct {
	cfg    Config
	pool   *HealthPool
	ca     *CA
	logger *log.Logger
}

func (g *Gate) Serve(ln net.Listener) error {
	for {
		c, err := ln.Accept()
		if err != nil {
			return err
		}
		go g.handle(c)
	}
}

func (g *Gate) handle(client net.Conn) {
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(g.cfg.DialTimeout + 30*time.Second))

	host, port, err := socksHandshake(client, g.cfg.SocksUser, g.cfg.SocksPass)
	if err != nil {
		g.logger.Printf("socks handshake: %v", err)
		return
	}
	_ = client.SetDeadline(time.Time{})

	needMITM := g.cfg.EnabledMITM && port == 443 && HostNeedsMITM(g.cfg.Rules, host)
	if needMITM {
		if err := g.handleMITM(client, host, port); err != nil {
			g.logger.Printf("mitm %s:%d: %v", host, port, err)
		}
		return
	}
	if err := g.handlePassthrough(client, host, port); err != nil {
		g.logger.Printf("pass %s:%d: %v", host, port, err)
	}
}

func (g *Gate) handlePassthrough(client net.Conn, host string, port int) error {
	if err := socksOK(client); err != nil {
		return err
	}
	up, via, err := g.dialPassthroughUpstream(host, port)
	if err != nil {
		return err
	}
	defer up.Close()

	tuneTCP(client, g.cfg.SockBuf, g.cfg.SockBuf)
	tuneTCP(up, g.cfg.SockBuf, g.cfg.SockBuf)

	if g.cfg.LogPassVia {
		g.logger.Printf("pass %s:%d via %s", host, port, via)
	}
	return bidirectionalRelay(client, up)
}

// dialPassthroughUpstream prefers direct dial to a healthy inst (skip HAProxy hop).
// Falls back to HAProxy RR SOCKS if direct is disabled or direct dials fail.
func (g *Gate) dialPassthroughUpstream(host string, port int) (net.Conn, string, error) {
	if g.cfg.PassDirect {
		tried := make(map[int]struct{}, 4)
		for attempt := 0; attempt < 3; attempt++ {
			id, ok := g.pool.Pick()
			if !ok {
				break
			}
			if _, seen := tried[id]; seen {
				if g.pool.Len() <= len(tried) {
					break
				}
				continue
			}
			tried[id] = struct{}{}
			c, err := g.dialViaInst(id, host, port)
			if err == nil {
				return c, fmt.Sprintf("inst%d", id), nil
			}
		}
	}

	c, err := g.dialViaHAProxy(host, port)
	if err != nil {
		if g.cfg.PassDirect {
			return nil, "", fmt.Errorf("direct+haproxy failed: %w", err)
		}
		return nil, "", err
	}
	return c, "haproxy", nil
}

func (g *Gate) dialViaHAProxy(host string, port int) (net.Conn, error) {
	d := net.Dialer{Timeout: g.cfg.DialTimeout}
	conn, err := d.Dial("tcp", g.cfg.HAProxyAddr)
	if err != nil {
		return nil, fmt.Errorf("dial haproxy: %w", err)
	}
	_ = conn.SetDeadline(time.Now().Add(g.cfg.DialTimeout))
	if err := socksClientHandshakeNoAuth(conn, host, port); err != nil {
		conn.Close()
		return nil, fmt.Errorf("socks via haproxy: %w", err)
	}
	_ = conn.SetDeadline(time.Time{})
	tuneTCP(conn, g.cfg.SockBuf, g.cfg.SockBuf)
	return conn, nil
}

func (g *Gate) dialViaInst(instID int, host string, port int) (net.Conn, error) {
	prefix := env("INSTANCE_SUBNET_PREFIX", "10.66")
	addr := fmt.Sprintf("%s.%d.2:1080", prefix, instID)
	d := net.Dialer{Timeout: g.cfg.DialTimeout}
	conn, err := d.Dial("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("dial inst%d: %w", instID, err)
	}
	_ = conn.SetDeadline(time.Now().Add(g.cfg.DialTimeout))
	if err := socksClientHandshakeNoAuth(conn, host, port); err != nil {
		conn.Close()
		return nil, fmt.Errorf("socks inst%d: %w", instID, err)
	}
	_ = conn.SetDeadline(time.Time{})
	tuneTCP(conn, g.cfg.SockBuf, g.cfg.SockBuf)
	return conn, nil
}

func (g *Gate) handleMITM(client net.Conn, host string, port int) error {
	instID, ok := g.pool.Pick()
	if !ok {
		_ = socksFail(client, socksRepFailure)
		return fmt.Errorf("no healthy instance")
	}
	if err := socksOK(client); err != nil {
		return err
	}

	leaf, err := g.ca.leafFor(host)
	if err != nil {
		return err
	}
	tlsClient := tls.Server(client, &tls.Config{
		Certificates: []tls.Certificate{*leaf},
		MinVersion:   tls.VersionTLS12,
		NextProtos:   []string{"http/1.1"},
	})
	if err := tlsClient.Handshake(); err != nil {
		return fmt.Errorf("client tls: %w", err)
	}

	rawUp, err := g.dialViaInst(instID, host, port)
	if err != nil {
		return err
	}
	defer rawUp.Close()

	tlsUp := tls.Client(rawUp, &tls.Config{
		ServerName: host,
		NextProtos: []string{"http/1.1"},
		MinVersion: tls.VersionTLS12,
	})
	if err := tlsUp.Handshake(); err != nil {
		return fmt.Errorf("upstream tls: %w", err)
	}

	return g.bridgeHTTPInspect(tlsClient, tlsUp, host, instID)
}

func (g *Gate) bridgeHTTPInspect(client, up net.Conn, host string, instID int) error {
	errc := make(chan error, 2)

	go func() {
		errc <- copyBuffered(up, client)
	}()

	go func() {
		errc <- g.copyUpstreamInspect(client, up, host, instID)
	}()

	err := <-errc
	_ = client.Close()
	_ = up.Close()
	<-errc
	if err != nil && err != io.EOF {
		return err
	}
	return nil
}

func (g *Gate) copyUpstreamInspect(dst, src net.Conn, host string, instID int) error {
	br := bufio.NewReaderSize(src, 64<<10)
	statusLine, err := br.ReadString('\n')
	if err != nil {
		return err
	}
	if _, err := io.WriteString(dst, statusLine); err != nil {
		return err
	}
	code := parseHTTPStatus(statusLine)

	var hdr bytes.Buffer
	for {
		line, err := br.ReadString('\n')
		if err != nil {
			return err
		}
		hdr.WriteString(line)
		if line == "\r\n" || line == "\n" {
			break
		}
	}
	if _, err := dst.Write(hdr.Bytes()); err != nil {
		return err
	}

	var bodyPrefix strings.Builder
	limit := g.cfg.BodyLimit
	if limit > 0 {
		tmp := make([]byte, limit)
		n, _ := io.ReadFull(br, tmp)
		if n > 0 {
			bodyPrefix.Write(tmp[:n])
			if _, err := dst.Write(tmp[:n]); err != nil {
				return err
			}
		}
	}

	if code > 0 {
		if rule, ok := MatchPunish(g.cfg.Rules, host, code, bodyPrefix.String()); ok {
			reason := fmt.Sprintf("host=%s status=%d rule=%s", host, code, rule.Raw)
			_ = RequestPunish(g.cfg.StateDir, instID, reason)
		}
	}

	bp := copyBufPool.Get().(*[]byte)
	defer copyBufPool.Put(bp)
	_, err = io.CopyBuffer(dst, br, *bp)
	return err
}

func parseHTTPStatus(statusLine string) int {
	parts := strings.Fields(statusLine)
	if len(parts) < 2 {
		return 0
	}
	code, err := strconv.Atoi(parts[1])
	if err != nil {
		return 0
	}
	return code
}
