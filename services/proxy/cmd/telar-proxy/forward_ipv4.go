package main

import (
	"encoding/binary"
	"errors"
	"net"

	"golang.org/x/net/ipv4"
)

const (
	ipv4VersionShift = 4
	ipv4IHLMask      = 0x0f
	ipv4WordBytes    = 4
	ipv4TOSOffset    = 1
	ipv4LengthOffset = 2
	ipv4IDOffset     = 4
	ipv4FlagsOffset  = 6
	ipv4TTLOffset    = 8
	ipv4FlagsShift   = 13
	ipv4FragmentMask = 0x1fff
)

func forwardIPv4(sender *ipv4.RawConn, packet []byte) error {
	if len(packet) < ipv4.HeaderLen ||
		packet[0]>>ipv4VersionShift != ipv4.Version {
		return errors.New("invalid IPv4 header")
	}

	headerLength := int(packet[0]&ipv4IHLMask) * ipv4WordBytes
	totalLength := int(binary.BigEndian.Uint16(packet[ipv4LengthOffset:]))

	if headerLength < ipv4.HeaderLen || totalLength < headerLength || totalLength > len(packet) {
		return errors.New("invalid IPv4 packet length")
	}

	fragments := binary.BigEndian.Uint16(packet[ipv4FlagsOffset:])

	header := ipv4.Header{
		Version:  ipv4.Version,
		Len:      headerLength,
		TOS:      int(packet[ipv4TOSOffset]),
		TotalLen: totalLength,
		ID:       int(binary.BigEndian.Uint16(packet[ipv4IDOffset:])),
		Flags:    ipv4.HeaderFlags(fragments >> ipv4FlagsShift),
		FragOff:  int(fragments & ipv4FragmentMask),
		TTL:      int(packet[ipv4TTLOffset]),
		Protocol: int(packet[protocolOffset]),
		Src:      net.IP(packet[sourceOffset : sourceOffset+net.IPv4len]),
		Dst:      net.IP(packet[destinationOffset : destinationOffset+net.IPv4len]),
		Options:  packet[ipv4.HeaderLen:headerLength],
	}

	return sender.WriteTo(&header, packet[headerLength:totalLength], nil)
}
