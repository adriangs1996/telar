package main

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"net/netip"
	"testing"

	"golang.org/x/net/http2"
)

func TestTLSInspectionRelaysRealHTTP2Exchange(t *testing.T) {
	originCA, originRoots := tlsTestAuthority(t, "Origin CA")
	inspectionCA, inspectionRoots := tlsTestAuthority(t, "Inspection CA")
	certificate, err := originCA.mint("proxy.test")
	if err != nil {
		t.Fatal(err)
	}
	policy, _ := newTLSHostPolicy([]string{"proxy.test"})
	inspector := &TLSInspector{authority: inspectionCA, roots: originRoots, policy: policy}
	application, client := tcpTestPair(t)
	upstream, server := tcpTestPair(t)
	ctx, cancel := context.WithTimeout(context.Background(), tcpTestTimeout)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- inspector.Relay(ctx, client, upstream, netip.MustParseAddr("127.0.0.1")) }()
	serverDone := make(chan error, 1)
	go func() {
		secured := tls.Server(server, &tls.Config{Certificates: []tls.Certificate{*certificate}, NextProtos: []string{"h2"}, MinVersion: tls.VersionTLS12})
		if err := secured.HandshakeContext(ctx); err != nil {
			serverDone <- err
			return
		}
		(&http2.Server{}).ServeConn(secured, &http2.ServeConnOpts{Handler: http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
			if request.ProtoMajor != 2 || request.Host != "proxy.test" {
				t.Error("origin did not receive the original HTTP/2 request")
			}
			io.WriteString(writer, "HTTP/2 inspected")
		})})
		serverDone <- nil
	}()
	transport := &http.Transport{
		ForceAttemptHTTP2: true,
		TLSClientConfig:   &tls.Config{RootCAs: inspectionRoots, MinVersion: tls.VersionTLS12},
		DialContext:       func(context.Context, string, string) (net.Conn, error) { return application, nil },
	}
	defer transport.CloseIdleConnections()
	response, err := (&http.Client{Transport: transport}).Get("https://proxy.test/")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil || string(body) != "HTTP/2 inspected" || response.ProtoMajor != 2 {
		t.Fatalf("HTTP/2 response: %q, protocol = %s, error = %v", body, response.Proto, err)
	}
	cancel()
	<-done
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}
