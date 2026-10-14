package main

import (
	"encoding/binary"
	"errors"
	"net/netip"

	"gvisor.dev/gvisor/pkg/tcpip/header"
)

const (
	ipv6ExtensionPrefixSize = 2
	ipv6ExtensionLengthUnit = 8
	ipv6FragmentHeaderSize  = 8
)

type packetProtocolInfo struct {
	protocol      byte
	known         bool
	needsDecision bool
	firstFragment bool
	fragmentNext  byte
	fragmentKey   ipv6FragmentKey
}

// All IPv4 fragments carry the transport protocol. For IPv6, walk the
// first fragment's complete chain. Later fragments may need its decision.
func packetProtocol(packet []byte) (packetProtocolInfo, error) {
	info := packetProtocolInfo{known: true}
	if len(packet) == 0 {
		return info, errors.New("empty IP packet")
	}
	if packet[0]>>ipv4VersionShift == header.IPv4Version {
		if len(packet) < header.IPv4MinimumSize {
			return info, errors.New("truncated IPv4 header")
		}
		info.protocol = packet[protocolOffset]
		return info, nil
	}
	if packet[0]>>ipv4VersionShift != header.IPv6Version || len(packet) < header.IPv6MinimumSize {
		return info, errors.New("invalid IPv6 header")
	}
	if header.IPv6MinimumSize+int(binary.BigEndian.Uint16(packet[ipv6PayloadLengthOffset:])) != len(packet) {
		return info, errors.New("invalid IPv6 payload length; jumbograms are unsupported")
	}

	protocol := packet[protocolIPv6Offset]
	offset := header.IPv6MinimumSize
	fragmentSeen := false
	for {
		switch header.IPv6ExtensionHeaderIdentifier(protocol) {
		case header.IPv6HopByHopOptionsExtHdrIdentifier, header.IPv6RoutingExtHdrIdentifier, header.IPv6DestinationOptionsExtHdrIdentifier:
			if offset+ipv6ExtensionPrefixSize > len(packet) {
				return info, errors.New("truncated IPv6 extension header")
			}
			length := (int(packet[offset+1]) + 1) * ipv6ExtensionLengthUnit
			if offset+length > len(packet) {
				return info, errors.New("invalid IPv6 extension length")
			}
			protocol = packet[offset]
			offset += length
		case header.IPv6ExperimentExtHdrIdentifier:
			if offset+header.IPv6ExperimentHdrLength > len(packet) {
				return info, errors.New("truncated IPv6 experiment header")
			}
			protocol = packet[offset]
			offset += header.IPv6ExperimentHdrLength
		case header.IPv6FragmentExtHdrIdentifier:
			if fragmentSeen || offset+ipv6FragmentHeaderSize > len(packet) {
				return info, errors.New("invalid IPv6 fragment header")
			}
			fragmentSeen = true
			fragment := header.IPv6FragmentExtHdr(packet[offset+ipv6ExtensionPrefixSize : offset+ipv6FragmentHeaderSize])
			protocol = packet[offset]
			offset += ipv6FragmentHeaderSize
			if header.IPv6ExtensionHeaderIdentifier(protocol) == header.IPv6FragmentExtHdrIdentifier {
				return info, errors.New("nested IPv6 fragment header")
			}
			payloadLength := len(packet) - offset
			if payloadLength == 0 || (fragment.More() && payloadLength%ipv6ExtensionLengthUnit != 0) {
				return info, errors.New("invalid IPv6 fragment payload length")
			}
			if int(fragment.FragmentOffset())*ipv6ExtensionLengthUnit+payloadLength > packetBufferSize {
				return info, errors.New("IPv6 fragment exceeds maximum datagram length")
			}
			info.firstFragment = fragment.FragmentOffset() == 0
			info.fragmentNext = protocol
			info.needsDecision = !fragment.IsAtomic()
			if info.needsDecision {
				info.fragmentKey = ipv6FragmentKey{
					source:      netip.AddrFrom16([16]byte(packet[sourceIPv6Offset:destinationIPv6Offset])),
					destination: netip.AddrFrom16([16]byte(packet[destinationIPv6Offset:header.IPv6MinimumSize])),
					id:          fragment.ID(),
				}
			}
			if !info.firstFragment {
				info.protocol = protocol
				info.known = !ipv6DispatchExtension(protocol)
				return info, nil
			}
		default:
			if fragmentSeen && info.firstFragment {
				if err := validateFirstFragmentTransport(protocol, packet[offset:]); err != nil {
					return info, err
				}
			}
			info.protocol = protocol
			return info, nil
		}
	}
}

func ipv6DispatchExtension(protocol byte) bool {
	switch header.IPv6ExtensionHeaderIdentifier(protocol) {
	case header.IPv6HopByHopOptionsExtHdrIdentifier, header.IPv6RoutingExtHdrIdentifier, header.IPv6DestinationOptionsExtHdrIdentifier, header.IPv6ExperimentExtHdrIdentifier:
		return true
	}

	return false
}

func validateFirstFragmentTransport(protocol byte, payload []byte) error {
	minimum := 0
	switch protocol {
	case TCP:
		minimum = header.TCPMinimumSize
		if len(payload) >= minimum {
			minimum = int(header.TCP(payload).DataOffset())
			if minimum < header.TCPMinimumSize {
				return errors.New("invalid TCP header in first IPv6 fragment")
			}
		}
	case UDP:
		minimum = header.UDPMinimumSize
	case ICMPv6:
		minimum = header.ICMPv6MinimumSize
	}
	if len(payload) < minimum {
		return errors.New("first IPv6 fragment does not contain the complete transport header")
	}

	return nil
}
