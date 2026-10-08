package main

import (
	"errors"
	"net/netip"
	"strings"
	"testing"
)

func TestLinuxRouteParser(t *testing.T) {
	output := `[{"dst":"203.0.113.8","gateway":"198.51.100.1","dev":"eth7","prefsrc":"198.51.100.3"}]`
	route, err := parseLinuxRoute(output)
	if err != nil || route.interfaceName != "eth7" || route.sourceAddress.String() != "198.51.100.3" {
		t.Fatalf("route = %+v, error = %v", route, err)
	}

	for _, output := range []string{`[]`, `{`, `[{"dev":"eth7"}]`, `[{"dev":"eth7","prefsrc":"::1"}]`} {
		if _, err := parseLinuxRoute(output); err == nil {
			t.Fatalf("accepted invalid outbound route: %s", output)
		}
	}
}

func TestLinuxDefaultRouteSelection(t *testing.T) {
	output := `[{"dev":"eth8","metric":200},{"dev":"eth7","metric":100,"prefsrc":"198.51.100.3"}]`
	route, err := parseLinuxDefaultRoute(output)
	if err != nil || route.interfaceName != "eth7" || route.sourceAddress.String() != "198.51.100.3" {
		t.Fatalf("route = %+v, error = %v", route, err)
	}

	for _, output := range []string{`[]`, `{`, `[{"dev":"eth7"},{"dev":"eth8"}]`, `[{"gateway":"198.51.100.1"}]`} {
		if _, err := parseLinuxDefaultRoute(output); err == nil {
			t.Fatalf("accepted missing or ambiguous default route: %s", output)
		}
	}
}

func TestLinuxAllCaptureRollsBackOnlyFirstRoute(t *testing.T) {
	config := networkConfig{
		captureAll:        true,
		interfaceName:     "teltun99",
		outboundInterface: "eth7",
		localAddress:      netip.MustParseAddr("192.0.2.1"),
		peerAddress:       netip.MustParseAddr("192.0.2.2"),
		sourceAddress:     netip.MustParseAddr("198.51.100.3"),
	}
	wantErr := errors.New("second route already exists")
	var commands []string
	run := func(name string, args ...string) (string, error) {
		command := strings.Join(args, " ")
		commands = append(commands, command)
		if name == linuxSysctlCommand {
			return "0\n", nil
		}

		if strings.Contains(command, "route add "+ipv4UpperHalf) {
			return "", wantErr
		}

		return "", nil
	}

	cleanup, err := configureNetworkWithRunner(config, run)
	if cleanup != nil || !errors.Is(err, wantErr) {
		t.Fatalf("cleanup nil = %v, error = %v", cleanup == nil, err)
	}

	firstDeleted := false
	for _, command := range commands {
		if strings.Contains(command, "route del "+ipv4UpperHalf) {
			t.Fatal("deleted the pre-existing upper-half route")
		}

		if strings.Contains(command, "route del "+ipv4LowerHalf) {
			firstDeleted = true
		}
	}

	if !firstDeleted {
		t.Fatalf("failed to roll back lower-half route: %v", commands)
	}
}

func TestLinuxExistingRouteIsNotDeletedOnActivationFailure(t *testing.T) {
	config := networkConfig{
		interfaceName:     "teltun99",
		outboundInterface: "eth7",
		localAddress:      netip.MustParseAddr("192.0.2.1"),
		peerAddress:       netip.MustParseAddr("192.0.2.2"),
		destination:       netip.MustParseAddr("203.0.113.8"),
		sourceAddress:     netip.MustParseAddr("198.51.100.3"),
	}
	wantErr := errors.New("File exists")
	var commands []string
	run := func(name string, args ...string) (string, error) {
		command := strings.Join(args, " ")
		if name == linuxSysctlCommand {
			return "0\n", nil
		}

		commands = append(commands, command)
		if strings.Contains(command, "route add") {
			return "", wantErr
		}

		return "", nil
	}

	cleanup, err := configureNetworkWithRunner(config, run)
	if cleanup != nil || !errors.Is(err, wantErr) {
		t.Fatalf("cleanup nil = %v, error = %v", cleanup == nil, err)
	}

	for _, command := range commands {
		if strings.Contains(command, "route del") {
			t.Fatalf("removed a route whose installation failed: %s", command)
		}
	}

	if len(commands) < 2 || !strings.HasSuffix(commands[len(commands)-2], " down") || !strings.Contains(commands[len(commands)-1], "address del") {
		t.Fatalf("incomplete rollback: %v", commands)
	}
}

func TestLinuxReversePathChangePreservesConcurrentEdits(t *testing.T) {
	config := networkConfig{outboundInterface: "eth7"}
	current := "1"
	var writes []string
	run := func(name string, args ...string) (string, error) {
		if args[0] == "-n" {
			if strings.Contains(args[1], ".all.") {
				return "1\n", nil
			}

			return current + "\n", nil
		}

		writes = append(writes, args[1])
		_, current, _ = strings.Cut(args[1], "=")
		return "", nil
	}

	change, err := linuxReversePathChange(config, run)
	if err != nil {
		t.Fatal(err)
	}

	if err := change.apply(); err != nil || current != "2" {
		t.Fatalf("current = %s, error = %v", current, err)
	}

	current = "0"
	if err := change.undo(); err != nil || current != "0" || len(writes) != 1 {
		t.Fatalf("overwrote concurrent edit: value = %s, writes = %v, error = %v", current, writes, err)
	}
}

func TestLinuxReversePathChangeRestoresOriginalValue(t *testing.T) {
	config := networkConfig{outboundInterface: "eth7"}
	current := "0"
	run := func(name string, args ...string) (string, error) {
		if args[0] == "-n" {
			if strings.Contains(args[1], ".all.") {
				return "1\n", nil
			}

			return current + "\n", nil
		}

		_, current, _ = strings.Cut(args[1], "=")
		return "", nil
	}

	change, err := linuxReversePathChange(config, run)
	if err != nil {
		t.Fatal(err)
	}

	if err := change.apply(); err != nil {
		t.Fatal(err)
	}

	if err := change.undo(); err != nil || current != "0" {
		t.Fatalf("current = %s, error = %v", current, err)
	}
}

func TestLinuxIPv6RouteParser(t *testing.T) {
	route, err := parseLinuxRouteForFamily(`[{"dev":"eth7","prefsrc":"2001:db8::3"}]`, "6")
	if err != nil || route.sourceAddress.String() != "2001:db8::3" {
		t.Fatalf("route = %+v, error = %v", route, err)
	}

	if _, err := parseLinuxRouteForFamily(`[{"dev":"eth7","prefsrc":"192.0.2.1"}]`, "6"); err == nil {
		t.Fatal("accepted IPv4 source for IPv6 route")
	}
	if _, err := parseLinuxDefaultRouteForFamily(`[]`, "6"); !errors.Is(err, errNoDefaultRoute) {
		t.Fatalf("missing default route error = %v", err)
	}
}
