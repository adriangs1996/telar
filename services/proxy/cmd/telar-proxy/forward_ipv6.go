package main

import (
	"encoding/binary"
	"errors"
	"io"

	"golang.org/x/net/ipv6"
)

const ipv6PayloadLengthOffset = 4

type ipv6Sender interface {
	Send(frame []byte) error
	Close() error
	InterfaceName() string
}

// Keep extension headers and transport bytes opaque. The sender receives the
// complete IPv6 packet, including the headroom required by macOS's TUN writer.
func forwardIPv6(sender ipv6Sender, frame []byte) error {
	if len(frame) < packetOffset+ipv6.HeaderLen {
		return errors.New("truncated IPv6 packet")
	}

	packet := frame[packetOffset:]
	if packet[0]>>ipv4VersionShift != ipv6.Version {
		return errors.New("invalid IPv6 version")
	}

	length := ipv6.HeaderLen + int(binary.BigEndian.Uint16(packet[ipv6PayloadLengthOffset:]))
	if length != len(packet) {
		return errors.New("invalid IPv6 payload length; jumbograms are unsupported")
	}

	if sender == nil {
		return errors.New("IPv6 forwarding is inactive")
	}

	return sender.Send(frame)
}

func writeTunnelPacket(device packetWriter, frame []byte) error {
	buffers := [1][]byte{frame}
	written, err := device.Write(buffers[:], packetOffset)
	if err != nil {
		return err
	}

	if !tunnelWriteComplete(written, frame) {
		return io.ErrShortWrite
	}

	return nil
}

type packetWriter interface {
	Write(buffers [][]byte, offset int) (int, error)
}
