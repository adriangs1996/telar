package main

import (
	"context"
	"fmt"
	"log"
	"net/netip"
	"sync"
	"time"

	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/waiter"
)

const (
	tcpPacketQueueSize      = 256
	tcpMaxConnections       = 256
	tcpDefaultReceiveWindow = 0
	tcpShutdownPollInterval = 10 * time.Millisecond
)

type TcpAdapter struct {
	stack     *stack.Stack
	link      *channel.Endpoint
	nicID     tcpip.NICID
	handler   *TcpHandler
	ctx       context.Context
	cancel    context.CancelFunc
	slots     chan struct{}
	mu        sync.Mutex
	closed    bool
	callbacks sync.WaitGroup
	closeOnce sync.Once
}

func NewTCPAdapter(ctx context.Context, handler *TcpHandler) (*TcpAdapter, error) {
	ctx, cancel := context.WithCancel(ctx)
	adapter := &TcpAdapter{
		stack: stack.New(stack.Options{
			NetworkProtocols: []stack.NetworkProtocolFactory{
				ipv4.NewProtocol,
				ipv6.NewProtocol,
			},
			TransportProtocols: []stack.TransportProtocolFactory{
				tcp.NewProtocol,
			},
		}),
		link:    channel.New(tcpPacketQueueSize, tunnelMTU, ""),
		handler: handler,
		ctx:     ctx,
		cancel:  cancel,
		slots:   make(chan struct{}, tcpMaxConnections),
	}

	forwarder := tcp.NewForwarder(adapter.stack, tcpDefaultReceiveWindow, tcpMaxConnections, adapter.accept)
	adapter.stack.SetTransportProtocolHandler(tcp.ProtocolNumber, forwarder.HandlePacket)
	adapter.nicID = adapter.stack.NextNICID()
	if err := adapter.configureNIC(); err != nil {
		adapter.Close()
		return nil, err
	}

	return adapter, nil
}

func (self *TcpAdapter) configureNIC() error {
	if err := self.stack.CreateNIC(self.nicID, self.link); err != nil {
		return fmt.Errorf("registering TCP adapter interface: %s", err)
	}

	if err := self.stack.SetPromiscuousMode(self.nicID, true); err != nil {
		return fmt.Errorf("enabling promiscuous mode: %s", err)
	}

	if err := self.stack.SetSpoofing(self.nicID, true); err != nil {
		return fmt.Errorf("enabling address spoofing: %s", err)
	}

	self.stack.SetRouteTable([]tcpip.Route{
		{Destination: header.IPv4EmptySubnet, NIC: self.nicID},
		{Destination: header.IPv6EmptySubnet, NIC: self.nicID},
	})

	return nil
}

func (self *TcpAdapter) accept(request *tcp.ForwarderRequest) {
	self.mu.Lock()
	if self.closed || self.ctx.Err() != nil {
		self.mu.Unlock()
		request.Complete(true)
		return
	}
	select {
	case self.slots <- struct{}{}:
		self.callbacks.Add(1)
	default:
		self.mu.Unlock()
		request.Complete(true)
		return
	}
	self.mu.Unlock()
	defer self.callbacks.Done()
	defer func() { <-self.slots }()

	id := request.ID()
	address, valid := netip.AddrFromSlice(id.LocalAddress.AsSlice())
	if !valid {
		request.Complete(true)
		return
	}
	destination := netip.AddrPortFrom(address, id.LocalPort)
	upstream, err := self.handler.Connect(self.ctx, destination)
	if err != nil {
		request.Complete(true)
		if self.ctx.Err() == nil {
			log.Printf("Connecting TCP %s: %v", destination, err)
		}
		return
	}
	defer upstream.Close()

	if self.ctx.Err() != nil {
		request.Complete(true)
		return
	}

	var queue waiter.Queue
	endpoint, endpointErr := request.CreateEndpoint(&queue)
	request.Complete(endpointErr != nil)
	if endpointErr != nil {
		if self.ctx.Err() == nil {
			log.Printf("Accepting TCP %s: %s", destination, endpointErr)
		}
		return
	}
	client := gonet.NewTCPConn(&queue, endpoint)
	log.Printf("Relaying TCP %s to %s through %s", client.RemoteAddr(), destination, upstream.LocalAddr())
	if err := self.handler.Relay(self.ctx, client, upstream, destination.Addr()); err != nil && self.ctx.Err() == nil {
		log.Printf("Relaying TCP %s: %v", destination, err)
	}
}

func (self *TcpAdapter) Inject(packet []byte) {
	self.mu.Lock()
	defer self.mu.Unlock()
	if self.closed || self.ctx.Err() != nil {
		return
	}

	protocol := ipv4.ProtocolNumber
	if packet[0]>>ipv4VersionShift == header.IPv6Version {
		protocol = ipv6.ProtocolNumber
	}
	// MakeWithData copies the bytes: the TUN reader reuses its input buffers.
	owned := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(packet)})
	defer owned.DecRef()
	self.link.InjectInbound(protocol, owned)
}

func (self *TcpAdapter) WriteReplies(device packetWriter) error {
	frame := make([]byte, packetOffset+packetBufferSize)
	for {
		packet := self.link.ReadContext(self.ctx)
		if packet == nil {
			return nil
		}

		length := packet.Size()
		if length > packetBufferSize {
			packet.DecRef()
			return fmt.Errorf("TCP reply exceeds packet buffer: %d bytes", length)
		}
		views, skip := packet.AsViewList()
		written := packetOffset
		for view := views.Front(); view != nil; view = view.Next() {
			data := view.AsSlice()
			if skip >= len(data) {
				skip -= len(data)
				continue
			}

			written += copy(frame[written:], data[skip:])
			skip = 0
		}
		packet.DecRef()
		if err := writeTunnelPacket(device, frame[:packetOffset+length]); err != nil {
			return fmt.Errorf("injecting TCP reply: %w", err)
		}
	}
}

func (self *TcpAdapter) Close() {
	self.closeOnce.Do(func() {
		self.mu.Lock()
		self.closed = true
		self.cancel()
		self.mu.Unlock()

		done := make(chan struct{})
		go func() {
			self.callbacks.Wait()
			close(done)
		}()
		ticker := time.NewTicker(tcpShutdownPollInterval)
		defer ticker.Stop()
		// CreateEndpoint can be between route lookup and endpoint registration
		// when shutdown starts. Abort newly registered handshakes until all
		// admitted callbacks have finished, then stop the stack's workers.
		for {
			for _, endpoint := range self.stack.RegisteredEndpoints() {
				endpoint.Abort()
			}
			select {
			case <-done:
				self.link.Close()
				self.stack.Close()
				self.stack.Wait()
				return
			case <-ticker.C:
			}
		}
	})
}
