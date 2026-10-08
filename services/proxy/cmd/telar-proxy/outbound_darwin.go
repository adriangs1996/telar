package main

import (
	"net"

	"golang.org/x/sys/unix"
)

func bindOutboundInterface(fd int, iface *net.Interface) error {
	return unix.SetsockoptInt(
		fd,
		unix.IPPROTO_IP,
		unix.IP_BOUND_IF,
		iface.Index,
	)
}

func bindIPv6OutboundInterface(fd int, iface *net.Interface) error {
	return unix.SetsockoptInt(fd, unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF, iface.Index)
}
