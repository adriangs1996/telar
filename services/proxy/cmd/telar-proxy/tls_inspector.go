package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"log"
	"net/netip"
	"time"
)

const tlsHandshakeTimeout = 30 * time.Second

type tlsDirection uint8

const (
	tlsRequest tlsDirection = iota
	tlsResponse
)

type tlsChunk struct {
	host      string
	protocol  string
	direction tlsDirection
	data      []byte
}

type TLSInspector struct {
	authority *tlsAuthority
	policy    tlsHostPolicy
	roots     *x509.CertPool
	observe   func(tlsChunk)
}

type inspectedTLSStream struct {
	tcpStream
	bytes  int64
	onRead func([]byte)
}

func (self *inspectedTLSStream) Read(data []byte) (int, error) {
	count, err := self.tcpStream.Read(data)
	self.bytes += int64(count)
	if count != 0 && self.onRead != nil {
		self.onRead(data[:count])
	}

	return count, err
}

func (self *TLSInspector) Relay(ctx context.Context, client, upstream tcpStream, destination netip.Addr) error {
	originalClient, originalUpstream := client, upstream
	defer originalClient.Close()
	defer originalUpstream.Close()

	if ctx.Err() != nil {
		return ctx.Err()
	}

	stop := context.AfterFunc(ctx, func() { originalClient.Close(); originalUpstream.Close() })
	defer stop()

	client, upstream, isTLS, err := peekTCPStreams(client, upstream)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}

		return err
	}

	if !isTLS {
		return relayTCP(ctx, client, upstream)
	}

	handshakeCtx, cancel := context.WithTimeout(ctx, tlsHandshakeTimeout)
	defer cancel()
	deadline, _ := handshakeCtx.Deadline()
	client.SetDeadline(deadline)
	upstream.SetDeadline(deadline)
	hello, client, probeErr := probeTLSHello(handshakeCtx, client)
	if !errors.Is(probeErr, errTLSProbeComplete) {
		if handshakeCtx.Err() != nil {
			return handshakeCtx.Err()
		}
		if errors.Is(probeErr, errTLSProbeLimit) {
			return probeErr
		}

		client.SetDeadline(time.Time{})
		upstream.SetDeadline(time.Time{})
		return relayTCP(ctx, client, upstream)
	}

	host := hello.host
	if host == "" {
		host = destination.String()
	}

	host, err = canonicalTLSHost(host)
	if err != nil {
		return err
	}

	offer := tlsHTTPOffer(hello.protocols)
	if hello.ech || !self.policy.matches(host) || len(hello.protocols) != 0 && len(offer) == 0 {
		client.SetDeadline(time.Time{})
		upstream.SetDeadline(time.Time{})
		return relayTCP(ctx, client, upstream)
	}

	origin := tls.Client(upstream, &tls.Config{
		ServerName: host,
		RootCAs:    self.roots,
		NextProtos: offer,
		MinVersion: tls.VersionTLS12,
	})
	if err := origin.HandshakeContext(handshakeCtx); err != nil {
		return fmt.Errorf("TLS origin handshake for %s: %w", host, err)
	}

	certificate, err := self.authority.mint(host)
	if err != nil {
		return fmt.Errorf("minting TLS certificate for %s: %w", host, err)
	}

	protocol := origin.ConnectionState().NegotiatedProtocol
	config := &tls.Config{
		Certificates: []tls.Certificate{*certificate},
		MinVersion:   tls.VersionTLS12,
	}
	if protocol != "" {
		config.NextProtos = []string{protocol}
	}

	application := tls.Server(client, config)
	if err := application.HandshakeContext(handshakeCtx); err != nil {
		return fmt.Errorf("TLS application handshake for %s: %w", host, err)
	}

	if application.ConnectionState().NegotiatedProtocol != protocol {
		return errors.New("TLS ALPN differs between application and origin")
	}

	client.SetDeadline(time.Time{})
	upstream.SetDeadline(time.Time{})
	cancel()
	log.Printf("Inspecting TLS host=%s protocol=%q", host, protocol)
	request := &inspectedTLSStream{tcpStream: application, onRead: self.observer(host, protocol, tlsRequest)}
	response := &inspectedTLSStream{tcpStream: origin, onRead: self.observer(host, protocol, tlsResponse)}
	err = relayTCP(ctx, request, response)
	log.Printf("Inspected TLS host=%s request_bytes=%d response_bytes=%d", host, request.bytes, response.bytes)
	return err
}

// Observers receive borrowed plaintext buffers. Copy before retaining a chunk.
// The two relay directions may invoke the observer concurrently.
func (self *TLSInspector) observer(host, protocol string, direction tlsDirection) func([]byte) {
	if self.observe == nil {
		return nil
	}

	return func(data []byte) {
		self.observe(tlsChunk{host: host, protocol: protocol, direction: direction, data: data})
	}
}

func tlsHTTPOffer(protocols []string) []string {
	var offer []string
	for _, protocol := range protocols {
		if protocol == "h2" || protocol == "http/1.1" {
			offer = append(offer, protocol)
		}
	}

	return offer
}
