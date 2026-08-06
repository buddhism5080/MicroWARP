package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type CA struct {
	dir     string
	cert    *x509.Certificate
	key     *rsa.PrivateKey
	tlsCert tls.Certificate
	// Created is true when this process just generated a new CA on disk.
	Created bool
	mu      sync.Mutex
	cache   map[string]*tls.Certificate
}

func caCertPath(dir string) string { return filepath.Join(dir, "ca.crt") }
func caKeyPath(dir string) string  { return filepath.Join(dir, "ca.key") }

// caDownloadDonePath marks that ca.crt was fetched once via the bootstrap web.
func caDownloadDonePath(dir string) string {
	return filepath.Join(dir, ".ca_crt_downloaded")
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

// LoadOrCreateCA loads ca.crt+ca.key from dir, or generates a fresh pair in dir.
// No repo embed, no required volume mount — dir may be ephemeral under /var/run.
func LoadOrCreateCA(dir string) (*CA, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	certPath := caCertPath(dir)
	keyPath := caKeyPath(dir)

	if fileExists(certPath) && fileExists(keyPath) {
		certPEM, err := os.ReadFile(certPath)
		if err != nil {
			return nil, err
		}
		keyPEM, err := os.ReadFile(keyPath)
		if err != nil {
			return nil, err
		}
		ca, err := caFromPEM(dir, certPEM, keyPEM)
		if err != nil {
			return nil, fmt.Errorf("load existing CA: %w", err)
		}
		return ca, nil
	}

	// Generate new CA (not stored in git; lives only in container/state dir).
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, err
	}
	serial, _ := rand.Int(rand.Reader, big.NewInt(1<<62))
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   "MicroWARP Gate MITM CA",
			Organization: []string{"MicroWARP"},
		},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(10 * 365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            1,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	if err := os.WriteFile(certPath, certPEM, 0o644); err != nil {
		return nil, err
	}
	if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
		return nil, err
	}
	// New CA → allow one-shot web download again (clear previous done flag if any).
	_ = os.Remove(caDownloadDonePath(dir))

	tlsCert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, err
	}
	tlsCert.Leaf = cert
	return &CA{
		dir:     dir,
		cert:    cert,
		key:     key,
		tlsCert: tlsCert,
		Created: true,
		cache:   make(map[string]*tls.Certificate),
	}, nil
}

func caFromPEM(dir string, certPEM, keyPEM []byte) (*CA, error) {
	tlsCert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, err
	}
	if tlsCert.Leaf == nil {
		block, _ := pem.Decode(certPEM)
		if block == nil {
			return nil, fmt.Errorf("no cert PEM")
		}
		leaf, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, err
		}
		tlsCert.Leaf = leaf
	}
	keyBlock, _ := pem.Decode(keyPEM)
	if keyBlock == nil {
		return nil, fmt.Errorf("no key PEM")
	}
	var key *rsa.PrivateKey
	if k, err := x509.ParsePKCS1PrivateKey(keyBlock.Bytes); err == nil {
		key = k
	} else {
		k2, err2 := x509.ParsePKCS8PrivateKey(keyBlock.Bytes)
		if err2 != nil {
			return nil, fmt.Errorf("parse key: %v / %v", err, err2)
		}
		var ok bool
		key, ok = k2.(*rsa.PrivateKey)
		if !ok {
			return nil, fmt.Errorf("ca key is not RSA")
		}
	}
	return &CA{
		dir:     dir,
		cert:    tlsCert.Leaf,
		key:     key,
		tlsCert: tlsCert,
		cache:   make(map[string]*tls.Certificate),
	}, nil
}

func (c *CA) CertPEMPath() string {
	return caCertPath(c.dir)
}

func (c *CA) ReadCertPEM() ([]byte, error) {
	return os.ReadFile(c.CertPEMPath())
}

func (c *CA) leafFor(host string) (*tls.Certificate, error) {
	host = stripPort(host)
	c.mu.Lock()
	defer c.mu.Unlock()
	if cert, ok := c.cache[host]; ok {
		return cert, nil
	}
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, err
	}
	serial, _ := rand.Int(rand.Reader, big.NewInt(1<<62))
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: host},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	if ip := net.ParseIP(host); ip != nil {
		template.IPAddresses = []net.IP{ip}
	} else {
		template.DNSNames = []string{host}
	}
	der, err := x509.CreateCertificate(rand.Reader, template, c.cert, &key.PublicKey, c.key)
	if err != nil {
		return nil, err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	tlsCert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, err
	}
	tlsCert.Certificate = append(tlsCert.Certificate, c.tlsCert.Certificate...)
	c.cache[host] = &tlsCert
	return &tlsCert, nil
}

func stripPort(hostport string) string {
	h, _, err := net.SplitHostPort(hostport)
	if err != nil {
		return hostport
	}
	return h
}

// MarkCADownloaded records that the public cert was fetched once.
func MarkCADownloaded(dir string) error {
	return os.WriteFile(caDownloadDonePath(dir), []byte(time.Now().UTC().Format(time.RFC3339)+"\n"), 0o644)
}

// CADownloadDone reports whether one-shot download already completed.
func CADownloadDone(dir string) bool {
	return fileExists(caDownloadDonePath(dir))
}
