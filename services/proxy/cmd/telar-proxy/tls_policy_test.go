package main

import "testing"

func TestTLSHostPolicyMatchesExactAndProperSubdomains(t *testing.T) {
	policy, err := newTLSHostPolicy([]string{"API.Example.com.", "*.other.test", "2001:db8::1"})
	if err != nil {
		t.Fatal(err)
	}
	for host, want := range map[string]bool{
		"api.example.com": true, "sub.api.example.com": false,
		"other.test": false, "sub.other.test": true, "deep.sub.other.test": true,
		"notother.test": false, "2001:db8::1": true, "2001:db8::2": false,
	} {
		if policy.matches(host) != want {
			t.Fatalf("match(%q) = %t, want %t", host, policy.matches(host), want)
		}
	}
	for _, rule := range []string{"", "a*b.test", "*example.com", "foo..test", "*.127.0.0.1", "localhost:443", "-bad.test"} {
		if _, err := newTLSHostPolicy([]string{rule}); err == nil {
			t.Fatalf("accepted invalid rule %q", rule)
		}
	}
}

func TestTLSOptionsRejectMissingAuthorityBeforeNetworkActivation(t *testing.T) {
	for _, options := range []tlsOptions{
		{hosts: []string{"*"}}, {certificate: "unused.pem"},
		{hosts: []string{"*"}, certificate: "cert.pem"},
		{hosts: []string{"*"}, key: "key.pem"},
	} {
		if _, err := loadTLSInspector(options); err == nil {
			t.Fatal("accepted incomplete TLS inspection configuration")
		}
	}
}
