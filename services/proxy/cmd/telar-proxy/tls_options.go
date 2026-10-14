package main

import (
	"crypto/x509"
	"errors"
	"fmt"
)

type tlsOptions struct {
	hosts          []string
	certificate    string
	key            string
	upstreamBundle string
}

func loadTLSInspector(options tlsOptions) (*TLSInspector, error) {
	if len(options.hosts) == 0 {
		if options.certificate != "" || options.key != "" || options.upstreamBundle != "" {
			return nil, errors.New("TLS CA options require at least one -inspect-host")
		}
		return nil, nil
	}
	policy, err := newTLSHostPolicy(options.hosts)
	if err != nil {
		return nil, err
	}
	if options.certificate == "" || options.key == "" {
		return nil, errors.New("TLS inspection requires -tls-ca-cert and -tls-ca-key")
	}
	authority, err := loadTLSAuthority(options.certificate, options.key)
	if err != nil {
		return nil, fmt.Errorf("loading TLS inspection CA: %w", err)
	}
	inspector := &TLSInspector{authority: authority, policy: policy}
	if options.upstreamBundle != "" {
		bundle, err := readTLSFile(options.upstreamBundle, false)
		if err != nil {
			return nil, err
		}
		inspector.roots, err = x509.SystemCertPool()
		if err != nil {
			return nil, err
		}
		if !inspector.roots.AppendCertsFromPEM(bundle) {
			return nil, errors.New("TLS upstream bundle contains no certificates")
		}
	}

	return inspector, nil
}
