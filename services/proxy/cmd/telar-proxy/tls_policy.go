package main

import (
	"fmt"
	"net/netip"
	"strings"

	"golang.org/x/net/idna"
)

const (
	tlsMaxHostRules     = 256
	tlsMaxHostnameBytes = 253
	tlsMaxDNSLabelBytes = 63
)

type tlsHostPolicy struct {
	all      bool
	exact    map[string]bool
	suffixes []string
}

func newTLSHostPolicy(rules []string) (tlsHostPolicy, error) {
	policy := tlsHostPolicy{exact: make(map[string]bool)}
	if len(rules) > tlsMaxHostRules {
		return policy, fmt.Errorf("TLS inspection accepts at most %d host rules", tlsMaxHostRules)
	}
	for _, rule := range rules {
		if rule == "*" {
			policy.all = true
			continue
		}
		wildcard := strings.HasPrefix(rule, "*.")
		name := strings.TrimPrefix(rule, "*.")
		host, err := canonicalTLSHost(name)
		if err != nil {
			return policy, fmt.Errorf("invalid inspection host %q: %w", rule, err)
		}
		if wildcard {
			if _, err := netip.ParseAddr(host); err == nil {
				return policy, fmt.Errorf("wildcard inspection rule cannot name an IP address: %q", rule)
			}
			policy.suffixes = append(policy.suffixes, "."+host)
		} else {
			policy.exact[host] = true
		}
	}

	return policy, nil
}

func canonicalTLSHost(host string) (string, error) {
	if address, err := netip.ParseAddr(host); err == nil && address.Zone() == "" {
		return address.Unmap().String(), nil
	}
	host, err := idna.Lookup.ToASCII(strings.TrimSuffix(host, "."))
	if err != nil || len(host) == 0 || len(host) > tlsMaxHostnameBytes {
		return "", fmt.Errorf("invalid TLS hostname %q", host)
	}
	host = strings.ToLower(host)
	for _, label := range strings.Split(host, ".") {
		if len(label) == 0 || len(label) > tlsMaxDNSLabelBytes || label[0] == '-' || label[len(label)-1] == '-' {
			return "", fmt.Errorf("invalid DNS label in %q", host)
		}
		for _, character := range label {
			if !(character >= 'a' && character <= 'z' || character >= '0' && character <= '9' || character == '-') {
				return "", fmt.Errorf("invalid DNS character in %q", host)
			}
		}
	}

	return host, nil
}

func (self tlsHostPolicy) matches(host string) bool {
	if self.all || self.exact[host] {
		return true
	}
	for _, suffix := range self.suffixes {
		if strings.HasSuffix(host, suffix) {
			return true
		}
	}

	return false
}
