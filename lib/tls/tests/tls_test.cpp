#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <unistd.h>
#endif
#include <arpa/inet.h>
#include <cstdlib>
#include <ctime>
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.base.memory.sensitive;
import telar.platform.primitives;
import telar.testing;
import telar.tls.tests.tls_fixture;
import telar.platform.error;
import telar.platform.fs;
import telar.tls;

using telar::testing::check;

using namespace telar;
using namespace telar::runtime;

template <typename Operation>
static void rejected(Operation&& operation) {
  bool failed = false;

  try {
    operation();
  } catch (const TlsError&) {
    failed = true;
  } catch (const SystemError&) {
    failed = true;
  }

  check(failed);
}

static void testTlsMemory() {
  auto* bytes = static_cast<unsigned char*>(OPENSSL_malloc(16));

  check(bytes != nullptr && reinterpret_cast<std::uintptr_t>(bytes) % alignof(std::max_align_t) == 0);
  std::fill_n(bytes, 16, 42);
  auto* expanded = static_cast<unsigned char*>(OPENSSL_realloc(bytes, 256));

  check(expanded != nullptr && std::all_of(expanded, expanded + 16, [](auto byte) {
    return byte == 42;
  }));

  check(OPENSSL_realloc(expanded, std::numeric_limits<std::size_t>::max()) == nullptr);
  check(std::all_of(expanded, expanded + 16, [](auto byte) {
    return byte == 42;
  }));

  OPENSSL_free(expanded);
  check(OPENSSL_malloc(std::numeric_limits<std::size_t>::max()) == nullptr);

  std::array<std::thread, 4> workers;

  for (auto& worker : workers) {
    worker = std::thread{[] {
      for (unsigned index = 0; index < 256; ++index) {
        void* allocation = OPENSSL_malloc(index + 1);

        check(allocation != nullptr);
        OPENSSL_free(allocation);
      }

      OPENSSL_thread_stop();
    }};
  }

  for (auto& worker : workers) {
    worker.join();
  }
}

// Whether `leaf` verifies under `issuer` as a TLS server for `name`, a DNS name or, if `numeric`,
// an IP address. OpenSSL 4.1 checks names only through verification.
static bool covers(X509* issuer, X509* leaf, std::string_view name, bool numeric = false) {
  TlsHandle<X509_STORE, X509_STORE_free> store{X509_STORE_new()};
  TlsHandle<X509_STORE_CTX, X509_STORE_CTX_free> verification{X509_STORE_CTX_new()};

  check(store != nullptr && verification != nullptr && X509_STORE_add_cert(store.get(), issuer) == 1);
  check(X509_STORE_CTX_init(verification.get(), store.get(), leaf, nullptr) == 1);
  check(X509_STORE_CTX_set_purpose(verification.get(), X509_PURPOSE_SSL_SERVER) == 1);
  auto* parameters = X509_STORE_CTX_get0_param(verification.get());
  const std::string terminated{name};

  check((numeric ? X509_VERIFY_PARAM_set1_ip_asc(parameters, terminated.c_str()) : X509_VERIFY_PARAM_set1_host(parameters, terminated.data(), terminated.size())) == 1);
  return X509_verify_cert(verification.get()) == 1;
}

static void testAuthorities(ConcurrentMemory& memory, const TlsLibrary& library) {
  AuthorityDirectory directory;
  const int descriptor = directory.descriptor.get();
  auto authority = CertificateAuthority::loadOrCreate(memory, library, descriptor, AuthorityKind::private_local);
  const auto fingerprint = authority.fingerprint();

  check(!authority.expiresWithin(std::chrono::days{31}));
  for (const auto name : {"ca-key.pem", "ca-cert.pem"}) {
    struct stat state{};

    check(::fstatat(descriptor, name, &state, AT_SYMLINK_NOFOLLOW) == 0 && (state.st_mode & 0777) == 0600 && S_ISREG(state.st_mode));
  }

  auto loaded = CertificateAuthority::loadOrCreate(memory, library, descriptor, AuthorityKind::private_local);

  check(loaded.fingerprint() == fingerprint);
  auto system = CertificateAuthority::loadOrCreate(memory, library, descriptor, AuthorityKind::system_trust);

  check(system.expiresWithin(std::chrono::days{31}) && !system.expiresWithin(std::chrono::days{29}));
  auto loaded_system = CertificateAuthority::loadOrCreate(memory, library, descriptor, AuthorityKind::system_trust);

  check(loaded_system.fingerprint() == system.fingerprint());

  const auto longest = std::string(63, 'a') + "." + std::string(63, 'b') + "." + std::string(63, 'c') + "." + std::string(61, 'd');

  for (const auto& hostname : {std::string{"api.example.com"}, longest}) {
    auto leaf = authority.mint(hostname);
    TlsKey issuer{X509_get_pubkey(authority.certificate())};

    check(X509_verify(leaf.certificate.get(), issuer.get()) == 1);
    check(covers(authority.certificate(), leaf.certificate.get(), hostname));
    check(!covers(authority.certificate(), leaf.certificate.get(), "another.example.com"));
    check(X509_check_ca(leaf.certificate.get()) == 0 && X509_check_private_key(leaf.certificate.get(), leaf.key.get()) == 1);
    check(i2d_X509(leaf.certificate.get(), nullptr) <= static_cast<int>(CertificatePair::maximum_der_bytes));
  }

  for (const auto hostname : {"", "*.example.com", "bad,name", "a..b", "https://example.com"}) {
    rejected([&] {
      authority.mint(hostname);
    });
  }

  const PemDocument root{system.certificate()};

  authority.writeBundle(descriptor, root.bytes());
  Vector<unsigned char, ConcurrentMemory> bundle{AllocatorRef<unsigned char, ConcurrentMemory>{memory}};

  check(readPrivateFile(descriptor, "ca-bundle.pem", bundle, PemDocument::maximum_bytes * 2));
  const PemDocument own{authority.certificate()};

  check(bundle.size() == root.bytes().size() + own.bytes().size());
  check(std::equal(root.bytes().begin(), root.bytes().end(), bundle.begin()));
  check(std::equal(own.bytes().begin(), own.bytes().end(), bundle.begin() + root.bytes().size()));

  check(::unlinkat(descriptor, "ca-cert.pem", 0) == 0);
  rejected([&] {
    CertificateAuthority::loadOrCreate(memory, library, descriptor, AuthorityKind::private_local);
  });

  check(writePrivateFile(descriptor, "ca-cert.pem", own.bytes(), PrivateFileMode::create_only) == 0);
  check(::fchmodat(descriptor, "ca-key.pem", 0644, 0) == 0);
  rejected([&] {
    CertificateAuthority::loadOrCreate(memory, library, descriptor, AuthorityKind::private_local);
  });

  check(::fchmodat(descriptor, "ca-key.pem", 0600, 0) == 0);

  const auto replacement = CertificatePair::authority("telar local CA", CertificatePair::private_lifetime);
  const PemDocument other_key{replacement.key.get()};

  check(writePrivateFile(descriptor, "ca-key.pem", other_key.bytes(), PrivateFileMode::replace) == 0);
  rejected([&] {
    CertificateAuthority::loadOrCreate(memory, library, descriptor, AuthorityKind::private_local);
  });

  Vector<unsigned char, ConcurrentMemory> retained{AllocatorRef<unsigned char, ConcurrentMemory>{memory}};

  check(readPrivateFile(descriptor, "ca-key.pem", retained, PemDocument::maximum_bytes) && std::ranges::equal(retained, other_key.bytes()));
  eraseSensitive(retained.data(), retained.size());
}

static void testAuthorityValidation() {
  auto pair = CertificatePair::authority("telar local CA", CertificatePair::private_lifetime);

  pair.validateAuthority("telar local CA", false);
  rejected([&] {
    pair.validateAuthority("another issuer", false);
  });

  rejected([&] {
    pair.validateAuthority("telar local CA", true);
  });

  const PemDocument key{pair.key.get()};
  const PemDocument certificate{pair.certificate.get()};
  auto decoded = CertificatePair::parse(key.bytes(), certificate.bytes());

  decoded.validateAuthority("telar local CA", false);

  TlsBuffer encrypted{BIO_new(BIO_s_mem())};
  constexpr unsigned char password[] = "fixture";

  check(PEM_write_bio_PrivateKey(encrypted.get(), pair.key.get(), EVP_aes_256_cbc(), password, sizeof(password) - 1, nullptr, nullptr) == 1);
  char* data = nullptr;
  const auto length = BIO_get_mem_data(encrypted.get(), &data);

  rejected([&] {
    CertificatePair::parse({reinterpret_cast<const unsigned char*>(data), static_cast<std::size_t>(length)}, certificate.bytes());
  });

  check(X509_gmtime_adj(X509_getm_notAfter(pair.certificate.get()), -1) != nullptr && X509_sign(pair.certificate.get(), pair.key.get(), EVP_sha256()) > 0);
  rejected([&] {
    pair.validateAuthority("telar local CA", false);
  });
}

static void numericCertificates() {
  const auto issuer = CertificatePair::authority("Numeric test", CertificatePair::private_lifetime);

  for (const auto host : {"127.0.0.1", "::1", "2001:db8::1234"}) {
    const auto leaf = issuer.mint(host);

    check(covers(issuer.certificate.get(), leaf.certificate.get(), host, true));
    check(!covers(issuer.certificate.get(), leaf.certificate.get(), "192.0.2.1", true));
  }
}

static const telar::testing::Case case_tls_memory{"tls.tls_memory", testTlsMemory};
static const telar::testing::Case case_authorities{"tls.authorities", withTlsLibrary<testAuthorities>};
static const telar::testing::Case case_authority_validation{"tls.authority_validation", testAuthorityValidation};
static const telar::testing::Case case_numeric_certificates{"tls.numeric_certificates", numericCertificates};
