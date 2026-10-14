package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"net/netip"
	"testing"

	"golang.org/x/net/ipv6"
)

type testIPv6Sender struct {
	frame []byte
}

func (self *testIPv6Sender) Send(frame []byte) error {
	self.frame = append([]byte(nil), frame...)
	return nil
}

func (self *testIPv6Sender) Close() error          { return nil }
func (self *testIPv6Sender) InterfaceName() string { return "" }

func ipv6Packet(local netip.Addr) []byte {
	packet := make([]byte, ipv6.HeaderLen+16)
	packet[0] = ipv6.Version << ipv4VersionShift
	binary.BigEndian.PutUint16(packet[ipv6PayloadLengthOffset:], uint16(len(packet)-ipv6.HeaderLen))
	packet[protocolIPv6Offset] = 60 // Destination options followed by ICMPv6.
	packet[ipv6.HeaderLen] = ICMPv6
	copy(packet[sourceIPv6Offset:], netip.MustParseAddr("2001:db8::8").AsSlice())
	copy(packet[destinationIPv6Offset:], local.AsSlice())
	return packet
}

func TestIPv6ForwardingPreservesExtensionHeaders(t *testing.T) {
	packet := ipv6Packet(netip.MustParseAddr("2001:db8::9"))
	frame := append(make([]byte, packetOffset), packet...)
	sender := &testIPv6Sender{}
	if err := forwardIPv6(sender, frame); err != nil || !bytes.Equal(frame, sender.frame) {
		t.Fatalf("forwarding changed packet: %x, error = %v", sender.frame, err)
	}

	for _, broken := range [][]byte{frame[:packetOffset+10], frame[:len(frame)-1], append(append([]byte(nil), frame...), 0)} {
		if err := forwardIPv6(sender, broken); err == nil {
			t.Fatal("forwarded invalid IPv6 length")
		}
	}
}

func TestIPv6ReplyIsInjectedUnchanged(t *testing.T) {
	local := netip.MustParseAddr(defaultTunnelIPv6)
	device := &replyTestDevice{packet: ipv6Packet(local)}
	err := readPackets(device, &packetRelay{localAddress6: local})
	if !errors.Is(err, io.EOF) || !bytes.Equal(device.packet, device.written) || device.writeCount != 1 {
		t.Fatalf("modified reply: %x, writes = %d, error = %v", device.written, device.writeCount, err)
	}
}
