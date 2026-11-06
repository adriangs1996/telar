#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#if (defined(__APPLE__))
#include <cerrno>
#endif
#if (defined(__APPLE__))
#include <exception>
#endif
#if (defined(__APPLE__))
#include <CoreFoundation/CoreFoundation.h>
#endif
#if (defined(__APPLE__))
#include <Security/Security.h>
#endif
#if (defined(__APPLE__))
#include <array>
#endif
#if (defined(__APPLE__))
#include <cstdint>
#endif
#if (defined(__APPLE__))
#include <memory>
#endif
#if (defined(__APPLE__))
#include <span>
#endif
#if (!(defined(__APPLE__)))
#include <array>
#endif
#if (!(defined(__APPLE__)))
#include <cstdint>
#endif
#if (!(defined(__APPLE__)))
#include <cstdlib>
#endif
#if (!(defined(__APPLE__)))
#include <memory>
#endif
#if (!(defined(__APPLE__)))
#include <openssl/err.h>
#endif
#if (!(defined(__APPLE__)))
#include <openssl/pem.h>
#endif
#if (!(defined(__APPLE__)))
#include <openssl/x509.h>
#endif
#if (!(defined(__APPLE__)))
#include <span>
#endif
#if (!(defined(__APPLE__)))
#include <unistd.h>
#endif
#include "telar_base/memory/allocator.hpp"
#include <cstddef>
#include <cstring>
#include "telar_platform/file_descriptor.hpp"
#include <array>
#include <cstdint>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include "telar_platform/random_bytes.hpp"
#include <cstdio>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <unistd.h>
#endif
#include <cerrno>
#include <span>
#include <unistd.h>
#include <algorithm>
#include <cstdlib>
#include <string_view>
#include "telar_platform/trace.hpp"
#include <exception>
#include <memory>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <arpa/inet.h>
#include <optional>
#include <chrono>
#include <ctime>
#include <openssl/crypto.h>
#include <stdexcept>
#include <cassert>
#include "tls_fixture.hpp"
#include <type_traits>



import telar.runtime.platform.system_certificates;
import telar.tls;
import telar.runtime.tls.system_root_bundle;
import telar.runtime.tls.interception;

using namespace telar;
using namespace telar::runtime;

#if defined(__APPLE__)
template <typename Reference>
using NativeResource = TlsHandle<std::remove_pointer_t<Reference>, CFRelease>;

static NativeResource<SecCertificateRef> nativeCertificate(X509 *certificate) {
  std::array<unsigned char, CertificatePair::maximum_der_bytes> encoded;
  const auto length = i2d_X509(certificate, nullptr);
  check(length > 0 && static_cast<std::size_t>(length) <= encoded.size());
  auto *destination = encoded.data();
  check(i2d_X509(certificate, &destination) == length);
  NativeResource<CFDataRef> data{CFDataCreate(kCFAllocatorDefault, encoded.data(), length)};
  check(data != nullptr);
  NativeResource<SecCertificateRef> result{SecCertificateCreateWithData(kCFAllocatorDefault, data.get())};
  check(result != nullptr);

  return result;
}

static bool nativeTrusted(const CertificatePair &issuer, const CertificatePair &leaf, const char *hostname, bool anchored = true) {
  const auto root = nativeCertificate(issuer.certificate.get());
  const auto certificate = nativeCertificate(leaf.certificate.get());
  const void *certificates[]{certificate.get(), root.get()};
  NativeResource<CFArrayRef> chain{CFArrayCreate(kCFAllocatorDefault, certificates, std::size(certificates), &kCFTypeArrayCallBacks)};
  const void *roots[]{root.get()};
  NativeResource<CFArrayRef> anchors{CFArrayCreate(kCFAllocatorDefault, roots, anchored ? 1 : 0, &kCFTypeArrayCallBacks)};
  NativeResource<CFStringRef> name{CFStringCreateWithCString(kCFAllocatorDefault, hostname, kCFStringEncodingASCII)};
  check(chain && anchors && name);
  NativeResource<SecPolicyRef> policy{SecPolicyCreateSSL(true, name.get())};
  check(policy != nullptr);
  SecTrustRef trust = nullptr;
  check(SecTrustCreateWithCertificates(chain.get(), policy.get(), &trust) == errSecSuccess && trust != nullptr);
  NativeResource<SecTrustRef> evaluation{trust};
  // These anchors affect only this evaluation, never the user's keychains or
  // trust settings. Disabling fetches keeps the fixture local to this process.
  check(SecTrustSetAnchorCertificates(evaluation.get(), anchors.get()) == errSecSuccess);
  check(SecTrustSetAnchorCertificatesOnly(evaluation.get(), true) == errSecSuccess);
  check(SecTrustSetNetworkFetchAllowed(evaluation.get(), false) == errSecSuccess);

  return SecTrustEvaluateWithError(evaluation.get(), nullptr);
}
#else
static bool nativeTrusted(const CertificatePair &issuer, const CertificatePair &leaf, const char *hostname, bool anchored = true) {
  TlsHandle<X509_STORE, X509_STORE_free> store{X509_STORE_new()};
  check(store != nullptr);
  if (anchored) {
    check(X509_STORE_add_cert(store.get(), issuer.certificate.get()) == 1);
  }

  TlsHandle<X509_STORE_CTX, X509_STORE_CTX_free> verification{X509_STORE_CTX_new()};
  check(verification != nullptr && X509_STORE_CTX_init(verification.get(), store.get(), leaf.certificate.get(), nullptr) == 1);
  check(X509_STORE_CTX_set_purpose(verification.get(), X509_PURPOSE_SSL_SERVER) == 1);
  auto *parameters = X509_STORE_CTX_get0_param(verification.get());
  std::array<unsigned char, sizeof(in6_addr)> address{};
  const bool numeric = ::inet_pton(AF_INET, hostname, address.data()) == 1 || ::inet_pton(AF_INET6, hostname, address.data()) == 1;
  check((numeric ? X509_VERIFY_PARAM_set1_ip_asc(parameters, hostname) : X509_VERIFY_PARAM_set1_host(parameters, hostname, 0)) == 1);
  return X509_verify_cert(verification.get()) == 1;
}
#endif

static void nativeTrustChains() {
  auto issuer = CertificatePair::authority("Native fixture", CertificatePair::private_lifetime);
  const auto leaf = issuer.mint("origin.test");
  check(nativeTrusted(issuer, leaf, "origin.test"));
  check(!nativeTrusted(issuer, leaf, "wrong.test"));
  check(!nativeTrusted(issuer, leaf, "origin.test", false));
  const auto ipv6 = issuer.mint("::1");
  check(nativeTrusted(issuer, ipv6, "::1"));
  auto expired = issuer.mint("origin.test");
  check(X509_gmtime_adj(X509_getm_notAfter(expired.certificate.get()), -1) != nullptr);
  check(X509_sign(expired.certificate.get(), issuer.key.get(), EVP_sha256()) > 0);
  check(!nativeTrusted(issuer, expired, "origin.test"));
}

static bool trusted(TlsTrustStore<TlsTestMemory> &store, const CertificatePair &issuer) {
  const auto leaf = issuer.mint("origin.test");
  TlsHandle<X509_STORE_CTX, X509_STORE_CTX_free> verification{X509_STORE_CTX_new()};
  check(verification != nullptr && X509_STORE_CTX_init(verification.get(), store.native(), leaf.certificate.get(), nullptr) == 1);
  check(X509_STORE_CTX_set_purpose(verification.get(), X509_PURPOSE_SSL_SERVER) == 1);
  check(X509_VERIFY_PARAM_set1_host(X509_STORE_CTX_get0_param(verification.get()), "origin.test", 0) == 1);

  return X509_verify_cert(verification.get()) == 1;
}

void testTlsTrust(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library) {
  TlsTrustStore store{memory, library};
  check(store.count() == 0);
  auto first = CertificatePair::authority("Fixture authority", CertificatePair::private_lifetime);
  store.add(first.certificate.get());
  store.add(first.certificate.get());
  check(store.count() == 1);
  check(trusted(store, first));
  auto repeated_name = CertificatePair::authority("Fixture authority", CertificatePair::private_lifetime);
  store.add(repeated_name.certificate.get());
  check(store.count() == 2);
  check(trusted(store, first));
  check(trusted(store, repeated_name));
  const auto untrusted_same_name = CertificatePair::authority("Fixture authority", CertificatePair::private_lifetime);
  check(!trusted(store, untrusted_same_name));
  auto different = CertificatePair::authority("Another fixture", CertificatePair::private_lifetime);
  store.add(different.certificate.get());
  check(store.count() == 3);

  auto legacy = CertificatePair::authority("Fixture authority", CertificatePair::private_lifetime);
  const auto key_identifier = X509_get_ext_by_NID(legacy.certificate.get(), NID_subject_key_identifier, -1);
  check(key_identifier >= 0);
  TlsHandle<X509_EXTENSION, X509_EXTENSION_free> removed{X509_delete_ext(legacy.certificate.get(), key_identifier)};
  check(removed != nullptr && X509_sign(legacy.certificate.get(), legacy.key.get(), EVP_sha256()) > 0);
  store.add(legacy.certificate.get());
  check(trusted(store, legacy));
  check(store.count() == 4);

  std::array<unsigned char, CertificatePair::maximum_der_bytes> encoded;
  auto *destination = encoded.data();
  const auto length = i2d_X509(first.certificate.get(), &destination);
  check(length > 0);
  store.addDer(std::span{encoded}.first(static_cast<std::size_t>(length)));
  check(store.count() == 4);
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
  check(store.count() == 4);

  TlsTrustStore system{memory, library};
  std::size_t certificates = 0;
  SystemCertificates::read([&](std::span<const std::uint8_t> bytes) {
    system.addDer(bytes);
    ++certificates;
  });
  check(certificates != 0 && system.count() != 0 && system.count() <= certificates);
  const SystemRootBundle bundle{memory};
  check(!bundle.bytes().empty());
  nativeTrustChains();
}
