package main

import (
	"container/list"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/netip"
	"os"
	"sync"
	"syscall"
	"time"
)

const (
	tlsMaxPEMBytes       = 64 * 1024
	tlsMaxLeafCache      = 256
	tlsLeafLifetime      = 24 * time.Hour
	tlsCertificateMargin = time.Minute
	tlsSerialBits        = 128
)

type tlsLeaf struct {
	host        string
	certificate *tls.Certificate
}

type tlsAuthority struct {
	certificate *x509.Certificate
	key         crypto.Signer
	chain       [][]byte
	mu          sync.Mutex
	leaves      map[string]*list.Element
	ordered     list.List
}

func readTLSFile(path string, private bool) ([]byte, error) {
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0022 != 0 || private && info.Mode().Perm()&0077 != 0 {
		return nil, fmt.Errorf("TLS file %s must be regular and protected; private keys require mode 0600 or stricter", path)
	}
	data, err := io.ReadAll(io.LimitReader(file, tlsMaxPEMBytes+1))
	if err == nil && len(data) > tlsMaxPEMBytes {
		err = fmt.Errorf("TLS file %s exceeds %d bytes", path, tlsMaxPEMBytes)
	}

	return data, err
}

func loadTLSAuthority(certificatePath, keyPath string) (*tlsAuthority, error) {
	certificate, err := readTLSFile(certificatePath, false)
	if err != nil {
		return nil, err
	}
	key, err := readTLSFile(keyPath, true)
	if err != nil {
		return nil, err
	}
	defer clear(key)
	pair, err := tls.X509KeyPair(certificate, key)
	if err != nil {
		return nil, err
	}
	parent, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return nil, err
	}
	if !parent.IsCA || !parent.BasicConstraintsValid || parent.KeyUsage&x509.KeyUsageCertSign == 0 {
		return nil, errors.New("TLS inspection certificate must be a signing CA")
	}
	now := time.Now()
	if now.Before(parent.NotBefore) || !now.Before(parent.NotAfter) {
		return nil, errors.New("TLS inspection CA is outside its validity period")
	}
	signer, valid := pair.PrivateKey.(crypto.Signer)
	if !valid {
		return nil, errors.New("unsupported TLS authority signing key")
	}

	return &tlsAuthority{certificate: parent, key: signer, chain: pair.Certificate, leaves: make(map[string]*list.Element)}, nil
}

func (self *tlsAuthority) mint(host string) (*tls.Certificate, error) {
	host, err := canonicalTLSHost(host)
	if err != nil {
		return nil, err
	}

	self.mu.Lock()
	defer self.mu.Unlock()
	now := time.Now()
	if !now.Before(self.certificate.NotAfter) || now.Before(self.certificate.NotBefore) {
		return nil, errors.New("TLS inspection CA is outside its validity period")
	}
	if element := self.leaves[host]; element != nil {
		leaf := element.Value.(tlsLeaf).certificate
		if now.Before(leaf.Leaf.NotAfter) {
			self.ordered.MoveToBack(element)
			return leaf, nil
		}
		delete(self.leaves, host)
		self.ordered.Remove(element)
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), tlsSerialBits))
	if err != nil {
		return nil, err
	}
	serial.Add(serial, big.NewInt(1))
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: host},
		NotBefore:    now.Add(-tlsCertificateMargin),
		NotAfter:     minTime(now.Add(tlsLeafLifetime), self.certificate.NotAfter),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	if address, err := netip.ParseAddr(host); err == nil {
		template.IPAddresses = []net.IP{address.AsSlice()}
	} else {
		template.DNSNames = []string{host}
	}
	der, err := x509.CreateCertificate(rand.Reader, template, self.certificate, &key.PublicKey, self.key)
	if err != nil {
		return nil, err
	}
	parsed, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	roots := x509.NewCertPool()
	roots.AddCert(self.certificate)
	if _, err := parsed.Verify(x509.VerifyOptions{Roots: roots, DNSName: host}); err != nil {
		return nil, fmt.Errorf("verifying minted TLS certificate: %w", err)
	}
	leaf := &tls.Certificate{Certificate: append([][]byte{der}, self.chain...), PrivateKey: key, Leaf: parsed}
	if len(self.leaves) == tlsMaxLeafCache {
		oldest := self.ordered.Front()
		delete(self.leaves, oldest.Value.(tlsLeaf).host)
		self.ordered.Remove(oldest)
	}
	self.leaves[host] = self.ordered.PushBack(tlsLeaf{host: host, certificate: leaf})

	return leaf, nil
}

func minTime(left, right time.Time) time.Time {
	if left.Before(right) {
		return left
	}

	return right
}
