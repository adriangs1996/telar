package main

import (
	"bytes"
	"encoding/binary"
	"net/netip"
	"testing"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip/header"
)

func extensionFragment(protocol byte, offset uint16, more bool, id uint32) []byte {
	const fragmentPayloadSize = 32
	packet := make([]byte, header.IPv6MinimumSize+ipv6FragmentHeaderSize+fragmentPayloadSize)
	packet[0] = header.IPv6Version << ipv4VersionShift
	binary.BigEndian.PutUint16(packet[ipv6PayloadLengthOffset:], uint16(len(packet)-header.IPv6MinimumSize))
	packet[protocolIPv6Offset] = byte(header.IPv6FragmentExtHdrIdentifier)
	copy(packet[sourceIPv6Offset:], netip.MustParseAddr(defaultTunnelIPv6).AsSlice())
	copy(packet[destinationIPv6Offset:], netip.MustParseAddr("2001:db8::9").AsSlice())
	packet[40] = byte(header.IPv6DestinationOptionsExtHdrIdentifier)
	flags := offset * ipv6ExtensionLengthUnit
	if more {
		flags |= 1
	}
	binary.BigEndian.PutUint16(packet[42:], flags)
	binary.BigEndian.PutUint32(packet[44:], id)
	if offset == 0 {
		packet[48] = protocol
		packet[68] = 5 << 4
	} else {
		copy(packet[48:], bytes.Repeat([]byte{0xff}, fragmentPayloadSize))
	}
	return append(make([]byte, packetOffset), packet...)
}

func dispatchFragment(t *testing.T, dispatcher *ipv6FragmentDispatcher, frame []byte, forward func([]byte, byte) error) error {
	t.Helper()
	info, err := packetProtocol(frame[packetOffset:])
	if err != nil {
		t.Fatal(err)
	}
	return dispatcher.dispatch(info, frame, forward)
}

func TestIPv6DispatchPreservesReorderedTCPUDPAndICMPFragments(t *testing.T) {
	for _, protocol := range []byte{TCP, UDP, ICMPv6} {
		for _, reverse := range []bool{false, true} {
			var dispatcher ipv6FragmentDispatcher
			first := extensionFragment(protocol, 0, true, 1)
			last := extensionFragment(protocol, 4, false, 1)
			frames := [][]byte{first, last}
			if reverse {
				frames = [][]byte{last, first}
			}
			var delivered [][]byte
			forward := func(frame []byte, got byte) error {
				if got != protocol {
					t.Fatalf("protocol = %d, want %d", got, protocol)
				}
				delivered = append(delivered, append([]byte(nil), frame...))
				return nil
			}
			for index, frame := range frames {
				if err := dispatchFragment(t, &dispatcher, frame, forward); err != nil {
					t.Fatal(err)
				}
				if reverse && index == 0 && len(delivered) != 0 {
					t.Fatal("forwarded an unclassified fragment")
				}
			}
			if len(delivered) != 2 || !bytes.Equal(delivered[0], first) || !bytes.Equal(delivered[1], last) || dispatcher.bytes != 0 {
				t.Fatal("changed fragments or leaked queued bytes")
			}
		}
	}
}

func TestIPv6DispatchOwnsQueuedBytesAndExpiresDecisions(t *testing.T) {
	var dispatcher ipv6FragmentDispatcher
	frame := extensionFragment(TCP, 4, false, 1)
	want := append([]byte(nil), frame...)
	var delivered [][]byte
	forward := func(frame []byte, _ byte) error {
		delivered = append(delivered, append([]byte(nil), frame...))
		return nil
	}
	if err := dispatchFragment(t, &dispatcher, frame, forward); err != nil {
		t.Fatal(err)
	}
	clear(frame)
	if err := dispatchFragment(t, &dispatcher, extensionFragment(TCP, 0, true, 1), forward); err != nil {
		t.Fatal(err)
	}
	if len(delivered) != 2 || !bytes.Equal(delivered[1], want) {
		t.Fatal("queued fragment referenced the reusable input buffer")
	}
	if err := dispatchFragment(t, &dispatcher, extensionFragment(TCP, 4, false, 2), forward); err != nil {
		t.Fatal(err)
	}
	dispatcher.expire(time.Now().Add(ipv6FragmentDecisionTimeout))
	if dispatcher.bytes != 0 || len(dispatcher.decisions) != 0 || dispatcher.ordered.Len() != 0 {
		t.Fatal("expired fragments retained memory")
	}
}

func TestIPv6DispatchIsolatesAtomicFragmentsAndRejectsProtocolChanges(t *testing.T) {
	var dispatcher ipv6FragmentDispatcher
	var protocols []byte
	forward := func(_ []byte, protocol byte) error {
		protocols = append(protocols, protocol)
		return nil
	}
	for _, frame := range [][]byte{extensionFragment(TCP, 4, false, 1), extensionFragment(UDP, 0, false, 1), extensionFragment(TCP, 0, true, 1)} {
		if err := dispatchFragment(t, &dispatcher, frame, forward); err != nil {
			t.Fatal(err)
		}
	}
	if !bytes.Equal(protocols, []byte{UDP, TCP, TCP}) {
		t.Fatalf("atomic fragment contaminated another datagram: %v", protocols)
	}
	if err := dispatchFragment(t, &dispatcher, extensionFragment(UDP, 0, true, 1), forward); err == nil {
		t.Fatal("accepted conflicting first-fragment protocols")
	}
	if err := dispatchFragment(t, &dispatcher, extensionFragment(TCP, 4, false, 1), forward); err == nil || len(protocols) != 3 {
		t.Fatal("forwarded a rejected datagram")
	}
}

func TestIPv6DispatchBoundsPendingFragmentsAndDatagrams(t *testing.T) {
	var dispatcher ipv6FragmentDispatcher
	forward := func(_ []byte, _ byte) error { t.Fatal("forwarded pending fragment"); return nil }
	frame := extensionFragment(TCP, 4, false, 1)
	for range ipv6MaxPendingFragments {
		if err := dispatchFragment(t, &dispatcher, frame, forward); err != nil {
			t.Fatal(err)
		}
	}
	if err := dispatchFragment(t, &dispatcher, frame, forward); err == nil || dispatcher.bytes != 0 {
		t.Fatal("pending fragment limit did not release its queue")
	}
	for id := uint32(2); id < ipv6MaxFragmentDecisions+3; id++ {
		if err := dispatchFragment(t, &dispatcher, extensionFragment(TCP, 4, false, id), forward); err != nil {
			t.Fatal(err)
		}
	}
	if len(dispatcher.decisions) != ipv6MaxFragmentDecisions || dispatcher.bytes > ipv6MaxPendingBytes {
		t.Fatal("fragment cache grew beyond its bounds")
	}
}

func TestIPv6DispatchBoundsPendingBytes(t *testing.T) {
	var dispatcher ipv6FragmentDispatcher
	frame := extensionFragment(TCP, 4, false, 1)
	frame = append(frame, make([]byte, 64000)...)
	packet := frame[packetOffset:]
	binary.BigEndian.PutUint16(packet[ipv6PayloadLengthOffset:], uint16(len(packet)-header.IPv6MinimumSize))
	forward := func(_ []byte, _ byte) error { t.Fatal("forwarded pending fragment"); return nil }
	for id := uint32(1); ; id++ {
		binary.BigEndian.PutUint32(packet[44:], id)
		if err := dispatchFragment(t, &dispatcher, frame, forward); err != nil {
			break
		}
		if int(id) > ipv6MaxPendingBytes/len(frame)+1 {
			t.Fatal("pending byte limit was not enforced")
		}
	}
	if dispatcher.bytes > ipv6MaxPendingBytes || ipv6MaxPendingBytes-dispatcher.bytes >= len(frame) {
		t.Fatal("pending byte limit was not enforced at capacity")
	}
}

func TestIPv6DispatchKeysDecisionsByBothAddresses(t *testing.T) {
	var dispatcher ipv6FragmentDispatcher
	var protocols []byte
	forward := func(_ []byte, protocol byte) error {
		protocols = append(protocols, protocol)
		return nil
	}
	if err := dispatchFragment(t, &dispatcher, extensionFragment(TCP, 4, false, 1), forward); err != nil {
		t.Fatal(err)
	}
	other := extensionFragment(UDP, 0, true, 1)
	copy(other[packetOffset+destinationIPv6Offset:], netip.MustParseAddr("2001:db8::10").AsSlice())
	if err := dispatchFragment(t, &dispatcher, other, forward); err != nil {
		t.Fatal(err)
	}
	other = extensionFragment(ICMPv6, 0, true, 1)
	copy(other[packetOffset+sourceIPv6Offset:], netip.MustParseAddr("2001:db8::11").AsSlice())
	if err := dispatchFragment(t, &dispatcher, other, forward); err != nil {
		t.Fatal(err)
	}
	if err := dispatchFragment(t, &dispatcher, extensionFragment(TCP, 0, true, 1), forward); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(protocols, []byte{UDP, ICMPv6, TCP, TCP}) {
		t.Fatalf("unrelated datagrams shared a protocol decision: %v", protocols)
	}
}
