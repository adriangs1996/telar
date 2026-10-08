package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const networkCommandTimeout = 5 * time.Second

const (
	ipv4LowerHalf     = "0.0.0.0/1"
	ipv4UpperHalf     = "128.0.0.0/1"
	ipv6LowerHalf     = "::/1"
	ipv6UpperHalf     = "8000::/1"
	defaultTunnelIPv6 = "fd7a:115c:a1e0:7465::1"
	defaultPeerIPv6   = "fd7a:115c:a1e0:7465::2"
)

type networkConfig struct {
	captureAll        bool
	ipv6LocalAddress  netip.Addr
	ipv6PeerAddress   netip.Addr
	interfaceName     string
	outboundInterface string
	egressInterface   string
	outboundGateway   netip.Addr
	localAddress      netip.Addr
	peerAddress       netip.Addr
	destination       netip.Addr
	sourceAddress     netip.Addr
}

func parseNetworkConfig(captureAll bool, destination, localAddress, peerAddress string) (networkConfig, error) {
	config := networkConfig{captureAll: captureAll}
	if captureAll == (destination != "") {
		return networkConfig{}, errors.New("choose exactly one of -all or -route <IP>")
	}

	var err error
	if !captureAll {
		config.destination, err = netip.ParseAddr(destination)
		if err != nil || !config.destination.IsGlobalUnicast() || config.destination.Is4In6() {
			return networkConfig{}, errors.New("provide -route with a unicast IP test destination")
		}
	}

	config.localAddress, err = netip.ParseAddr(localAddress)
	if err != nil {
		return networkConfig{}, fmt.Errorf("invalid -tun-address: %w", err)
	}

	config.peerAddress, err = netip.ParseAddr(peerAddress)
	if err != nil {
		return networkConfig{}, fmt.Errorf("invalid -tun-peer: %w", err)
	}

	return config, nil
}

func (self networkConfig) capturePrefixes() []netip.Prefix {
	if self.captureAll && self.localAddress.Is6() {
		return []netip.Prefix{netip.MustParsePrefix(ipv6LowerHalf), netip.MustParsePrefix(ipv6UpperHalf)}
	}

	if self.captureAll {
		return []netip.Prefix{netip.MustParsePrefix(ipv4LowerHalf), netip.MustParsePrefix(ipv4UpperHalf)}
	}

	return []netip.Prefix{netip.PrefixFrom(self.destination, self.destination.BitLen())}
}

type outboundRoute struct {
	interfaceName  string
	sourceAddress  netip.Addr
	gatewayAddress netip.Addr
}

type networkCommandRunner func(name string, args ...string) (string, error)

type networkChange struct {
	apply func() error
	undo  func() error
}

func runNetworkCommand(name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), networkCommandTimeout)
	defer cancel()

	command := exec.CommandContext(ctx, name, args...)
	var stderr bytes.Buffer
	command.Stderr = &stderr
	output, err := command.Output()

	// Darwin's route can report failure on stderr while exiting with status 0.
	if err != nil || (filepath.Base(name) == "route" && stderr.Len() != 0) {
		if err == nil {
			err = errors.New(strings.TrimSpace(stderr.String()))
		} else if stderr.Len() != 0 {
			err = fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
		}

		return "", fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), err)
	}

	return string(output) + stderr.String(), nil
}

func writeNetworkRules(rules string) (string, error) {
	file, err := os.CreateTemp("", "telar-proxy-rules-*")
	if err != nil {
		return "", err
	}

	_, writeErr := file.WriteString(rules)
	closeErr := file.Close()
	if err := errors.Join(writeErr, closeErr); err != nil {
		os.Remove(file.Name())
		return "", err
	}

	return file.Name(), nil
}

func commandChange(run networkCommandRunner, name string, applyArgs, undoArgs []string) networkChange {
	return networkChange{
		apply: func() error {
			_, err := run(name, applyArgs...)
			return err
		},
		undo: func() error {
			_, err := run(name, undoArgs...)
			return err
		},
	}
}

// Only successful changes are owned by this activation. Undo them in reverse
// order on shutdown or partial failure, without restoring a system-wide snapshot.
func applyNetworkChanges(changes []networkChange) (func() error, error) {
	applied := 0
	closed := false
	var cleanupErr error

	cleanup := func() error {
		if closed {
			return cleanupErr
		}

		closed = true
		for i := applied - 1; i >= 0; i-- {
			cleanupErr = errors.Join(cleanupErr, changes[i].undo())
		}

		return cleanupErr
	}

	for _, change := range changes {
		if err := change.apply(); err != nil {
			return nil, errors.Join(err, cleanup())
		}

		applied++
	}

	return cleanup, nil
}

func validateNetworkConfig(config networkConfig) error {
	if config.interfaceName == "" || config.outboundInterface == "" || config.interfaceName == config.outboundInterface {
		return errors.New("expected distinct TUN and outbound interface names")
	}

	if config.captureAll && config.destination.IsValid() {
		return errors.New("-all cannot specify a destination")
	}

	addresses := []netip.Addr{config.localAddress, config.peerAddress, config.sourceAddress}
	if !config.captureAll {
		addresses = append(addresses, config.destination)
	}

	for _, address := range addresses {
		if !address.IsGlobalUnicast() || address.Is4In6() || address.BitLen() != config.localAddress.BitLen() {
			return fmt.Errorf("expected unicast addresses of the same IP family, got %s", address)
		}
	}

	for i, address := range addresses {
		for _, other := range addresses[i+1:] {
			if address == other {
				return fmt.Errorf("TUN, source and destination addresses must differ: %s", address)
			}
		}
	}

	return nil
}

func checkTunnelAddresses(localAddress, peerAddress netip.Addr) error {
	addresses, err := net.InterfaceAddrs()
	if err != nil {
		return err
	}

	for _, address := range addresses {
		prefix, err := netip.ParsePrefix(address.String())
		if err == nil && (prefix.Addr() == localAddress || prefix.Addr() == peerAddress) {
			return fmt.Errorf("TUN address %s is already assigned; choose -tun-address and -tun-peer for an unused pair", prefix.Addr())
		}
	}

	return nil
}

func interfaceIPv4(interfaceName string) (netip.Addr, error) {
	iface, err := net.InterfaceByName(interfaceName)
	if err != nil {
		return netip.Addr{}, err
	}

	addresses, err := iface.Addrs()
	if err != nil {
		return netip.Addr{}, err
	}

	var source netip.Addr
	for _, address := range addresses {
		prefix, err := netip.ParsePrefix(address.String())
		if err != nil || !prefix.Addr().Is4() || !prefix.Addr().IsGlobalUnicast() {
			continue
		}

		if source.IsValid() {
			return netip.Addr{}, fmt.Errorf("multiple IPv4 addresses on %s; source selection is ambiguous", interfaceName)
		}

		source = prefix.Addr()
	}

	if !source.IsValid() {
		return netip.Addr{}, fmt.Errorf("no unicast IPv4 address on %s", interfaceName)
	}

	return source, nil
}

func (self networkConfig) family() string {
	if self.localAddress.Is6() {
		return "6"
	}

	return "4"
}

var errNoDefaultRoute = errors.New("no default route")

func discoverNetworkConfigs(config networkConfig) ([]networkConfig, error) {
	candidates := []networkConfig{config}
	if config.captureAll {
		ipv6Config := config
		ipv6Config.localAddress = config.ipv6LocalAddress
		ipv6Config.peerAddress = config.ipv6PeerAddress
		candidates = append(candidates, ipv6Config)
	}

	var configs []networkConfig
	for _, candidate := range candidates {
		route, err := findOutboundRouteForFamily(candidate.destination, candidate.family())
		if candidate.captureAll && errors.Is(err, errNoDefaultRoute) {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("finding IPv%s outbound route: %w", candidate.family(), err)
		}

		candidate.sourceAddress = route.sourceAddress
		candidate.outboundInterface = route.interfaceName
		candidate.outboundGateway = route.gatewayAddress
		if err := checkTunnelAddresses(candidate.localAddress, candidate.peerAddress); err != nil {
			return nil, err
		}

		configs = append(configs, candidate)
	}

	if len(configs) == 0 {
		return nil, errNoDefaultRoute
	}

	return configs, nil
}
