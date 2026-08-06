package main

import (
	"context"
	"log"
	"net"
	"net/http"
	"sync"
	"time"
)

// CAWebMode controls the bootstrap CA cert HTTP server.
//   off  — never listen
//   once — listen until ca.crt is downloaded once (default when MITM on and not yet downloaded)
//   on   — always listen (env force)
type CAWebMode string

const (
	CAWebOff  CAWebMode = "off"
	CAWebOnce CAWebMode = "once"
	CAWebOn   CAWebMode = "on"
)

// StartCACertWeb serves GET /ca.crt (and /) from ca.CertPEMPath.
// In "once" mode the server shuts down after the first successful cert download.
// Returns a stop func (safe to call multiple times) and whether the server was started.
func StartCACertWeb(addr string, mode CAWebMode, ca *CA, logger *log.Logger) (stop func(), started bool) {
	if ca == nil || mode == CAWebOff || addr == "" {
		return func() {}, false
	}
	if mode == CAWebOnce && CADownloadDone(ca.dir) {
		if logger != nil {
			logger.Printf("CA web: skip (already downloaded once; set GATE_CA_WEB=1 to force)")
		}
		return func() {}, false
	}

	pemBytes, err := ca.ReadCertPEM()
	if err != nil || len(pemBytes) == 0 {
		if logger != nil {
			logger.Printf("CA web: cannot read cert: %v", err)
		}
		return func() {}, false
	}

	var (
		srv     *http.Server
		ln      net.Listener
		onceStop sync.Once
		mu      sync.Mutex
		stopped bool
	)

	shutdown := func() {
		onceStop.Do(func() {
			mu.Lock()
			stopped = true
			mu.Unlock()
			if srv != nil {
				ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				defer cancel()
				_ = srv.Shutdown(ctx)
			}
			if ln != nil {
				_ = ln.Close()
			}
		})
	}

	mux := http.NewServeMux()
	serveCRT := func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		// Re-read in case of replace (rare).
		b, err := ca.ReadCertPEM()
		if err != nil {
			http.Error(w, "cert unavailable", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/x-pem-file")
		w.Header().Set("Content-Disposition", `attachment; filename="microwarp-gate-ca.crt"`)
		w.Header().Set("Cache-Control", "no-store")
		if r.Method == http.MethodHead {
			w.Header().Set("Content-Length", fmtInt(len(b)))
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(b)

		if mode == CAWebOnce {
			if err := MarkCADownloaded(ca.dir); err != nil && logger != nil {
				logger.Printf("CA web: mark downloaded: %v", err)
			}
			if logger != nil {
				logger.Printf("CA web: ca.crt downloaded from %s — shutting down one-shot server", r.RemoteAddr)
			}
			// Shutdown outside request goroutine slightly delayed so response flushes.
			go func() {
				time.Sleep(50 * time.Millisecond)
				shutdown()
			}()
		}
	}

	mux.HandleFunc("/ca.crt", serveCRT)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("MicroWARP Gate MITM CA\n\nDownload: GET /ca.crt\n"))
	})

	ln, err = net.Listen("tcp", addr)
	if err != nil {
		if logger != nil {
			logger.Printf("CA web: listen %s: %v", addr, err)
		}
		return func() {}, false
	}
	srv = &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}

	go func() {
		if logger != nil {
			msg := "always on"
			if mode == CAWebOnce {
				msg = "one-shot until first /ca.crt download"
			}
			logger.Printf("CA web: http://%s/ca.crt (%s)", addr, msg)
		}
		err := srv.Serve(ln)
		mu.Lock()
		wasStopped := stopped
		mu.Unlock()
		if err != nil && err != http.ErrServerClosed && !wasStopped && logger != nil {
			logger.Printf("CA web: serve ended: %v", err)
		}
	}()

	return shutdown, true
}

func fmtInt(n int) string {
	if n == 0 {
		return "0"
	}
	var a [32]byte
	i := len(a)
	for n > 0 {
		i--
		a[i] = byte('0' + n%10)
		n /= 10
	}
	return string(a[i:])
}
