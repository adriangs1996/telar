package main

import (
	"errors"
	"net/netip"
	"os"
	"strings"
	"testing"
)

func darwinTestConfig() networkConfig {
	return networkConfig{
		interfaceName:     "utun99",
		outboundInterface: "en7",
		outboundGateway:   netip.MustParseAddr("198.51.100.1"),
		localAddress:      netip.MustParseAddr("192.0.2.1"),
		peerAddress:       netip.MustParseAddr("192.0.2.2"),
		destination:       netip.MustParseAddr("203.0.113.8"),
		sourceAddress:     netip.MustParseAddr("198.51.100.3"),
	}
}

func darwinPFTestOutput(name string, args []string) string {
	if name != darwinPFCommand {
		return ""
	}

	switch strings.Join(args, " ") {
	case "-s nat":
		return "nat-anchor \"com.apple/*\" all\n"
	case "-s rules":
		return "anchor \"com.apple/*\" all\nscrub-anchor \"com.apple/*\" all fragment reassemble\n"
	case "-E":
		return "pf enabled\nToken : 123456\n"
	}

	return ""
}

func TestDarwinRouteParser(t *testing.T) {
	output := "   route to: 203.0.113.8\ndestination: default\n    gateway: 198.51.100.1\n  interface: en7\n      flags: <UP,GATEWAY>\n"
	fields, err := parseDarwinRoute(output)
	if err != nil || fields["interface"] != "en7" || fields["destination"] != "default" {
		t.Fatalf("fields = %v, error = %v", fields, err)
	}

	if _, err := parseDarwinRoute("route: writing to routing socket: Invalid argument"); err == nil {
		t.Fatal("accepted route output without a route")
	}
}

func TestDarwinExistingRouteIsNotDeletedOnActivationFailure(t *testing.T) {
	wantErr := errors.New("File exists")
	var commands []string
	run := func(name string, args ...string) (string, error) {
		command := name + " " + strings.Join(args, " ")
		commands = append(commands, command)
		if strings.Contains(command, " add ") {
			return "", wantErr
		}

		return darwinPFTestOutput(name, args), nil
	}

	cleanup, err := configureNetworkWithRunner(darwinTestConfig(), run)
	if cleanup != nil || !errors.Is(err, wantErr) {
		t.Fatalf("cleanup nil = %v, error = %v", cleanup == nil, err)
	}

	for _, command := range commands {
		if strings.Contains(command, " delete ") {
			t.Fatalf("removed a route whose installation failed: %s", command)
		}
	}

	if len(commands) < 2 || !strings.HasSuffix(commands[len(commands)-2], " down") || !strings.HasSuffix(commands[len(commands)-1], " -alias") {
		t.Fatalf("incomplete rollback: %v", commands)
	}
}

func TestDarwinCleanupPreservesAReplacedRoute(t *testing.T) {
	var deleted bool
	run := func(name string, args ...string) (string, error) {
		command := strings.Join(args, " ")
		if strings.Contains(command, " get ") {
			return "destination: 203.0.113.8\ninterface: en7\nflags: <UP,HOST,STATIC>\n", nil
		}

		if strings.Contains(command, " delete ") {
			deleted = true
		}

		return darwinPFTestOutput(name, args), nil
	}

	cleanup, err := configureNetworkWithRunner(darwinTestConfig(), run)
	if err != nil {
		t.Fatal(err)
	}

	if err := cleanup(); err != nil || deleted {
		t.Fatalf("cleanup error = %v, deleted replacement route = %v", err, deleted)
	}
}

func TestDarwinCleanupRemovesOwnedRouteBeforeAddress(t *testing.T) {
	var commands []string
	run := func(name string, args ...string) (string, error) {
		command := strings.Join(args, " ")
		commands = append(commands, command)
		if strings.Contains(command, " get ") {
			return "destination: 203.0.113.8\ninterface: utun99\nflags: <UP,HOST,STATIC,PROTO1>\n", nil
		}

		return darwinPFTestOutput(name, args), nil
	}

	cleanup, err := configureNetworkWithRunner(darwinTestConfig(), run)
	if err != nil {
		t.Fatal(err)
	}

	if err := cleanup(); err != nil {
		t.Fatal(err)
	}

	deleteIndex := -1
	flushIndex := -1
	for index, command := range commands {
		if strings.Contains(command, " delete ") {
			deleteIndex = index
		}
		if strings.Contains(command, "-F rules") {
			flushIndex = index
		}
	}

	if deleteIndex < 0 || flushIndex < deleteIndex || !strings.HasSuffix(commands[len(commands)-2], " down") || !strings.HasSuffix(commands[len(commands)-1], " -alias") {
		t.Fatalf("unexpected deactivation order: %v", commands)
	}
}

func TestDarwinPFTokenParser(t *testing.T) {
	token, err := parsePFToken("No ALTQ support in kernel\npf enabled\nToken : 123456789\n")
	if err != nil || token != "123456789" {
		t.Fatalf("token = %q, error = %v", token, err)
	}

	for _, output := range []string{"", "Token : 0", "Token : invalid", "Token : 18446744073709551616"} {
		if _, err := parsePFToken(output); err == nil {
			t.Fatalf("accepted invalid enable token: %q", output)
		}
	}
}

func TestDarwinMissingPFAnchorsMakesNoChanges(t *testing.T) {
	run := func(name string, args ...string) (string, error) {
		if name != darwinPFCommand || len(args) != 2 || args[0] != "-s" {
			t.Fatalf("modified network despite missing PF anchors: %s %v", name, args)
		}

		return "", nil
	}

	if _, err := configureNetworkWithRunner(darwinTestConfig(), run); err == nil {
		t.Fatal("accepted PF ruleset without reachable anchor hooks")
	}
}

func TestDarwinGeneratedPFRulesParse(t *testing.T) {
	for _, all := range []bool{false, true} {
		config := darwinTestConfig()
		config.captureAll = all
		if all {
			config.destination = netip.Addr{}
		}

		file, err := writeNetworkRules(darwinNATRules(config))
		if err != nil {
			t.Fatal(err)
		}
		defer os.Remove(file)

		if _, err := runNetworkCommand(darwinPFCommand, "-n", "-a", "com.apple/telar-proxy-syntax", "-f", file); err != nil {
			t.Fatal(err)
		}
	}
}

func TestDarwinAllCaptureRollsBackOnlyFirstRoute(t *testing.T) {
	config := darwinTestConfig()
	config.captureAll = true
	config.destination = netip.Addr{}
	wantErr := errors.New("second route already exists")
	var commands []string
	run := func(name string, args ...string) (string, error) {
		command := strings.Join(args, " ")
		commands = append(commands, command)
		if name == darwinRouteCommand {
			if strings.Contains(command, "add -inet -net "+ipv4UpperHalf) && !strings.Contains(command, "-ifscope") {
				return "", wantErr
			}

			if strings.Contains(command, " get ") {
				if strings.Contains(command, "-ifscope") {
					destination := "default"
					if strings.Contains(command, "128.0.0.1") {
						destination = "128.0.0.0"
					}

					return "destination: " + destination + "\nmask: 128.0.0.0\ninterface: en7\ngateway: 198.51.100.1\nflags: <UP,GATEWAY,STATIC,PROTO1,IFSCOPE>\n", nil
				}

				return "destination: default\nmask: 128.0.0.0\ninterface: utun99\nflags: <UP,STATIC,PROTO1>\n", nil
			}
		}

		return darwinPFTestOutput(name, args), nil
	}

	cleanup, err := configureNetworkWithRunner(config, run)
	if cleanup != nil || !errors.Is(err, wantErr) {
		t.Fatalf("cleanup nil = %v, error = %v", cleanup == nil, err)
	}

	firstDeleted := false
	for _, command := range commands {
		if strings.Contains(command, "delete -inet -net "+ipv4UpperHalf) && !strings.Contains(command, "-ifscope") {
			t.Fatal("deleted the pre-existing upper-half route")
		}

		if strings.Contains(command, "delete -inet -net "+ipv4LowerHalf) && !strings.Contains(command, "-ifscope") {
			firstDeleted = true
		}
	}

	if !firstDeleted {
		t.Fatalf("failed to roll back lower-half route: %v", commands)
	}
}

func TestDarwinInvalidConfigMakesNoNetworkChanges(t *testing.T) {
	config := darwinTestConfig()
	config.destination = config.sourceAddress
	run := func(name string, args ...string) (string, error) {
		t.Fatalf("ran a command for an invalid config: %s %v", name, args)
		return "", nil
	}

	if _, err := configureNetworkWithRunner(config, run); err == nil {
		t.Fatal("accepted a destination equal to the outbound source address")
	}
}

func darwinIPv6TestConfig() networkConfig {
	config := darwinTestConfig()
	config.egressInterface = "utun98"
	config.localAddress = netip.MustParseAddr(defaultTunnelIPv6)
	config.peerAddress = netip.MustParseAddr(defaultPeerIPv6)
	config.sourceAddress = netip.MustParseAddr("2001:db8:2::3")
	config.outboundGateway = netip.MustParseAddr("fe80::1%7")
	config.destination = netip.MustParseAddr("2001:db8:1::8")
	return config
}

func TestDarwinIPv6RulesParse(t *testing.T) {
	for _, scenario := range []struct{ all, direct bool }{{false, false}, {true, false}, {true, true}} {
		all := scenario.all
		config := darwinIPv6TestConfig()
		if scenario.direct {
			config.outboundGateway = netip.Addr{}
		}
		config.captureAll = all
		if all {
			config.destination = netip.Addr{}
		}

		file, err := writeNetworkRules(darwinNATRules(config))
		if err != nil {
			t.Fatal(err)
		}
		defer os.Remove(file)

		if _, err := runNetworkCommand(darwinPFCommand, "-n", "-a", "com.apple/telar-proxy-syntax", "-f", file); err != nil {
			t.Fatal(err)
		}
	}
}

func TestDarwinIPv6RoutePrefixes(t *testing.T) {
	for _, output := range []string{
		"destination: ::\nmask: 8000::\ninterface: utun99\nflags: <UP,STATIC,PROTO1>\n",
		"destination: 8000::\nmask: 8000::\ninterface: utun99\nflags: <UP,STATIC,PROTO1>\n",
		"destination: 2001:db8::1\ninterface: utun99\nflags: <UP,HOST,STATIC,PROTO1>\n",
	} {
		fields, err := parseDarwinRoute(output)
		if err != nil {
			t.Fatal(err)
		}

		prefix, err := parseDarwinRoutePrefix(fields)
		if err != nil || !prefix.Addr().Is6() {
			t.Fatalf("prefix = %s, error = %v", prefix, err)
		}
	}
}

func TestDarwinIPv6LowerHalfCleanupAvoidsLoopback(t *testing.T) {
	config := darwinIPv6TestConfig()
	var deleted bool
	run := func(name string, args ...string) (string, error) {
		command := strings.Join(args, " ")
		if strings.Contains(command, "get") {
			if command != "-n get -inet6 4000::1" {
				t.Fatalf("queried a more-specific loopback route: %s", command)
			}

			return "destination: ::\nmask: 8000::\ninterface: utun99\nflags: <UP,STATIC,PROTO1>\n", nil
		}

		if strings.Contains(command, "delete") {
			deleted = true
		}

		return "", nil
	}
	change := darwinCaptureRouteChange(config, netip.MustParsePrefix(ipv6LowerHalf), false, run)
	if err := change.apply(); err != nil {
		t.Fatal(err)
	}

	if err := change.undo(); err != nil || !deleted {
		t.Fatalf("delete = %v, error = %v", deleted, err)
	}
}

func TestDarwinIPv6KeepsGatewayScope(t *testing.T) {
	config := darwinIPv6TestConfig()
	if !strings.Contains(darwinNATRules(config), "route-to (\"en7\" fe80::1%7)") {
		t.Fatal("discarded link-local gateway scope needed for refragmentation")
	}
}
