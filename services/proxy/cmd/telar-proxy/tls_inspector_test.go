package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net/netip"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func tlsTestAuthority(t *testing.T, name string) (*tlsAuthority, *x509.CertPool) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	parent := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: name},
		NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, parent, parent, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	certificatePath := filepath.Join(directory, "ca.pem")
	keyPath := filepath.Join(directory, "ca-key.pem")
	if err := os.WriteFile(certificatePath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}), 0600); err != nil {
		t.Fatal(err)
	}
	authority, err := loadTLSAuthority(certificatePath, keyPath)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(authority.certificate)
	return authority, roots
}

func TestTLSInspectionDecryptsBothDirectionsAndMirrorsALPN(t *testing.T) {
	for _, version := range []uint16{tls.VersionTLS12, tls.VersionTLS13} {
		for _, protocol := range []string{"", "http/1.1", "h2"} {
			t.Run(fmt.Sprintf("%x/%s", version, protocol), func(t *testing.T) {
				originCA, originRoots := tlsTestAuthority(t, "Origin test CA")
				inspectionCA, inspectionRoots := tlsTestAuthority(t, "Inspection test CA")
				certificate, err := originCA.mint("proxy.test")
				if err != nil {
					t.Fatal(err)
				}
				policy, _ := newTLSHostPolicy([]string{"proxy.test"})
				var mu sync.Mutex
				var requests, responses []byte
				inspector := &TLSInspector{authority: inspectionCA, roots: originRoots, policy: policy}
				inspector.observe = func(chunk tlsChunk) {
					mu.Lock()
					defer mu.Unlock()
					if chunk.host != "proxy.test" || chunk.protocol != protocol {
						t.Errorf("unexpected TLS capture metadata: %s %q", chunk.host, chunk.protocol)
					}
					if chunk.direction == tlsRequest {
						requests = append(requests, chunk.data...)
					} else {
						responses = append(responses, chunk.data...)
					}
				}
				application, client := tcpTestPair(t)
				upstream, server := tcpTestPair(t)
				ctx, cancel := context.WithTimeout(context.Background(), tcpTestTimeout)
				defer cancel()
				done := make(chan error, 1)
				go func() { done <- inspector.Relay(ctx, client, upstream, netip.MustParseAddr("127.0.0.1")) }()
				serverConfig := &tls.Config{Certificates: []tls.Certificate{*certificate}, MinVersion: version, MaxVersion: version}
				clientConfig := &tls.Config{RootCAs: inspectionRoots, ServerName: "proxy.test", MinVersion: version, MaxVersion: version}
				if protocol != "" {
					serverConfig.NextProtos = []string{protocol}
					clientConfig.NextProtos = []string{"http/1.1", "h2"}
				}
				securedServer := tls.Server(server, serverConfig)
				request := bytes.Repeat([]byte("decrypted request bytes\n"), 4096)
				response := bytes.Repeat([]byte("decrypted response bytes\n"), 4096)
				serverDone := make(chan error, 1)
				go func() {
					got, err := io.ReadAll(securedServer)
					if err == nil && !bytes.Equal(got, request) {
						err = fmt.Errorf("origin received different request bytes: %d", len(got))
					}
					if err == nil {
						_, err = securedServer.Write(response)
					}
					if err == nil {
						err = securedServer.CloseWrite()
					}
					serverDone <- err
				}()
				securedClient := tls.Client(application, clientConfig)
				if _, err := securedClient.Write(request); err != nil {
					t.Fatal(err)
				}
				if err := securedClient.CloseWrite(); err != nil {
					t.Fatal(err)
				}
				got, err := io.ReadAll(securedClient)
				if err != nil || !bytes.Equal(got, response) {
					t.Fatalf("response = %d bytes, error = %v", len(got), err)
				}
				state := securedClient.ConnectionState()
				if state.NegotiatedProtocol != protocol || bytes.Equal(state.PeerCertificates[0].Raw, certificate.Certificate[0]) {
					t.Fatal("TLS inspection did not mirror ALPN or mint a replacement certificate")
				}
				if err := <-serverDone; err != nil {
					t.Fatal(err)
				}
				if err := <-done; err != nil {
					t.Fatal(err)
				}
				mu.Lock()
				defer mu.Unlock()
				if !bytes.Equal(requests, request) || !bytes.Equal(responses, response) {
					t.Fatal("observer did not receive the original plaintext in both directions")
				}
			})
		}
	}
}

func TestTLSInspectionRejectsUntrustedOrWrongHostnameOrigin(t *testing.T) {
	for _, wrongName := range []bool{false, true} {
		originCA, originRoots := tlsTestAuthority(t, "Origin CA")
		inspectionCA, inspectionRoots := tlsTestAuthority(t, "Inspection CA")
		host := "proxy.test"
		if wrongName {
			host = "other.test"
		}
		certificate, err := originCA.mint(host)
		if err != nil {
			t.Fatal(err)
		}
		policy, _ := newTLSHostPolicy([]string{"*"})
		roots := x509.NewCertPool()
		if wrongName {
			roots = originRoots
		}
		inspector := &TLSInspector{authority: inspectionCA, policy: policy, roots: roots}
		application, client := tcpTestPair(t)
		upstream, server := tcpTestPair(t)
		ctx, cancel := context.WithTimeout(context.Background(), tcpTestTimeout)
		done := make(chan error, 1)
		go func() { done <- inspector.Relay(ctx, client, upstream, netip.MustParseAddr("127.0.0.1")) }()
		serverDone := make(chan error, 1)
		go func() {
			serverDone <- tls.Server(server, &tls.Config{Certificates: []tls.Certificate{*certificate}}).HandshakeContext(ctx)
		}()
		securedClient := tls.Client(application, &tls.Config{RootCAs: inspectionRoots, ServerName: "proxy.test"})
		if err := securedClient.HandshakeContext(ctx); err == nil {
			t.Fatal("accepted an invalid origin certificate")
		}
		if err := <-done; err == nil {
			t.Fatal("origin verification failure was hidden")
		}
		cancel()
		<-serverDone
		if len(inspectionCA.leaves) != 0 {
			t.Fatal("minted a trusted leaf before validating the origin")
		}
	}
}
