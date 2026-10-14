package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/netip"
	"syscall"
	"time"
)

type TcpHandler struct {
	interface4 string
	interface6 string
	tls        *TLSInspector
}

type tcpStream interface {
	net.Conn
	CloseWrite() error
}

const tcpConnectTimeout = 10 * time.Second

func (self *TcpHandler) Connect(ctx context.Context, destination netip.AddrPort) (*net.TCPConn, error) {
	network := "tcp4"
	interfaceName := self.interface4
	bind := bindOutboundInterface
	if destination.Addr().Is6() {
		network = "tcp6"
		interfaceName = self.interface6
		bind = bindIPv6OutboundInterface
	}

	if interfaceName == "" {
		return nil, fmt.Errorf("no outbound interface for %s", network)
	}

	iface, err := net.InterfaceByName(interfaceName)
	if err != nil {
		return nil, err
	}

	dialer := net.Dialer{
		Timeout: tcpConnectTimeout,
		Control: func(_, _ string, raw syscall.RawConn) error {
			var bindErr error
			err := raw.Control(func(fd uintptr) {
				bindErr = bind(int(fd), iface)
			})
			if err != nil {
				return err
			}

			return bindErr
		},
	}

	connection, err := dialer.DialContext(ctx, network, destination.String())
	if err != nil {
		return nil, err
	}

	return connection.(*net.TCPConn), nil
}

func (self *TcpHandler) Relay(ctx context.Context, client, upstream tcpStream, destination netip.Addr) error {
	if self.tls != nil {
		return self.tls.Relay(ctx, client, upstream, destination)
	}

	return relayTCP(ctx, client, upstream)
}

// A clean EOF closes only the opposite write direction. A copy failure or
// cancellation closes both sockets so the other pump cannot remain blocked.
func relayTCP(ctx context.Context, client, upstream tcpStream) error {
	closeConnections := func() {
		client.Close()
		upstream.Close()
	}
	defer closeConnections()
	stop := context.AfterFunc(ctx, closeConnections)
	defer stop()

	done := make(chan error, 2)
	pump := func(destination, source tcpStream) {
		_, err := io.Copy(destination, source)
		if err == nil {
			err = destination.CloseWrite()
		}
		if err != nil {
			closeConnections()
		}

		done <- err
	}
	go pump(upstream, client)
	go pump(client, upstream)

	first, second := <-done, <-done
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if first != nil {
		return first
	}

	return second
}
