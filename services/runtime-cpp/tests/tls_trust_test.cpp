#include "check.hpp"
#include "platform/system_certificates.hpp"
#include "tls/authority.hpp"
#include "tls/system_root_bundle.hpp"
#include "tls/trust_store.hpp"
#include "tls_fixture.hpp"

using namespace telar::runtime;

void testTlsTrust(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library) {
  TlsTrustStore store{memory, library};
  check(store.count() == 0);
  auto first = CertificatePair::authority("Fixture authority", CertificatePair::private_lifetime);
  store.add(first.certificate.get());
  store.add(first.certificate.get());
  check(store.count() == 1);
  auto repeated_name = CertificatePair::authority("Fixture authority", CertificatePair::private_lifetime);
  store.add(repeated_name.certificate.get());
  check(store.count() == 1);
  auto different = CertificatePair::authority("Another fixture", CertificatePair::private_lifetime);
  store.add(different.certificate.get());
  check(store.count() == 2);

  std::array<unsigned char, CertificatePair::maximum_der_bytes> encoded;
  auto *destination = encoded.data();
  const auto length = i2d_X509(first.certificate.get(), &destination);
  check(length > 0);
  store.addDer(std::span{encoded}.first(static_cast<std::size_t>(length)));
  check(store.count() == 2);
  bool refused = false;
  try {
    store.addDer(std::span{encoded}.first(1));
  } catch (const TlsError &) {
    refused = true;
  }
  check(refused);

  auto expired = CertificatePair::authority("Expired fixture", CertificatePair::private_lifetime);
  check(X509_gmtime_adj(X509_getm_notAfter(expired.certificate.get()), -1) != nullptr);
  check(X509_sign(expired.certificate.get(), expired.key.get(), EVP_sha256()) > 0);
  store.add(expired.certificate.get());
  check(store.count() == 2);

  TlsTrustStore system{memory, library};
  std::size_t certificates = 0;
  SystemCertificates::read([&](std::span<const std::uint8_t> bytes) {
    system.addDer(bytes);
    ++certificates;
  });
  check(certificates != 0 && system.count() != 0 && system.count() <= certificates);
  const SystemRootBundle bundle{memory};
  check(!bundle.bytes().empty());
}
