//go:build !linux

package main

import "net"

func relayOneDirection(dst, src net.Conn) error {
	return copyBuffered(dst, src)
}
