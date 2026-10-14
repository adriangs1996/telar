package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"io"
	"time"
)

const (
	tlsHandshakeRecord = 22
	tlsECHExtension    = 0xfe0d
	tlsMaxProbeBytes   = 64 * 1024
	tlsSniffTimeout    = 10 * time.Second
)

var errTLSProbeComplete = errors.New("TLS ClientHello probe complete")
var errTLSProbeLimit = errors.New("TLS ClientHello exceeds probe limit")

type replayStream struct {
	tcpStream
	reader io.Reader
}

func (self *replayStream) Read(data []byte) (int, error) { return self.reader.Read(data) }

func replayTCP(stream tcpStream, prefix []byte) tcpStream {
	return &replayStream{tcpStream: stream, reader: io.MultiReader(bytes.NewReader(prefix), stream)}
}

type streamPrefix struct {
	client bool
	data   []byte
}

// Inspect either direction first so server-first protocols keep their greeting.
// Join both reads before clearing deadlines or letting the relay read again.
func peekTCPStreams(client, upstream tcpStream) (tcpStream, tcpStream, bool, error) {
	deadline := time.Now().Add(tlsSniffTimeout)
	if err := client.SetReadDeadline(deadline); err != nil {
		return nil, nil, false, err
	}
	defer client.SetReadDeadline(time.Time{})
	if err := upstream.SetReadDeadline(deadline); err != nil {
		return nil, nil, false, err
	}
	defer upstream.SetReadDeadline(time.Time{})
	done := make(chan streamPrefix, 2)
	peek := func(stream tcpStream, isClient bool) {
		data := make([]byte, 1)
		count, _ := stream.Read(data)
		done <- streamPrefix{client: isClient, data: data[:count]}
	}
	go peek(client, true)
	go peek(upstream, false)
	first := <-done
	if first.client {
		upstream.SetReadDeadline(time.Now())
	} else {
		client.SetReadDeadline(time.Now())
	}
	second := <-done
	clientPrefix, upstreamPrefix := first.data, second.data
	if !first.client {
		clientPrefix, upstreamPrefix = second.data, first.data
	}
	isTLS := len(upstreamPrefix) == 0 && len(clientPrefix) != 0 && clientPrefix[0] == tlsHandshakeRecord

	return replayTCP(client, clientPrefix), replayTCP(upstream, upstreamPrefix), isTLS, nil
}

type tlsProbeStream struct {
	tcpStream
	prefix []byte
}

func (self *tlsProbeStream) Read(data []byte) (int, error) {
	remaining := tlsMaxProbeBytes - len(self.prefix)
	if remaining == 0 {
		return 0, errTLSProbeLimit
	}
	if len(data) > remaining {
		data = data[:remaining]
	}
	count, err := self.tcpStream.Read(data)
	self.prefix = append(self.prefix, data[:count]...)
	return count, err
}

// The probe must never emit TLS alerts or close the real application's socket.
func (self *tlsProbeStream) Write(data []byte) (int, error) { return len(data), nil }
func (self *tlsProbeStream) Close() error                   { return nil }

type tlsHello struct {
	host      string
	protocols []string
	ech       bool
}

func probeTLSHello(ctx context.Context, client tcpStream) (tlsHello, tcpStream, error) {
	var hello tlsHello
	probe := &tlsProbeStream{tcpStream: client}
	connection := tls.Server(probe, &tls.Config{
		MinVersion: tls.VersionTLS12,
		GetConfigForClient: func(info *tls.ClientHelloInfo) (*tls.Config, error) {
			hello.host = info.ServerName
			hello.protocols = append([]string(nil), info.SupportedProtos...)
			for _, extension := range info.Extensions {
				hello.ech = hello.ech || extension == tlsECHExtension
			}
			return nil, errTLSProbeComplete
		},
	})
	err := connection.HandshakeContext(ctx)
	return hello, replayTCP(client, probe.prefix), err
}
