package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"strconv"
	"strings"
)

const linuxIPCommand = "ip"

const (
	linuxNFTCommand             = "nft"
	linuxConntrackCommand       = "conntrack"
	linuxSysctlCommand          = "sysctl"
	linuxLooseReversePathFilter = "2"
)

func linuxNATRules(config networkConfig, table string) string {
	family := "ip"
	if config.localAddress.Is6() {
		family = "ip6"
	}

	destinationMatch := ""
	if !config.captureAll {
		destinationMatch = " " + family + " daddr " + config.destination.String()
	}

	return fmt.Sprintf(`create table %[1]s %[2]s
add chain %[1]s %[2]s before_capture { type filter hook output priority raw; policy accept; }
add rule %[1]s %[2]s before_capture oifname %[3]s %[1]s saddr %[4]s%[5]s counter notrack
add chain %[1]s %[2]s outbound_nat { type nat hook postrouting priority srcnat; policy accept; }
add rule %[1]s %[2]s outbound_nat oifname %[6]s %[1]s saddr %[4]s%[5]s counter snat to %[7]s
`, family, table, strconv.Quote(config.interfaceName), config.localAddress, destinationMatch,
		strconv.Quote(config.outboundInterface), config.sourceAddress)
}

func clearLinuxNATStates(config networkConfig, run networkCommandRunner) error {
	args := []string{"-D", "-f", "ipv" + config.family(), "-s", config.localAddress.String()}
	if !config.captureAll {
		args = append(args, "-d", config.destination.String())
	}

	_, err := run(linuxConntrackCommand, args...)
	if err != nil && strings.Contains(err.Error(), "0 flow entries have been deleted") {
		return nil
	}

	return err
}

// Strict reverse-path validation would reject replies arriving on the original
// interface because the capture route points their source back into the TUN.
func linuxReversePathChange(config networkConfig, run networkCommandRunner) (networkChange, error) {
	key := "net/ipv4/conf/" + config.outboundInterface + "/rp_filter"
	all, err := run(linuxSysctlCommand, "-n", "net.ipv4.conf.all.rp_filter")
	if err != nil {
		return networkChange{}, err
	}

	original, err := run(linuxSysctlCommand, "-n", key)
	if err != nil {
		return networkChange{}, err
	}
	all = strings.TrimSpace(all)
	original = strings.TrimSpace(original)
	if (all != "0" && all != "1" && all != "2") || (original != "0" && original != "1" && original != "2") {
		return networkChange{}, errors.New("unexpected rp_filter value")
	}

	change := networkChange{apply: func() error { return nil }, undo: func() error { return nil }}
	if all == "2" || original == "2" || (all == "0" && original == "0") {
		return change, nil
	}

	change.apply = func() error {
		_, err := run(linuxSysctlCommand, "-w", key+"="+linuxLooseReversePathFilter)
		return err
	}
	change.undo = func() error {
		current, err := run(linuxSysctlCommand, "-n", key)
		if err != nil || strings.TrimSpace(current) != linuxLooseReversePathFilter {
			return err
		}

		_, err = run(linuxSysctlCommand, "-w", key+"="+original)
		return err
	}

	return change, nil
}

func parseLinuxRoute(output string) (outboundRoute, error) {
	return parseLinuxRouteForFamily(output, "4")
}

func parseLinuxRouteForFamily(output, family string) (outboundRoute, error) {
	var routes []struct {
		Device string `json:"dev"`
		Source string `json:"prefsrc"`
	}
	if err := json.Unmarshal([]byte(output), &routes); err != nil {
		return outboundRoute{}, fmt.Errorf("decoding ip route output: %w", err)
	}

	if len(routes) != 1 || routes[0].Device == "" {
		return outboundRoute{}, errors.New("expected one outbound IP route with an interface")
	}

	source, err := netip.ParseAddr(routes[0].Source)
	if err != nil || (family == "4") != source.Is4() || source.Is4In6() || !source.IsGlobalUnicast() {
		return outboundRoute{}, fmt.Errorf("route has no unicast IP source: %q", routes[0].Source)
	}

	return outboundRoute{interfaceName: routes[0].Device, sourceAddress: source}, nil
}

func parseLinuxDefaultRoute(output string) (outboundRoute, error) {
	return parseLinuxDefaultRouteForFamily(output, "4")
}

func parseLinuxDefaultRouteForFamily(output, family string) (outboundRoute, error) {
	var routes []struct {
		Device string `json:"dev"`
		Source string `json:"prefsrc"`
		Metric uint32 `json:"metric"`
	}
	if err := json.Unmarshal([]byte(output), &routes); err != nil {
		return outboundRoute{}, fmt.Errorf("decoding default routes: %w", err)
	}

	if len(routes) == 0 {
		return outboundRoute{}, errNoDefaultRoute
	}

	selected := 0
	for index, route := range routes {
		if route.Metric < routes[selected].Metric {
			selected = index
		}
	}

	for index, route := range routes {
		if index != selected && route.Metric == routes[selected].Metric {
			return outboundRoute{}, errors.New("ambiguous default IP routes with equal metrics")
		}
	}

	route := routes[selected]
	if route.Device == "" {
		return outboundRoute{}, errors.New("default IP route has no interface")
	}

	result := outboundRoute{interfaceName: route.Device}
	if route.Source != "" {
		var err error
		result.sourceAddress, err = netip.ParseAddr(route.Source)
		if err != nil || (family == "4") != result.sourceAddress.Is4() || result.sourceAddress.Is4In6() || !result.sourceAddress.IsGlobalUnicast() {
			return outboundRoute{}, errors.New("default route has an invalid IP source")
		}
	}

	return result, nil
}

func findOutboundRouteForFamily(destination netip.Addr, family string) (outboundRoute, error) {
	if !destination.IsValid() {
		output, err := runNetworkCommand(linuxIPCommand, "-j", "-"+family, "route", "show", "default")
		if err != nil {
			return outboundRoute{}, err
		}

		route, err := parseLinuxDefaultRouteForFamily(output, family)
		if err != nil {
			return outboundRoute{}, err
		}

		if !route.sourceAddress.IsValid() {
			if family == "6" {
				route.sourceAddress, err = interfaceIPv6(route.interfaceName)
			} else {
				route.sourceAddress, err = interfaceIPv4(route.interfaceName)
			}
		}

		return route, err
	}

	output, err := runNetworkCommand(linuxIPCommand, "-j", "-"+family, "route", "get", destination.String())
	if err != nil {
		return outboundRoute{}, err
	}

	return parseLinuxRouteForFamily(output, family)
}

func configureNetwork(config networkConfig) (func() error, error) {
	return configureNetworkWithRunner(config, runNetworkCommand)
}

func configureNetworkWithRunner(config networkConfig, run networkCommandRunner) (func() error, error) {
	if err := validateNetworkConfig(config); err != nil {
		return nil, err
	}

	reversePath := networkChange{apply: func() error { return nil }, undo: func() error { return nil }}
	if config.localAddress.Is4() {
		var err error
		reversePath, err = linuxReversePathChange(config, run)
		if err != nil {
			return nil, err
		}
	}

	// Check the cleanup dependency before acquiring any networking state.
	if _, err := run(linuxConntrackCommand, "-V"); err != nil {
		return nil, err
	}

	table := "telar_proxy_" + strconv.Itoa(os.Getpid())
	rulesFile, err := writeNetworkRules(linuxNATRules(config, table))
	if err != nil {
		return nil, err
	}
	defer os.Remove(rulesFile)

	family := "ip"
	if config.localAddress.Is6() {
		family = "ip6"
	}

	nat := commandChange(run, linuxNFTCommand,
		[]string{"-f", rulesFile},
		[]string{"delete", "table", family, table},
	)
	deleteTable := nat.undo
	nat.undo = func() error {
		return errors.Join(deleteTable(), clearLinuxNATStates(config, run))
	}

	local := netip.PrefixFrom(config.localAddress, config.localAddress.BitLen()).String()
	peer := netip.PrefixFrom(config.peerAddress, config.peerAddress.BitLen()).String()
	address := commandChange(run, linuxIPCommand,
		[]string{"-" + config.family(), "address", "add", local, "peer", peer, "dev", config.interfaceName},
		[]string{"-" + config.family(), "address", "del", local, "peer", peer, "dev", config.interfaceName},
	)
	if config.localAddress.Is6() {
		address = commandChange(run, linuxIPCommand,
			[]string{"-6", "address", "add", local, "peer", peer, "dev", config.interfaceName, "nodad"},
			[]string{"-6", "address", "del", local, "peer", peer, "dev", config.interfaceName},
		)
	}

	link := commandChange(run, linuxIPCommand,
		[]string{"link", "set", "dev", config.interfaceName, "up"},
		[]string{"link", "set", "dev", config.interfaceName, "down"},
	)
	if config.localAddress.Is6() {
		link.undo = func() error { return nil }
	}

	changes := []networkChange{address, link, reversePath, nat}
	for _, prefix := range config.capturePrefixes() {
		changes = append(changes, commandChange(run, linuxIPCommand,
			[]string{"-" + config.family(), "route", "add", prefix.String(), "dev", config.interfaceName, "src", config.localAddress.String(), "proto", "static"},
			[]string{"-" + config.family(), "route", "del", prefix.String(), "dev", config.interfaceName, "src", config.localAddress.String(), "proto", "static"},
		))
	}

	return applyNetworkChanges(changes)
}
