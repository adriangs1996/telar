package main

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"

	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

type tcpReplyWriter struct {
	packets chan []byte
	err     error
}

func (self *tcpReplyWriter) Write(buffers [][]byte, offset int) (int, error) {
	if self.err != nil {
		return 0, self.err
	}
	self.packets <- append([]byte(nil), buffers[0][offset:]...)
	return (&replyTestDevice{}).Write(buffers, offset)
}

func TestTCPAdapterWritesCompletePacketWithoutReservedHeadroom(t *testing.T) {
	adapter, err := NewTCPAdapter(context.Background(), &TcpHandler{})
	if err != nil {
		t.Fatal(err)
	}
	defer adapter.Close()

	payload := []byte("TCP response")
	packet := stack.NewPacketBuffer(stack.PacketBufferOptions{
		ReserveHeaderBytes: 64,
		Payload:            buffer.MakeWithData(payload),
	})
	transport := packet.TransportHeader().Push(20)
	copy(transport, bytes.Repeat([]byte{6}, len(transport)))
	network := packet.NetworkHeader().Push(40)
	copy(network, bytes.Repeat([]byte{0x60}, len(network)))
	want := append(append(append([]byte(nil), network...), transport...), payload...)
	var packets stack.PacketBufferList
	packets.PushBack(packet)
	_, queueErr := adapter.link.WritePackets(packets)
	packet.DecRef()
	if queueErr != nil {
		t.Fatal(queueErr)
	}

	writer := &tcpReplyWriter{packets: make(chan []byte, 1)}
	done := make(chan error, 1)
	go func() { done <- adapter.WriteReplies(writer) }()
	select {
	case got := <-writer.packets:
		if !bytes.Equal(got, want) {
			t.Fatalf("TCP reply changed: got %x, want %x", got, want)
		}
	case <-time.After(tcpTestTimeout):
		t.Fatal("no TCP reply delivered")
	}
	adapter.Close()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestTCPAdapterReportsTunnelWriteFailure(t *testing.T) {
	adapter, err := NewTCPAdapter(context.Background(), &TcpHandler{})
	if err != nil {
		t.Fatal(err)
	}
	defer adapter.Close()
	packet := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData([]byte{0x45})})
	var packets stack.PacketBufferList
	packets.PushBack(packet)
	_, queueErr := adapter.link.WritePackets(packets)
	packet.DecRef()
	if queueErr != nil {
		t.Fatal(queueErr)
	}

	wantErr := errors.New("TUN write failed")
	if err := adapter.WriteReplies(&tcpReplyWriter{err: wantErr}); !errors.Is(err, wantErr) {
		t.Fatalf("writer error = %v, want %v", err, wantErr)
	}
}
