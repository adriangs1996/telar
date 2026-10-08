package main

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"strconv"
	"strings"
)

const (
	darwinRouteCommand    = "/sbin/route"
	darwinIfconfigCommand = "/sbin/ifconfig"
	ipv4HostNetmask       = "255.255.255.255"
	darwinPFCommand       = "/sbin/pfctl"
	darwinPFAnchorPrefix  = "com.apple/telar-proxy-"
)

func darwinNATRules(config networkConfig) string {
	destination := "any"
	if !config.captureAll {
		destination = config.destination.String()
	}

	family := "inet"
	if config.localAddress.Is6() {
		family = "inet6"
	}

	tag := strconv.Quote("telar_proxy_" + strconv.Itoa(os.Getpid()) + "_" + config.family())
	rules := fmt.Sprintf(`nat on %[1]s %[2]s from %[3]s to %[4]s tag %[5]s -> %[6]s
pass out quick on %[7]s %[2]s from %[3]s to %[4]s no state
pass quick on %[7]s %[2]s to %[3]s no state
pass out quick on %[1]s reply-to (%[7]s %[8]s) %[2]s from %[6]s to %[4]s tagged %[5]s keep state (if-bound)
`, strconv.Quote(config.outboundInterface), family, config.localAddress, destination, tag, config.sourceAddress,
		strconv.Quote(config.interfaceName), config.peerAddress)
	if config.localAddress.Is6() {
		routeTo := strconv.Quote(config.outboundInterface)
		if config.outboundGateway.IsValid() {
			// Keep a link-local gateway's zone: PF's refragmented route-to path
			// needs the interface scope already encoded in the pool address.
			routeTo = fmt.Sprintf("(%s %s)", routeTo, config.outboundGateway)
		}
		rules += fmt.Sprintf("pass in quick on %s route-to %s inet6 from %s to %s no state\n",
			strconv.Quote(config.egressInterface), routeTo, config.localAddress, destination)
	}

	if config.localAddress.Is6() {
		// NAT requires a complete transport header before rewriting fragmented flows.
		// Reassembly/refragmentation remains in PF rather than in the Go relay.
		rules = fmt.Sprintf("scrub in on %s inet6 from %s to %s fragment reassemble\nscrub in on %s inet6 from %s to %s fragment reassemble\n",
			strconv.Quote(config.egressInterface), config.localAddress, destination,
			strconv.Quote(config.outboundInterface), destination, config.sourceAddress) + rules
	}

	return rules
}

func parsePFToken(output string) (string, error) {
	for _, line := range strings.Split(output, "\n") {
		key, value, found := strings.Cut(line, ":")
		if found && strings.TrimSpace(key) == "Token" {
			token := strings.TrimSpace(value)
			if value, err := strconv.ParseUint(token, 10, 64); err == nil && value != 0 {
				return token, nil
			}
		}
	}

	return "", errors.New("pfctl did not return a valid enable reference token")
}

func darwinPFEnableChange(run networkCommandRunner) networkChange {
	var token string
	return networkChange{
		apply: func() error {
			output, err := run(darwinPFCommand, "-E")
			if err != nil {
				return err
			}

			token, err = parsePFToken(output)
			return err
		},
		undo: func() error {
			_, err := run(darwinPFCommand, "-X", token)
			return err
		},
	}
}

func checkDarwinPFAnchors(run networkCommandRunner) error {
	for _, hook := range []struct{ selector, rule string }{
		{"nat", `nat-anchor "com.apple/*"`},
		{"rules", `anchor "com.apple/*"`},
		{"rules", `scrub-anchor "com.apple/*"`},
	} {
		output, err := run(darwinPFCommand, "-s", hook.selector)
		if err != nil {
			return err
		}

		found := false
		for line := range strings.SplitSeq(output, "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), hook.rule+" ") || strings.TrimSpace(line) == hook.rule {
				found = true
			}
		}

		if !found {
			return fmt.Errorf("PF main ruleset must include %s; refusing to replace system rules", hook.rule)
		}
	}

	return nil
}

func parseDarwinRoute(output string) (map[string]string, error) {
	fields := make(map[string]string)
	for line := range strings.SplitSeq(output, "\n") {
		key, value, found := strings.Cut(line, ":")
		if found {
			fields[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}

	if fields["interface"] == "" || fields["destination"] == "" {
		return nil, errors.New("route output has no interface or destination")
	}

	return fields, nil
}

func findOutboundRouteForFamily(destination netip.Addr, family string) (outboundRoute, error) {
	target := "default"
	if destination.IsValid() {
		target = destination.String()
	}

	output, err := runNetworkCommand(darwinRouteCommand, "-n", "get", "-inet"+strings.TrimPrefix(family, "4"), target)
	if err != nil {
		if !destination.IsValid() && (strings.Contains(err.Error(), "not in table") || strings.Contains(err.Error(), "not found") || strings.Contains(err.Error(), "No route to host")) {
			return outboundRoute{}, errNoDefaultRoute
		}

		return outboundRoute{}, err
	}

	fields, err := parseDarwinRoute(output)
	if err != nil {
		return outboundRoute{}, err
	}

	var source netip.Addr
	if family == "6" {
		source, err = interfaceIPv6(fields["interface"])
	} else {
		source, err = interfaceIPv4(fields["interface"])
	}
	if err != nil {
		return outboundRoute{}, err
	}

	gateway, gatewayErr := netip.ParseAddr(fields["gateway"])
	hasGateway := strings.Contains(","+strings.Trim(fields["flags"], "<>")+",", ",GATEWAY,")
	if hasGateway && (gatewayErr != nil || (family == "4") != gateway.Is4() || (!gateway.IsGlobalUnicast() && (family != "6" || !gateway.IsLinkLocalUnicast()))) {
		return outboundRoute{}, errors.New("outbound route has an invalid IP gateway")
	}
	if !hasGateway {
		gateway = netip.Addr{}
	}

	return outboundRoute{interfaceName: fields["interface"], sourceAddress: source, gatewayAddress: gateway}, nil
}

func parseDarwinRoutePrefix(fields map[string]string) (netip.Prefix, error) {
	destination := fields["destination"]
	if destination == "default" {
		destination = "0.0.0.0"
	}

	address, err := netip.ParseAddr(destination)
	if err != nil {
		return netip.Prefix{}, errors.New("route has an invalid IP destination")
	}

	if strings.Contains(","+strings.Trim(fields["flags"], "<>")+",", ",HOST,") {
		return netip.PrefixFrom(address, address.BitLen()), nil
	}

	mask := fields["mask"]
	if mask == "default" {
		mask = "0.0.0.0"
		if address.Is6() {
			mask = "::"
		}
	}
	maskAddress, err := netip.ParseAddr(mask)
	if err != nil || maskAddress.BitLen() != address.BitLen() {
		return netip.Prefix{}, errors.New("route has an invalid IP mask")
	}
	bits, size := net.IPMask(maskAddress.AsSlice()).Size()
	if size != address.BitLen() {
		return netip.Prefix{}, errors.New("route has a non-contiguous IP mask")
	}

	return netip.PrefixFrom(address, bits).Masked(), nil
}

func darwinCaptureRouteChange(config networkConfig, prefix netip.Prefix, scoped bool, run networkCommandRunner) networkChange {
	selector := "-net"
	destination := prefix.String()
	if prefix.Bits() == prefix.Addr().BitLen() {
		selector = "-host"
		destination = prefix.Addr().String()
	}

	interfaceName := config.interfaceName
	gatewayArgs := []string{"-interface", interfaceName}
	if scoped {
		interfaceName = config.outboundInterface
		gatewayArgs = []string{"-interface", interfaceName}
		if config.outboundGateway.IsValid() {
			gatewayArgs = []string{config.outboundGateway.String()}
		}

		gatewayArgs = append(gatewayArgs, "-ifscope", interfaceName)
	}

	family := "-inet"
	if config.localAddress.Is6() {
		family = "-inet6"
	}

	applyArgs := append([]string{"-n", "add", family, selector, destination}, gatewayArgs...)
	applyArgs = append(applyArgs, "-proto1")
	undoArgs := append([]string{"-n", "delete", family, selector, destination}, gatewayArgs...)
	change := commandChange(run, darwinRouteCommand, applyArgs, undoArgs)
	deleteRoute := change.undo
	change.undo = func() error {
		probe := prefix.Addr()
		if prefix.Bits() != prefix.Addr().BitLen() {
			probe = probe.Next()
			if prefix == netip.MustParsePrefix(ipv6LowerHalf) {
				probe = netip.MustParseAddr("4000::1")
			}
		}

		queryArgs := []string{"-n", "get", family, probe.String()}
		if scoped {
			queryArgs = append(queryArgs, "-ifscope", interfaceName)
		}

		output, err := run(darwinRouteCommand, queryArgs...)
		if err != nil {
			return err
		}

		fields, err := parseDarwinRoute(output)
		if err != nil {
			return err
		}

		if fields["interface"] != interfaceName {
			return nil
		}
		if scoped && config.outboundGateway.IsValid() && fields["gateway"] != config.outboundGateway.String() {
			return nil
		}

		currentPrefix, err := parseDarwinRoutePrefix(fields)
		if err != nil {
			return err
		}

		if currentPrefix != prefix {
			return nil
		}

		if !strings.Contains(","+strings.Trim(fields["flags"], "<>")+",", ",PROTO1,") {
			return fmt.Errorf("refusing to remove an unowned route to %s", prefix)
		}

		return deleteRoute()
	}

	return change
}

func configureNetwork(config networkConfig) (func() error, error) {
	return configureNetworkWithRunner(config, runNetworkCommand)
}

func configureNetworkWithRunner(config networkConfig, run networkCommandRunner) (func() error, error) {
	if err := validateNetworkConfig(config); err != nil {
		return nil, err
	}

	if err := checkDarwinPFAnchors(run); err != nil {
		return nil, err
	}

	anchor := darwinPFAnchorPrefix + strconv.Itoa(os.Getpid())
	if config.localAddress.Is6() {
		anchor += "-6"
		if config.egressInterface == "" || config.egressInterface == config.interfaceName {
			return nil, errors.New("IPv6 forwarding requires a separate egress TUN")
		}
	}
	rulesFile, err := writeNetworkRules(darwinNATRules(config))
	if err != nil {
		return nil, err
	}
	defer os.Remove(rulesFile)

	// Parse the anchor before changing addresses, PF references or routes.
	if _, err := run(darwinPFCommand, "-n", "-a", anchor, "-f", rulesFile); err != nil {
		return nil, err
	}

	nat := networkChange{
		apply: func() error {
			_, err := run(darwinPFCommand, "-a", anchor, "-f", rulesFile)
			return err
		},
		undo: func() error {
			_, rulesErr := run(darwinPFCommand, "-a", anchor, "-F", "rules")
			_, natErr := run(darwinPFCommand, "-a", anchor, "-F", "nat")
			args := []string{"-k", config.localAddress.String()}
			if !config.captureAll {
				args = append(args, "-k", config.destination.String())
			}
			_, statesErr := run(darwinPFCommand, args...)
			return errors.Join(rulesErr, natErr, statesErr)
		},
	}

	address := commandChange(run, darwinIfconfigCommand,
		[]string{config.interfaceName, "inet", config.localAddress.String(), config.peerAddress.String(), "netmask", ipv4HostNetmask, "alias"},
		[]string{config.interfaceName, "inet", config.localAddress.String(), "-alias"},
	)
	if config.localAddress.Is6() {
		address = commandChange(run, darwinIfconfigCommand,
			[]string{config.interfaceName, "inet6", config.localAddress.String(), "prefixlen", "128", "alias", "-dad"},
			[]string{config.interfaceName, "inet6", config.localAddress.String(), "-alias"},
		)
	}

	link := commandChange(run, darwinIfconfigCommand,
		[]string{config.interfaceName, "up"},
		[]string{config.interfaceName, "down"},
	)
	if config.localAddress.Is6() {
		link.undo = func() error { return nil }
	}

	changes := []networkChange{address, link, darwinPFEnableChange(run), nat}
	if config.localAddress.Is6() {
		changes = append(changes, commandChange(run, darwinIfconfigCommand,
			[]string{config.egressInterface, "inet6", "fe80::1", "prefixlen", "64", "alias", "-dad"},
			[]string{config.egressInterface, "inet6", "fe80::1", "-alias"},
		))
		changes = append(changes, commandChange(run, darwinIfconfigCommand,
			[]string{config.egressInterface, "up"},
			[]string{config.egressInterface, "down"},
		))
	}
	if config.captureAll {
		// Bound raw sockets need equally specific routes within their original
		// interface's scope; the unscoped capture routes remain on the TUN.
		for _, prefix := range config.capturePrefixes() {
			changes = append(changes, darwinCaptureRouteChange(config, prefix, true, run))
		}
	}

	for _, prefix := range config.capturePrefixes() {
		changes = append(changes, darwinCaptureRouteChange(config, prefix, false, run))
	}

	return applyNetworkChanges(changes)
}
