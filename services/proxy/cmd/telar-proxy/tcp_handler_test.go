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
	"errors"
	"io"
	"math/big"
	"net"
	"testing"
	"time"
)

const tcpTestTimeout = 5 * time.Second

func tcpTestPair(t *testing.T) (*net.TCPConn, *net.TCPConn) {
	t.Helper()
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	listener.SetDeadline(time.Now().Add(tcpTestTimeout))

	client, err := net.DialTCP("tcp4", nil, listener.Addr().(*net.TCPAddr))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { client.Close() })
	server, err := listener.AcceptTCP()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { server.Close() })
	client.SetDeadline(time.Now().Add(tcpTestTimeout))
	server.SetDeadline(time.Now().Add(tcpTestTimeout))
	return client, server
}

func TestTCPRelayPreservesHalfCloseAndLargeResponse(t *testing.T) {
	application, client := tcpTestPair(t)
	upstream, server := tcpTestPair(t)
	done := make(chan error, 1)
	go func() { done <- relayTCP(context.Background(), client, upstream) }()

	request := bytes.Repeat([]byte("request-data"), 65536)
	response := bytes.Repeat([]byte("response-data"), 65536)
	serverDone := make(chan error, 1)
	go func() {
		got, err := io.ReadAll(server)
		if err == nil && !bytes.Equal(got, request) {
			err = errors.New("request bytes changed")
		}
		if err == nil {
			_, err = server.Write(response)
		}
		if err == nil {
			err = server.CloseWrite()
		}
		serverDone <- err
	}()

	if _, err := application.Write(request); err != nil {
		t.Fatal(err)
	}
	if err := application.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(application)
	if err != nil || !bytes.Equal(got, response) {
		t.Fatalf("response = %d bytes, want %d; error = %v", len(got), len(response), err)
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestTCPRelayCancellationClosesIdleSockets(t *testing.T) {
	application, client := tcpTestPair(t)
	upstream, server := tcpTestPair(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- relayTCP(ctx, client, upstream) }()
	cancel()

	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancellation error = %v", err)
		}
	case <-time.After(tcpTestTimeout):
		t.Fatal("relay did not stop")
	}
	for _, connection := range []*net.TCPConn{application, server} {
		if _, err := connection.Read(make([]byte, 1)); err != io.EOF {
			t.Fatalf("idle peer was not closed: %v", err)
		}
	}
}

func TestTCPRelayPreservesTLSAndServerIdentity(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "proxy.test"},
		DNSNames:     []string{"proxy.test"},
		NotBefore:    time.Now().Add(-time.Minute),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(certificate)

	application, client := tcpTestPair(t)
	upstream, server := tcpTestPair(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- relayTCP(ctx, client, upstream) }()
	securedServer := tls.Server(server, &tls.Config{
		Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}},
		MinVersion:   tls.VersionTLS12,
	})
	serverDone := make(chan error, 1)
	go func() {
		_, err := io.CopyN(securedServer, securedServer, 4)
		serverDone <- err
	}()
	securedClient := tls.Client(application, &tls.Config{
		RootCAs: roots, ServerName: "proxy.test", MinVersion: tls.VersionTLS12,
	})
	if _, err := securedClient.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, 4)
	if _, err := io.ReadFull(securedClient, got); err != nil || string(got) != "ping" {
		t.Fatalf("TLS response = %q, error = %v", got, err)
	}
	if !bytes.Equal(securedClient.ConnectionState().PeerCertificates[0].Raw, der) {
		t.Fatal("relay replaced the origin certificate")
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
	cancel()
	<-done
}
