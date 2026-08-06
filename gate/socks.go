package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
)

const (
	socks5Version = 0x05
	socksCmdConnect = 0x01
	socksATYPIPv4 = 0x01
	socksATYDomain = 0x03
	socksATYPIPv6 = 0x04
	socksRepSuccess = 0x00
	socksRepFailure = 0x01
	socksRepCmdNotSupported = 0x07
)

// socksHandshake performs NO-AUTH (and optional user/pass) greeting + CONNECT request.
// Returns target host, port.
func socksHandshake(conn net.Conn, user, pass string) (host string, port int, err error) {
	buf := make([]byte, 258)
	if _, err = io.ReadFull(conn, buf[:2]); err != nil {
		return "", 0, err
	}
	if buf[0] != socks5Version {
		return "", 0, fmt.Errorf("not socks5")
	}
	nMethods := int(buf[1])
	if _, err = io.ReadFull(conn, buf[:nMethods]); err != nil {
		return "", 0, err
	}

	needAuth := user != "" || pass != ""
	if needAuth {
		// method 0x02 username/password
		if _, err = conn.Write([]byte{socks5Version, 0x02}); err != nil {
			return "", 0, err
		}
		// RFC1929
		if _, err = io.ReadFull(conn, buf[:2]); err != nil {
			return "", 0, err
		}
		if buf[0] != 0x01 {
			return "", 0, fmt.Errorf("bad auth ver")
		}
		ulen := int(buf[1])
		if _, err = io.ReadFull(conn, buf[:ulen+1]); err != nil {
			return "", 0, err
		}
		u := string(buf[:ulen])
		plen := int(buf[ulen])
		if _, err = io.ReadFull(conn, buf[:plen]); err != nil {
			return "", 0, err
		}
		p := string(buf[:plen])
		if u != user || p != pass {
			_, _ = conn.Write([]byte{0x01, 0x01})
			return "", 0, fmt.Errorf("auth failed")
		}
		if _, err = conn.Write([]byte{0x01, 0x00}); err != nil {
			return "", 0, err
		}
	} else {
		// no auth
		if _, err = conn.Write([]byte{socks5Version, 0x00}); err != nil {
			return "", 0, err
		}
	}

	// request
	if _, err = io.ReadFull(conn, buf[:4]); err != nil {
		return "", 0, err
	}
	if buf[0] != socks5Version {
		return "", 0, fmt.Errorf("bad req ver")
	}
	cmd := buf[1]
	atyp := buf[3]
	if cmd != socksCmdConnect {
		_ = socksFail(conn, socksRepCmdNotSupported)
		return "", 0, fmt.Errorf("cmd %d not supported", cmd)
	}

	switch atyp {
	case socksATYPIPv4:
		if _, err = io.ReadFull(conn, buf[:4]); err != nil {
			return "", 0, err
		}
		host = net.IP(buf[:4]).String()
	case socksATYDomain:
		if _, err = io.ReadFull(conn, buf[:1]); err != nil {
			return "", 0, err
		}
		l := int(buf[0])
		if _, err = io.ReadFull(conn, buf[:l]); err != nil {
			return "", 0, err
		}
		host = string(buf[:l])
	case socksATYPIPv6:
		if _, err = io.ReadFull(conn, buf[:16]); err != nil {
			return "", 0, err
		}
		host = net.IP(buf[:16]).String()
	default:
		_ = socksFail(conn, socksRepFailure)
		return "", 0, fmt.Errorf("bad atyp %d", atyp)
	}
	if _, err = io.ReadFull(conn, buf[:2]); err != nil {
		return "", 0, err
	}
	port = int(binary.BigEndian.Uint16(buf[:2]))
	return host, port, nil
}

func socksOK(conn net.Conn) error {
	// VER REP RSV ATYP BND.ADDR BND.PORT
	_, err := conn.Write([]byte{socks5Version, socksRepSuccess, 0x00, socksATYPIPv4, 0, 0, 0, 0, 0, 0})
	return err
}

func socksFail(conn net.Conn, rep byte) error {
	_, err := conn.Write([]byte{socks5Version, rep, 0x00, socksATYPIPv4, 0, 0, 0, 0, 0, 0})
	return err
}

func writeSocksConnectReq(w io.Writer, host string, port int) error {
	hostBytes := []byte(host)
	if len(hostBytes) > 255 {
		return fmt.Errorf("host too long")
	}
	req := make([]byte, 0, 7+len(hostBytes))
	req = append(req, socks5Version, socksCmdConnect, 0x00, socksATYDomain, byte(len(hostBytes)))
	req = append(req, hostBytes...)
	var pb [2]byte
	binary.BigEndian.PutUint16(pb[:], uint16(port))
	req = append(req, pb[:]...)
	_, err := w.Write(req)
	return err
}

func readSocksConnectReply(r io.Reader) error {
	buf := make([]byte, 4)
	if _, err := io.ReadFull(r, buf); err != nil {
		return err
	}
	if buf[0] != socks5Version {
		return fmt.Errorf("bad socks reply ver")
	}
	if buf[1] != socksRepSuccess {
		return fmt.Errorf("socks connect failed rep=%d", buf[1])
	}
	atyp := buf[3]
	switch atyp {
	case socksATYPIPv4:
		tmp := make([]byte, 4+2)
		_, err := io.ReadFull(r, tmp)
		return err
	case socksATYDomain:
		if _, err := io.ReadFull(r, buf[:1]); err != nil {
			return err
		}
		l := int(buf[0])
		tmp := make([]byte, l+2)
		_, err := io.ReadFull(r, tmp)
		return err
	case socksATYPIPv6:
		tmp := make([]byte, 16+2)
		_, err := io.ReadFull(r, tmp)
		return err
	default:
		return fmt.Errorf("bad reply atyp")
	}
}

func socksClientHandshakeNoAuth(conn net.Conn, host string, port int) error {
	if _, err := conn.Write([]byte{socks5Version, 0x01, 0x00}); err != nil {
		return err
	}
	buf := make([]byte, 2)
	if _, err := io.ReadFull(conn, buf); err != nil {
		return err
	}
	if buf[0] != socks5Version || buf[1] != 0x00 {
		return fmt.Errorf("socks auth rejected")
	}
	if err := writeSocksConnectReq(conn, host, port); err != nil {
		return err
	}
	return readSocksConnectReply(conn)
}
