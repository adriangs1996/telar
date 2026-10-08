package main

import (
	"net"

	"golang.org/x/sys/unix"
)

type linuxIPv6Sender struct {
	fd int
}

func openIPv6Sender(interfaceName string) (ipv6Sender, error) {
	iface, err := net.InterfaceByName(interfaceName)
	if err != nil {
		return nil, err
	}

	fd, err := unix.Socket(unix.AF_INET6, unix.SOCK_RAW|unix.SOCK_CLOEXEC, unix.IPPROTO_RAW)
	if err != nil {
		return nil, err
	}

	if err := unix.SetsockoptInt(fd, unix.IPPROTO_IPV6, unix.IPV6_HDRINCL, 1); err != nil {
		unix.Close(fd)
		return nil, err
	}

	if err := bindIPv6OutboundInterface(fd, iface); err != nil {
		unix.Close(fd)
		return nil, err
	}

	return &linuxIPv6Sender{fd: fd}, nil
}

func (self *linuxIPv6Sender) Send(frame []byte) error {
	packet := frame[packetOffset:]
	destination := unix.SockaddrInet6{}
	copy(destination.Addr[:], packet[destinationIPv6Offset:destinationIPv6Offset+net.IPv6len])
	return unix.Sendto(self.fd, packet, 0, &destination)
}

func (self *linuxIPv6Sender) Close() error          { return unix.Close(self.fd) }
func (self *linuxIPv6Sender) InterfaceName() string { return "" }
