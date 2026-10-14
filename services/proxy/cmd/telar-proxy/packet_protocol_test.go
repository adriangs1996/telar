package main

import (
	"encoding/binary"
	"testing"

	"gvisor.dev/gvisor/pkg/tcpip/header"
)

func TestPacketProtocolIncludesIPv4TCPFragments(t *testing.T) {
	for _, fragment := range []uint16{header.IPv4FlagMoreFragments << 13, 185} {
		packet := make([]byte, header.IPv4MinimumSize+8)
		packet[0] = header.IPv4Version<<ipv4VersionShift | header.IPv4MinimumSize/ipv4WordBytes
		packet[protocolOffset] = TCP
		binary.BigEndian.PutUint16(packet[6:], fragment)
		if got, err := packetProtocol(packet); err != nil || got.protocol != TCP || !got.known {
			t.Fatalf("fragment protocol = %+v, error = %v", got, err)
		}
	}
}

func TestPacketProtocolWalksIPv6ExtensionsAndFragments(t *testing.T) {
	for _, protocol := range []byte{TCP, UDP, ICMPv6} {
		for _, fragmentOffset := range []uint16{0, 185 << 3} {
			packet := make([]byte, header.IPv6MinimumSize+3*ipv6ExtensionLengthUnit+24)
			packet[0] = header.IPv6Version << ipv4VersionShift
			packet[protocolIPv6Offset] = byte(header.IPv6HopByHopOptionsExtHdrIdentifier)
			packet[40] = byte(header.IPv6DestinationOptionsExtHdrIdentifier)
			packet[48] = byte(header.IPv6FragmentExtHdrIdentifier)
			packet[56] = protocol
			binary.BigEndian.PutUint16(packet[58:], fragmentOffset)
			packet[76] = 5 << 4 // TCP data offset in the first fragment.
			binary.BigEndian.PutUint16(packet[ipv6PayloadLengthOffset:], uint16(len(packet)-header.IPv6MinimumSize))
			if got, err := packetProtocol(packet); err != nil || got.protocol != protocol || !got.known {
				t.Fatalf("IPv6 fragment protocol = %+v, want %d, error = %v", got, protocol, err)
			}
		}
	}
}

func TestPacketProtocolRejectsTruncatedIPv6Chains(t *testing.T) {
	packet := make([]byte, header.IPv6MinimumSize+ipv6FragmentHeaderSize)
	packet[0] = header.IPv6Version << ipv4VersionShift
	packet[protocolIPv6Offset] = byte(header.IPv6FragmentExtHdrIdentifier)
	packet[40] = byte(header.IPv6DestinationOptionsExtHdrIdentifier)
	binary.BigEndian.PutUint16(packet[ipv6PayloadLengthOffset:], uint16(len(packet)-header.IPv6MinimumSize))
	if _, err := packetProtocol(packet); err == nil {
		t.Fatal("accepted a fragment with no extension payload")
	}
	packet[protocolIPv6Offset] = byte(header.IPv6HopByHopOptionsExtHdrIdentifier)
	packet[41] = 1
	for _, broken := range [][]byte{nil, packet[:10], packet[:41], packet} {
		if _, err := packetProtocol(broken); err == nil {
			t.Fatalf("accepted truncated packet: %x", broken)
		}
	}
}

func TestPacketProtocolRejectsInvalidFragmentTransportAndNesting(t *testing.T) {
	for _, mutate := range []func([]byte){
		func(packet []byte) { packet[68] = 0 },
		func(packet []byte) { packet[68] = 15 << 4 },
		func(packet []byte) { packet[40] = byte(header.IPv6FragmentExtHdrIdentifier) },
		func(packet []byte) { binary.BigEndian.PutUint16(packet[42:], 65528|1) },
	} {
		frame := extensionFragment(TCP, 0, true, 1)
		packet := frame[packetOffset:]
		mutate(packet)
		if _, err := packetProtocol(packet); err == nil {
			t.Fatalf("accepted invalid IPv6 fragment: %x", packet)
		}
	}
	frame := extensionFragment(TCP, 0, true, 1)
	packet := frame[packetOffset : len(frame)-16]
	binary.BigEndian.PutUint16(packet[ipv6PayloadLengthOffset:], uint16(len(packet)-header.IPv6MinimumSize))
	if _, err := packetProtocol(packet); err == nil {
		t.Fatal("accepted a first fragment without the complete TCP header")
	}
}
