//go:build !linux

package main

func startInotify(p *HealthPool, stop <-chan struct{}) bool {
	return false
}
