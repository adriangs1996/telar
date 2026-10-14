package main

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"io"
	"net/netip"
	"testing"
)

func TestTLSInspectionPreservesExcludedHostsAndNonHTTPProtocols(t *testing.T) {
	for _, nonHTTP := range []bool{false, true} {
		originCA, originRoots := tlsTestAuthority(t, "Origin CA")
		inspectionCA, _ := tlsTestAuthority(t, "Inspection CA")
		certificate, err := originCA.mint("proxy.test")
		if err != nil {
			t.Fatal(err)
		}
		rules := []string{"excluded.test"}
		var protocols []string
		if nonHTTP {
			rules = []string{"*"}
			protocols = []string{"mqtt"}
		}
		policy, _ := newTLSHostPolicy(rules)
		inspector := &TLSInspector{authority: inspectionCA, policy: policy, observe: func(tlsChunk) { t.Error("captured excluded traffic") }}
		application, client := tcpTestPair(t)
		upstream, server := tcpTestPair(t)
		ctx, cancel := context.WithTimeout(context.Background(), tcpTestTimeout)
		done := make(chan error, 1)
		go func() { done <- inspector.Relay(ctx, client, upstream, netip.MustParseAddr("127.0.0.1")) }()
		securedServer := tls.Server(server, &tls.Config{Certificates: []tls.Certificate{*certificate}, NextProtos: protocols})
		serverDone := make(chan error, 1)
		go func() {
			_, err := io.CopyN(securedServer, securedServer, 4)
			serverDone <- err
		}()
		securedClient := tls.Client(application, &tls.Config{RootCAs: originRoots, ServerName: "proxy.test", NextProtos: protocols})
		if _, err := securedClient.Write([]byte("ping")); err != nil {
			t.Fatal(err)
		}
		response := make([]byte, 4)
		if _, err := io.ReadFull(securedClient, response); err != nil || string(response) != "ping" {
			t.Fatalf("passthrough response = %q, error = %v", response, err)
		}
		if !bytes.Equal(securedClient.ConnectionState().PeerCertificates[0].Raw, certificate.Certificate[0]) {
			t.Fatal("passthrough replaced the origin certificate")
		}
		if err := <-serverDone; err != nil {
			t.Fatal(err)
		}
		cancel()
		<-done
		if len(inspectionCA.leaves) != 0 {
			t.Fatal("minted a certificate for excluded traffic")
		}
	}
}

func TestTLSInspectionPreservesEncryptedClientHello(t *testing.T) {
	const (
		echConfigID = 1
		hpkeX25519  = 0x0020
		hpkeSHA256  = 0x0001
		hpkeAES128  = 0x0001
	)
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	publicName := []byte("public.test")
	body := []byte{echConfigID}
	body = binary.BigEndian.AppendUint16(body, hpkeX25519)
	body = binary.BigEndian.AppendUint16(body, uint16(len(key.PublicKey().Bytes())))
	body = append(body, key.PublicKey().Bytes()...)
	body = binary.BigEndian.AppendUint16(body, 4)
	body = binary.BigEndian.AppendUint16(body, hpkeSHA256)
	body = binary.BigEndian.AppendUint16(body, hpkeAES128)
	body = append(body, 255, byte(len(publicName)))
	body = append(body, publicName...)
	body = binary.BigEndian.AppendUint16(body, 0)
	config := binary.BigEndian.AppendUint16(nil, tlsECHExtension)
	config = binary.BigEndian.AppendUint16(config, uint16(len(body)))
	config = append(config, body...)
	configList := binary.BigEndian.AppendUint16(nil, uint16(len(config)))
	configList = append(configList, config...)

	originCA, originRoots := tlsTestAuthority(t, "Origin CA")
	inspectionCA, _ := tlsTestAuthority(t, "Inspection CA")
	certificate, err := originCA.mint("proxy.test")
	if err != nil {
		t.Fatal(err)
	}
	policy, _ := newTLSHostPolicy([]string{"*"})
	inspector := &TLSInspector{authority: inspectionCA, policy: policy, observe: func(tlsChunk) { t.Error("captured ECH traffic") }}
	application, client := tcpTestPair(t)
	upstream, server := tcpTestPair(t)
	ctx, cancel := context.WithTimeout(context.Background(), tcpTestTimeout)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- inspector.Relay(ctx, client, upstream, netip.MustParseAddr("127.0.0.1")) }()
	securedServer := tls.Server(server, &tls.Config{
		Certificates: []tls.Certificate{*certificate}, MinVersion: tls.VersionTLS13,
		EncryptedClientHelloKeys: []tls.EncryptedClientHelloKey{{Config: config, PrivateKey: key.Bytes()}},
	})
	serverDone := make(chan error, 1)
	go func() { _, err := io.CopyN(securedServer, securedServer, 4); serverDone <- err }()
	securedClient := tls.Client(application, &tls.Config{
		RootCAs: originRoots, ServerName: "proxy.test", MinVersion: tls.VersionTLS13,
		EncryptedClientHelloConfigList: configList,
	})
	if _, err := securedClient.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	response := make([]byte, 4)
	if _, err := io.ReadFull(securedClient, response); err != nil || string(response) != "ping" {
		t.Fatalf("ECH response = %q, error = %v", response, err)
	}
	if !securedClient.ConnectionState().ECHAccepted || !bytes.Equal(securedClient.ConnectionState().PeerCertificates[0].Raw, certificate.Certificate[0]) {
		t.Fatal("ECH was rejected or its certificate replaced")
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
	cancel()
	<-done
	if len(inspectionCA.leaves) != 0 {
		t.Fatal("minted a certificate for encrypted ClientHello")
	}
}

func TestTLSInspectionPreservesPlaintextAndServerFirstTraffic(t *testing.T) {
	for _, serverFirst := range []bool{false, true} {
		application, client := tcpTestPair(t)
		upstream, server := tcpTestPair(t)
		ctx, cancel := context.WithTimeout(context.Background(), tcpTestTimeout)
		defer cancel()
		inspector := &TLSInspector{}
		done := make(chan error, 1)
		go func() { done <- inspector.Relay(ctx, client, upstream, netip.MustParseAddr("127.0.0.1")) }()
		serverDone := make(chan error, 1)
		go func() {
			if serverFirst {
				if _, err := server.Write([]byte("220 server ready\r\n")); err != nil {
					serverDone <- err
					return
				}
			}
			_, err := io.CopyN(server, server, 4)
			server.CloseWrite()
			serverDone <- err
		}()
		if serverFirst {
			greeting := make([]byte, len("220 server ready\r\n"))
			if _, err := io.ReadFull(application, greeting); err != nil || string(greeting) != "220 server ready\r\n" {
				t.Fatalf("server greeting = %q, error = %v", greeting, err)
			}
		}
		if _, err := application.Write([]byte("ping")); err != nil {
			t.Fatal(err)
		}
		application.CloseWrite()
		response, err := io.ReadAll(application)
		if err != nil || string(response) != "ping" {
			t.Fatalf("plain response = %q, error = %v", response, err)
		}
		if err := <-serverDone; err != nil {
			t.Fatal(err)
		}
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}
}

func TestTLSInspectionCancellationStopsInitialProbe(t *testing.T) {
	_, client := tcpTestPair(t)
	upstream, _ := tcpTestPair(t)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- (&TLSInspector{}).Relay(ctx, client, upstream, netip.MustParseAddr("127.0.0.1")) }()
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("probe cancellation = %v", err)
	}
}
