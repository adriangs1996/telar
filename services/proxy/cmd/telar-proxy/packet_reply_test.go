package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"net/netip"
	"testing"

	"golang.org/x/net/ipv4"
	"golang.zx2c4.com/wireguard/tun"
)

type replyTestDevice struct {
	tun.Device
	packet     []byte
	read       bool
	written    []byte
	writeCount int
	writeError error
	shortWrite bool
}

func (self *replyTestDevice) BatchSize() int { return 1 }

func (self *replyTestDevice) Read(buffers [][]byte, sizes []int, offset int) (int, error) {
	if self.read {
		return 0, io.EOF
	}

	self.read = true
	copy(buffers[0][offset:], self.packet)
	sizes[0] = len(self.packet)
	return 1, nil
}

func (self *replyTestDevice) Write(buffers [][]byte, offset int) (int, error) {
	self.writeCount++
	self.written = append([]byte(nil), buffers[0][offset:]...)
	if self.writeError != nil {
		return 0, self.writeError
	}

	if self.shortWrite {
		return 0, nil
	}

	return len(buffers), nil
}

func ipv4ReplyPacket(protocol byte, localAddress netip.Addr) []byte {
	payload := []byte("opaque reply payload")
	packet := make([]byte, ipv4.HeaderLen+len(payload))
	packet[0] = ipv4.Version<<ipv4VersionShift | byte(ipv4.HeaderLen/ipv4WordBytes)
	packet[protocolOffset] = protocol
	binary.BigEndian.PutUint16(packet[ipv4LengthOffset:], uint16(len(packet)))
	source := netip.MustParseAddr("1.1.1.1").As4()
	destination := localAddress.As4()
	copy(packet[sourceOffset:], source[:])
	copy(packet[destinationOffset:], destination[:])
	copy(packet[ipv4.HeaderLen:], payload)
	return packet
}

func TestRepliesAreInjectedUnchangedWithoutOutboundSender(t *testing.T) {
	localAddress := netip.MustParseAddr("192.0.2.1")
	for _, protocol := range []byte{ICMP, TCP} {
		device := &replyTestDevice{packet: ipv4ReplyPacket(protocol, localAddress)}
		err := readPackets(device, nil, nil, localAddress, netip.Addr{})
		if !errors.Is(err, io.EOF) {
			t.Fatalf("reading packet: %v", err)
		}

		if device.writeCount != 1 || !bytes.Equal(device.written, device.packet) {
			t.Fatalf("reply was modified or padded: writes = %d, got %x, want %x", device.writeCount, device.written, device.packet)
		}
	}
}

func TestReplyInjectionReportsWriteFailures(t *testing.T) {
	localAddress := netip.MustParseAddr("192.0.2.1")
	wantErr := errors.New("TUN write failed")
	device := &replyTestDevice{packet: ipv4ReplyPacket(ICMP, localAddress), writeError: wantErr}
	if err := readPackets(device, nil, nil, localAddress, netip.Addr{}); !errors.Is(err, wantErr) {
		t.Fatalf("error = %v, want %v", err, wantErr)
	}

	device = &replyTestDevice{packet: ipv4ReplyPacket(ICMP, localAddress), shortWrite: true}
	if err := readPackets(device, nil, nil, localAddress, netip.Addr{}); !errors.Is(err, io.ErrShortWrite) {
		t.Fatalf("error = %v, want %v", err, io.ErrShortWrite)
	}
}
