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
	// clear read deadline for long-lived tunnels after handshake
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
	up, err := g.dialViaHAProxy(host, port)
	if err != nil {
		return err
	}
	defer up.Close()
	return splice(client, up)
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
		NextProtos:   []string{"http/1.1"}, // MVP: H1 only for inspectable status/body
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

	// Peek first HTTP response on the upstream side while bridging.
	return g.bridgeHTTPInspect(tlsClient, tlsUp, host, instID)
}

// bridgeHTTPInspect copies client→up fully; up→client peeks first response status/body prefix.
func (g *Gate) bridgeHTTPInspect(client, up net.Conn, host string, instID int) error {
	errc := make(chan error, 2)

	go func() {
		_, err := io.Copy(up, client)
		errc <- err
	}()

	go func() {
		errc <- g.copyUpstreamInspect(client, up, host, instID)
	}()

	err := <-errc
	// force close both sides to unblock the other copy
	_ = client.Close()
	_ = up.Close()
	<-errc
	if err != nil && err != io.EOF {
		return err
	}
	return nil
}

func (g *Gate) copyUpstreamInspect(dst, src net.Conn, host string, instID int) error {
	br := bufio.NewReader(src)
	// Read status line
	statusLine, err := br.ReadString('\n')
	if err != nil {
		return err
	}
	if _, err := io.WriteString(dst, statusLine); err != nil {
		return err
	}
	code := parseHTTPStatus(statusLine)

	// headers
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

	// body prefix for text match
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

	// rest of body / stream
	_, err = io.Copy(dst, br)
	return err
}

func parseHTTPStatus(statusLine string) int {
	// HTTP/1.1 429 Too Many Requests
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

func splice(a, b net.Conn) error {
	errc := make(chan error, 2)
	go func() {
		_, err := io.Copy(b, a)
		errc <- err
	}()
	go func() {
		_, err := io.Copy(a, b)
		errc <- err
	}()
	err := <-errc
	_ = a.Close()
	_ = b.Close()
	<-errc
	if err != nil && err != io.EOF {
		return err
	}
	return nil
}
