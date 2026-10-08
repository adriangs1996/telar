package main

import (
	"fmt"
	"net"
	"net/netip"
	"syscall"

	"golang.org/x/net/ipv4"
	"golang.org/x/sys/unix"
)

func openIPv4Sender(interfaceName string) (sender *ipv4.RawConn, err error) {
	iface, err := net.InterfaceByName(interfaceName)
	if err != nil {
		return nil, err
	}

	network := fmt.Sprintf("ip4:%d", unix.IPPROTO_RAW)
	conn, err := net.ListenIP(network, &net.IPAddr{})
	if err != nil {
		return nil, err
	}

	defer func() {
		if err != nil {
			conn.Close()
		}
	}()

	control, err := conn.SyscallConn()
	if err != nil {
		return nil, err
	}

	var bindErr error
	err = control.Control(func(fd uintptr) {
		bindErr = bindOutboundInterface(int(fd), iface)
	})
	if err != nil {
		return nil, err
	}
	if bindErr != nil {
		return nil, bindErr
	}

	return ipv4.NewRawConn(conn)
}

// Connecting a UDP socket selects a source address without transmitting a packet.
// Bind first so the kernel chooses among the original interface's current IPv6 addresses.
func interfaceIPv6(interfaceName string) (netip.Addr, error) {
	iface, err := net.InterfaceByName(interfaceName)
	if err != nil {
		return netip.Addr{}, err
	}

	dialer := net.Dialer{Control: func(network, address string, control syscall.RawConn) error {
		var bindErr error
		err := control.Control(func(fd uintptr) {
			bindErr = bindIPv6OutboundInterface(int(fd), iface)
		})
		if err != nil {
			return err
		}

		return bindErr
	}}
	conn, err := dialer.Dial("udp6", "[2000::]:9")
	if err != nil {
		return netip.Addr{}, err
	}
	defer conn.Close()

	source := conn.LocalAddr().(*net.UDPAddr).AddrPort().Addr()
	if !source.Is6() || source.Is4In6() || !source.IsGlobalUnicast() {
		return netip.Addr{}, fmt.Errorf("no usable unicast IPv6 source on %s", interfaceName)
	}

	return source, nil
}
