package main

import (
	"errors"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestCaptureModeSelection(t *testing.T) {
	for _, scenario := range []struct {
		all         bool
		destination string
		valid       bool
	}{
		{true, "", true},
		{false, "1.1.1.1", true},
		{false, "", false},
		{true, "1.1.1.1", false},
		{false, "::1", false},
		{false, "0.0.0.0", false},
	} {
		config, err := parseNetworkConfig(scenario.all, scenario.destination, "192.0.2.1", "192.0.2.2")
		if (err == nil) != scenario.valid {
			t.Fatalf("all = %v, destination = %q, error = %v", scenario.all, scenario.destination, err)
		}

		if err == nil && config.captureAll {
			prefixes := config.capturePrefixes()
			if len(prefixes) != 2 || prefixes[0] != netip.MustParsePrefix(ipv4LowerHalf) || prefixes[1] != netip.MustParsePrefix(ipv4UpperHalf) {
				t.Fatalf("unexpected IPv4 capture prefixes: %v", prefixes)
			}
		}
	}
}

func TestNetworkActivationRollsBackOnlySuccessfulChanges(t *testing.T) {
	wantErr := errors.New("route already exists")
	var actions []string
	changes := []networkChange{
		{
			apply: func() error { actions = append(actions, "add address"); return nil },
			undo:  func() error { actions = append(actions, "remove address"); return nil },
		},
		{
			apply: func() error { actions = append(actions, "add route"); return wantErr },
			undo:  func() error { actions = append(actions, "remove route"); return nil },
		},
	}

	cleanup, err := applyNetworkChanges(changes)
	if cleanup != nil || !errors.Is(err, wantErr) {
		t.Fatalf("cleanup = %v, error = %v", cleanup == nil, err)
	}

	want := []string{"add address", "add route", "remove address"}
	if !reflect.DeepEqual(actions, want) {
		t.Fatalf("actions = %v, want %v", actions, want)
	}
}

func TestNetworkCleanupContinuesAfterFailureAndRunsOnce(t *testing.T) {
	wantErr := errors.New("route removal failed")
	var actions []string
	changes := []networkChange{
		{
			apply: func() error { return nil },
			undo:  func() error { actions = append(actions, "remove address"); return nil },
		},
		{
			apply: func() error { return nil },
			undo:  func() error { actions = append(actions, "remove route"); return wantErr },
		},
	}

	cleanup, err := applyNetworkChanges(changes)
	if err != nil {
		t.Fatal(err)
	}

	for range 2 {
		if err := cleanup(); !errors.Is(err, wantErr) {
			t.Fatalf("cleanup error = %v, want %v", err, wantErr)
		}
	}

	want := []string{"remove route", "remove address"}
	if !reflect.DeepEqual(actions, want) {
		t.Fatalf("actions = %v, want %v", actions, want)
	}
}

func TestNetworkRollbackReportsCleanupFailure(t *testing.T) {
	applyErr := errors.New("activation failed")
	undoErr := errors.New("cleanup failed")
	_, err := applyNetworkChanges([]networkChange{
		{apply: func() error { return nil }, undo: func() error { return undoErr }},
		{apply: func() error { return applyErr }, undo: func() error { return nil }},
	})
	if !errors.Is(err, applyErr) || !errors.Is(err, undoErr) {
		t.Fatalf("error = %v; expected both activation and cleanup failures", err)
	}
}

func TestNetworkCommandRejectsStderrWithSuccessfulExit(t *testing.T) {
	command := filepath.Join(t.TempDir(), "route")
	script := []byte("#!/bin/sh\nprintf 'route: writing to routing socket: File exists\\n' >&2\nexit 0\n")
	if err := os.WriteFile(command, script, 0700); err != nil {
		t.Fatal(err)
	}

	if _, err := runNetworkCommand(command); err == nil {
		t.Fatal("accepted a failed command that exited with status 0")
	}
}

func TestIPv6CaptureConfig(t *testing.T) {
	for _, all := range []bool{false, true} {
		destination := "2001:db8::8"
		if all {
			destination = ""
		}

		config, err := parseNetworkConfig(all, destination, defaultTunnelIPv6, defaultPeerIPv6)
		if err != nil {
			t.Fatal(err)
		}
		config.interfaceName = "teltun99"
		config.outboundInterface = "eth7"
		config.sourceAddress = netip.MustParseAddr("2001:db8::3")
		if err := validateNetworkConfig(config); err != nil {
			t.Fatal(err)
		}

		prefixes := config.capturePrefixes()
		if (all && (len(prefixes) != 2 || prefixes[0].String() != ipv6LowerHalf || prefixes[1].String() != ipv6UpperHalf)) || (!all && prefixes[0].String() != "2001:db8::8/128") {
			t.Fatalf("unexpected IPv6 capture prefixes: %v", prefixes)
		}

		config.peerAddress = config.localAddress
		if err := validateNetworkConfig(config); err == nil {
			t.Fatal("accepted identical tunnel addresses")
		}
		config.peerAddress = netip.MustParseAddr("192.0.2.2")
		if err := validateNetworkConfig(config); err == nil {
			t.Fatal("accepted mixed IP families")
		}
	}
}
