package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

func writeFixture(directory, name, kind string, data []byte) error {
	return os.WriteFile(filepath.Join(directory, name+".pem"), pem.EncodeToMemory(&pem.Block{Type: kind, Bytes: data}), 0600)
}

func authority(directory, name string) (*x509.Certificate, *ecdsa.PrivateKey, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	certificate := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Test " + name + " CA"},
		NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, certificate, certificate, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	if err := writeFixture(directory, name+"-ca", "CERTIFICATE", der); err != nil {
		return nil, nil, err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, nil, err
	}
	if err := writeFixture(directory, name+"-key", "PRIVATE KEY", keyDER); err != nil {
		return nil, nil, err
	}
	parsed, err := x509.ParseCertificate(der)
	return parsed, key, err
}

func generate(directory string) error {
	if err := os.Mkdir(directory, 0700); err != nil {
		return err
	}
	parent, signer, err := authority(directory, "origin")
	if err != nil {
		return err
	}
	if _, _, err := authority(directory, "inspection"); err != nil {
		return err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	leaf := &x509.Certificate{
		SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "proxy.test"},
		DNSNames:    []string{"proxy.test", "bypass.test"},
		IPAddresses: []net.IP{net.ParseIP("198.51.100.10"), net.ParseIP("2001:db8:1::10")},
		NotBefore:   time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, leaf, parent, &key.PublicKey, signer)
	if err != nil {
		return err
	}
	if err := writeFixture(directory, "server", "CERTIFICATE", der); err != nil {
		return err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return err
	}
	return writeFixture(directory, "server-key", "PRIVATE KEY", keyDER)
}

func main() {
	if err := generate(os.Args[1]); err != nil {
		panic(err)
	}
}
