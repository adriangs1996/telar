package main

import (
	"bytes"
	"crypto/x509"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestTLSAuthorityMintsDNSAndIPv6SANsAndBoundsLifetime(t *testing.T) {
	authority, roots := tlsTestAuthority(t, "Inspection CA")
	for _, host := range []string{"proxy.test", "127.0.0.1", "2001:db8::1"} {
		leaf, err := authority.mint(host)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := leaf.Leaf.Verify(x509.VerifyOptions{Roots: roots, DNSName: host}); err != nil {
			t.Fatal(err)
		}
		if leaf.Leaf.NotAfter.After(authority.certificate.NotAfter) {
			t.Fatal("leaf outlives the signing CA")
		}
		cached, err := authority.mint(host)
		if err != nil || !bytes.Equal(cached.Certificate[0], leaf.Certificate[0]) {
			t.Fatal("valid cached certificate was replaced")
		}
	}
	if _, err := authority.mint("*.test"); err == nil {
		t.Fatal("minted a certificate for an invalid concrete hostname")
	}
	authority.certificate.NotAfter = time.Now().Add(-time.Second)
	if _, err := authority.mint("proxy.test"); err == nil {
		t.Fatal("used an expired authority through its leaf cache")
	}
}

func TestTLSFilesRejectReadableKeysSymlinksAndNonRegularFiles(t *testing.T) {
	directory := t.TempDir()
	key := filepath.Join(directory, "key.pem")
	if err := os.WriteFile(key, []byte("private key fixture"), 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := readTLSFile(key, true); err == nil {
		t.Fatal("accepted a key readable by other users")
	}
	if err := os.Chmod(key, 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(directory, "link.pem")
	if err := os.Symlink(key, link); err != nil {
		t.Fatal(err)
	}
	if _, err := readTLSFile(link, true); err == nil {
		t.Fatal("followed a CA key symlink")
	}
	fifo := filepath.Join(directory, "fifo.pem")
	if err := syscall.Mkfifo(fifo, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := readTLSFile(fifo, true); err == nil {
		t.Fatal("accepted a nonregular TLS file")
	}
}
