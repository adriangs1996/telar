package main

import (
	"net"

	"golang.org/x/sys/unix"
)

func bindOutboundInterface(fd int, iface *net.Interface) error {
	return unix.SetsockoptString(
		fd,
		unix.SOL_SOCKET,
		unix.SO_BINDTODEVICE,
		iface.Name,
	)
}

func bindIPv6OutboundInterface(fd int, iface *net.Interface) error {
	return bindOutboundInterface(fd, iface)
}
