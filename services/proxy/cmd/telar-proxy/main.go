package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/netip"
	"os"
	"os/signal"
	"runtime"
	"syscall"

	"golang.org/x/net/ipv4"
	"golang.org/x/net/ipv6"
	"golang.zx2c4.com/wireguard/tun"
)

const tunnelMTU = 1500

const (
	// Linux's TUN writer needs a 10-byte virtio header; macOS uses the last four.
	packetOffset     = 10
	packetBufferSize = 65535
)

// Packet's structure offsets
const (
	// IPv4
	protocolOffset    = 9
	sourceOffset      = 12
	destinationOffset = 16
	// IPv6
	protocolIPv6Offset    = 6
	sourceIPv6Offset      = 8
	destinationIPv6Offset = 24
)

// Protocol Constants
const (
	ICMP   = 1
	TCP    = 6
	ICMPv6 = 58
	UDP    = 17
)

func protocolName(protocol byte) string {
	switch protocol {
	case ICMP:
		return "ICMP"
	case TCP:
		return "TCP"
	case ICMPv6:
		return "ICMPv6"
	case UDP:
		return "UDP"
	}

	return "UNKNOWN"
}

func toIPString(address []byte) string {
	if len(address) == 4 {
		return fmt.Sprintf("%d.%d.%d.%d", address[0], address[1], address[2], address[3])
	}

	return fmt.Sprintf(
		"%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x",
		address[0],
		address[1],
		address[2],
		address[3],
		address[4],
		address[5],
		address[6],
		address[7],
		address[8],
		address[9],
		address[10],
		address[11],
		address[12],
		address[13],
		address[14],
		address[15],
	)
}

type packetRelay struct {
	sender        *ipv4.RawConn
	sender6       ipv6Sender
	localAddress  netip.Addr
	localAddress6 netip.Addr
	tcp           *TcpAdapter
	fragments     ipv6FragmentDispatcher
}

func readPackets(device tun.Device, relay *packetRelay) error {
	buffers := make([][]byte, device.BatchSize())
	sizes := make([]int, len(buffers))

	for i := range buffers {
		buffers[i] = make([]byte, packetOffset+packetBufferSize)
	}

	for {
		count, err := device.Read(buffers, sizes, packetOffset)
		if err != nil {
			return err
		}

		for i := range count {
			packet := buffers[i][packetOffset : packetOffset+sizes[i]]

			if len(packet) == 0 {
				continue
			}

			var (
				source      []byte
				destination []byte
				protocol    byte
			)

			version := packet[0] >> 4

			if version != 4 && version != 6 {
				return errors.New("invalid version")
			}

			switch version {
			case 4:
				if len(packet) < ipv4.HeaderLen {
					log.Printf("Dropping truncated IPv4 packet: %d bytes", len(packet))
					continue
				}

				source = packet[sourceOffset : sourceOffset+4]
				destination = packet[destinationOffset : destinationOffset+4]
			case 6:
				if len(packet) < ipv6.HeaderLen {
					log.Printf("Dropping truncated IPv6 packet: %d bytes", len(packet))
					continue
				}

				source = packet[sourceIPv6Offset : sourceIPv6Offset+16]
				destination = packet[destinationIPv6Offset : destinationIPv6Offset+16]
			}

			info, err := packetProtocol(packet)
			if err != nil {
				log.Printf("Dropping IPv%d packet: %v", version, err)
				continue
			}
			protocol = info.protocol

			log.Printf(
				"Received IPv%d packet: %d bytes protocol=%s source=%s destination=%s ",
				version,
				sizes[i],
				protocolName(protocol),
				toIPString(source),
				toIPString(destination),
			)

			destinationAddress, _ := netip.AddrFromSlice(destination)
			frame := buffers[i][:packetOffset+sizes[i]]
			if destinationAddress == relay.localAddress || destinationAddress == relay.localAddress6 {
				// PF has already undone NAT and routed the response into the TUN.
				// Inject it as received on the interface owning the temporary address.
				if err := writeTunnelPacket(device, frame); err != nil {
					return fmt.Errorf("injecting IPv%d reply: %w", version, err)
				}

				log.Printf("Delivered IPv%d reply to kernel: %d bytes", version, sizes[i])
				continue
			}

			// Link-local and multicast IPv6 control traffic belongs to the TUN itself.
			if version == ipv6.Version && !destinationAddress.IsGlobalUnicast() {
				continue
			}

			forwardErr := relay.fragments.dispatch(info, frame, relay.forwardProtocol)
			if forwardErr != nil {
				log.Printf("Forwarding IPv%d: %v", version, forwardErr)
			}

		}
	}
}

func (self *packetRelay) forwardProtocol(frame []byte, protocol byte) error {
	packet := frame[packetOffset:]
	if protocol == TCP && self.tcp != nil {
		self.tcp.Inject(packet)
		return nil
	}
	if packet[0]>>ipv4VersionShift == ipv4.Version && self.sender != nil {
		return forwardIPv4(self.sender, packet)
	}
	if packet[0]>>ipv4VersionShift == ipv6.Version {
		return forwardIPv6(self.sender6, frame)
	}

	return nil
}

func run(ctx context.Context, config networkConfig, inspector *TLSInspector) (resultErr error) {
	configs, err := discoverNetworkConfigs(config)
	if err != nil {
		return err
	}

	requestedName := "teltun1"
	if runtime.GOOS == "darwin" {
		requestedName = "utun"
	}
	for i := range configs {
		configs[i].interfaceName = requestedName
		if err := validateNetworkConfig(configs[i]); err != nil {
			return err
		}
	}

	if ctx.Err() != nil {
		return nil
	}

	device, err := tun.CreateTUN(requestedName, tunnelMTU)
	if err != nil {
		return fmt.Errorf("creating TUN: %w", err)
	}
	defer device.Close()

	actualName, err := device.Name()
	if err != nil {
		return fmt.Errorf("reading TUN name: %w", err)
	}
	log.Printf("Created TUN interface %s", actualName)

	var sender *ipv4.RawConn
	var sender6 ipv6Sender
	var localAddress, localAddress6 netip.Addr
	for i := range configs {
		configs[i].interfaceName = actualName
		if configs[i].localAddress.Is4() {
			sender, err = openIPv4Sender(configs[i].outboundInterface)
			if err == nil {
				defer sender.Close()
			}
			localAddress = configs[i].localAddress
		} else {
			sender6, err = openIPv6Sender(configs[i].outboundInterface)
			if err == nil {
				defer sender6.Close()
				configs[i].egressInterface = sender6.InterfaceName()
			}
			localAddress6 = configs[i].localAddress
		}
		if err != nil {
			return fmt.Errorf("opening IPv%s outbound sender: %w", configs[i].family(), err)
		}

		log.Printf("Opened outbound IPv%s sender on %s, source %s", configs[i].family(), configs[i].outboundInterface, configs[i].sourceAddress)
	}

	handler := &TcpHandler{tls: inspector}
	for _, candidate := range configs {
		if candidate.localAddress.Is4() {
			handler.interface4 = candidate.outboundInterface
		} else {
			handler.interface6 = candidate.outboundInterface
		}
	}
	adapter, err := NewTCPAdapter(ctx, handler)
	if err != nil {
		return fmt.Errorf("creating TCP adapter: %w", err)
	}
	defer adapter.Close()
	relay := &packetRelay{
		sender:        sender,
		sender6:       sender6,
		localAddress:  localAddress,
		localAddress6: localAddress6,
		tcp:           adapter,
	}

	// Each family owns its addresses, firewall state and routes. If the second
	// activation fails, unwind both without publishing partial capture as active.
	changes := make([]networkChange, len(configs))
	for i, candidate := range configs {
		var undo func() error
		changes[i] = networkChange{
			apply: func() error {
				var err error
				undo, err = configureNetwork(candidate)
				return err
			},
			undo: func() error { return undo() },
		}
	}
	cleanup, err := applyNetworkChanges(changes)
	if err != nil {
		return fmt.Errorf("configuring network: %w", err)
	}
	cleanupCalled := false
	defer func() {
		if !cleanupCalled {
			resultErr = errors.Join(resultErr, cleanup())
		}
	}()

	for _, candidate := range configs {
		if candidate.captureAll {
			prefixes := candidate.capturePrefixes()
			log.Printf("IPv%s capture active: %s and %s through %s", candidate.family(), prefixes[0], prefixes[1], actualName)
		} else {
			log.Printf("Test route active: %s through %s", candidate.destination, actualName)
		}
	}
	log.Printf("Capture ready")

	readDone := make(chan error, 1)
	writeDone := make(chan error, 1)
	go func() {
		readDone <- readPackets(device, relay)
	}()
	go func() {
		writeDone <- adapter.WriteReplies(device)
	}()

	var workerErr error
	readFinished, writeFinished := false, false
	select {
	case <-ctx.Done():
	case err := <-readDone:
		readFinished = true
		workerErr = fmt.Errorf("reading TUN: %w", err)
	case err := <-writeDone:
		writeFinished = true
		workerErr = err
	}

	// Withdraw capture before closing the TUN, then join both packet workers
	// and the TCP callbacks before releasing the remaining network resources.
	cleanupCalled = true
	cleanupErr := cleanup()
	closeErr := device.Close()
	adapter.Close()
	if !readFinished {
		<-readDone
	}
	if !writeFinished {
		<-writeDone
	}
	if ctx.Err() != nil {
		workerErr = nil
	}

	return errors.Join(workerErr, cleanupErr, closeErr)
}

func main() {
	// Losing a piped log consumer must not terminate the process before cleanup.
	signal.Ignore(syscall.SIGPIPE)

	captureAll := flag.Bool("all", false, "capture default-routed IPv4 and IPv6 traffic; preserve more-specific routes and interface-bound bypass")
	destination := flag.String("route", "", "IP destination to capture for the forwarding test")
	localAddress := flag.String("tun-address", "192.0.2.1", "local IPv4 address for the test TUN")
	peerAddress := flag.String("tun-peer", "192.0.2.2", "peer IPv4 address for the test TUN")
	localAddress6 := flag.String("tun-address6", defaultTunnelIPv6, "local IPv6 address for the TUN")
	peerAddress6 := flag.String("tun-peer6", defaultPeerIPv6, "peer IPv6 address for the TUN")
	var tlsConfig tlsOptions
	flag.Func("inspect-host", "TLS inspection hostname, *.suffix or *; may be repeated", func(host string) error {
		if len(tlsConfig.hosts) == tlsMaxHostRules {
			return fmt.Errorf("at most %d TLS host rules are supported", tlsMaxHostRules)
		}
		tlsConfig.hosts = append(tlsConfig.hosts, host)
		return nil
	})
	flag.StringVar(&tlsConfig.certificate, "tls-ca-cert", "", "existing TLS inspection CA certificate in PEM format")
	flag.StringVar(&tlsConfig.key, "tls-ca-key", "", "existing TLS inspection CA private key in PEM format; mode 0600 or stricter")
	flag.StringVar(&tlsConfig.upstreamBundle, "tls-upstream-ca", "", "optional additional trusted origin certificates in PEM format")
	flag.Parse()
	inspector, err := loadTLSInspector(tlsConfig)
	if err != nil {
		log.Print(err)
		os.Exit(1)
	}

	local4, localErr := netip.ParseAddr(*localAddress)
	peer4, peerErr := netip.ParseAddr(*peerAddress)
	if localErr != nil || peerErr != nil || !local4.Is4() || !peer4.Is4() || !local4.IsGlobalUnicast() || !peer4.IsGlobalUnicast() || local4 == peer4 {
		log.Print("-tun-address and -tun-peer must be distinct unicast IPv4 addresses")
		os.Exit(1)
	}

	routeAddress, _ := netip.ParseAddr(*destination)
	if routeAddress.Is6() {
		localAddress = localAddress6
		peerAddress = peerAddress6
	}

	config, err := parseNetworkConfig(*captureAll, *destination, *localAddress, *peerAddress)
	if err != nil {
		log.Print(err)
		os.Exit(1)
	}

	config.ipv6LocalAddress, err = netip.ParseAddr(*localAddress6)
	if err != nil || !config.ipv6LocalAddress.Is6() || !config.ipv6LocalAddress.IsGlobalUnicast() || config.ipv6LocalAddress.Is4In6() {
		log.Print("-tun-address6 must be a unicast IPv6 address")
		os.Exit(1)
	}
	config.ipv6PeerAddress, err = netip.ParseAddr(*peerAddress6)
	if err != nil || !config.ipv6PeerAddress.Is6() || !config.ipv6PeerAddress.IsGlobalUnicast() || config.ipv6PeerAddress.Is4In6() || config.ipv6PeerAddress == config.ipv6LocalAddress {
		log.Print("-tun-peer6 must be a distinct unicast IPv6 address")
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := run(ctx, config, inspector); err != nil {
		log.Print(err)
		os.Exit(1)
	}
}
