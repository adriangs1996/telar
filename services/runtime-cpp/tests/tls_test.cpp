#include "check.hpp"
#include "telar_platform/private_directory.hpp"
#include "telar_platform/trace.hpp"
#include "telar_tls/authority.hpp"
#include "telar_tls/trust/inspection.hpp"
#include "tls_fixture.hpp"
#include <filesystem>
#include <fstream>
#include <thread>

using namespace telar::runtime;

void testTlsAlpn();
void testProxyService(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library);
void testTlsSession(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library);
void testTlsTrust(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library);
void testProxyTrust(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library);
void createProxyTrustFixture(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library, std::string_view directory);

template <typename Operation>
static void rejected(Operation &&operation) {
  bool failed = false;
  try {
    operation();
  } catch (const TlsError &) {
    failed = true;
  } catch (const SystemError &) {
    failed = true;
  }
  check(failed);
}

static void testTlsMemory() {
  auto *bytes = static_cast<unsigned char *>(OPENSSL_malloc(16));
  check(bytes != nullptr && reinterpret_cast<std::uintptr_t>(bytes) % alignof(std::max_align_t) == 0);
  std::fill_n(bytes, 16, 42);
  auto *expanded = static_cast<unsigned char *>(OPENSSL_realloc(bytes, 256));
  check(expanded != nullptr && std::all_of(expanded, expanded + 16, [](auto byte) { return byte == 42; }));
  check(OPENSSL_realloc(expanded, std::numeric_limits<std::size_t>::max()) == nullptr);
  check(std::all_of(expanded, expanded + 16, [](auto byte) { return byte == 42; }));
  OPENSSL_free(expanded);
  check(OPENSSL_malloc(std::numeric_limits<std::size_t>::max()) == nullptr);

  std::array<std::thread, 4> workers;
  for (auto &worker : workers) {
    worker = std::thread{[] {
      for (unsigned index = 0; index < 256; ++index) {
        void *allocation = OPENSSL_malloc(index + 1);
        check(allocation != nullptr);
        OPENSSL_free(allocation);
      }
      OPENSSL_thread_stop();
    }};
  }
  for (auto &worker : workers) {
    worker.join();
  }
}

template <ConcurrentAllocator Memory>
static void testAuthorities(Memory &memory, const TlsLibrary<Memory> &library) {
  AuthorityDirectory directory;
  const int descriptor = directory.descriptor.get();
  auto authority = CertificateAuthority<Memory>::loadOrCreate(memory, library, descriptor, AuthorityKind::private_local);
  const auto fingerprint = authority.fingerprint();
  check(!authority.expiresWithin(std::chrono::days{31}));
  for (const auto name : {"ca-key.pem", "ca-cert.pem"}) {
    struct stat state{};
    check(::fstatat(descriptor, name, &state, AT_SYMLINK_NOFOLLOW) == 0 && (state.st_mode & 0777) == 0600 && S_ISREG(state.st_mode));
  }

  auto loaded = CertificateAuthority<Memory>::loadOrCreate(memory, library, descriptor, AuthorityKind::private_local);
  check(loaded.fingerprint() == fingerprint);
  auto system = CertificateAuthority<Memory>::loadOrCreate(memory, library, descriptor, AuthorityKind::system_trust);
  check(system.expiresWithin(std::chrono::days{31}) && !system.expiresWithin(std::chrono::days{29}));
  auto loaded_system = CertificateAuthority<Memory>::loadOrCreate(memory, library, descriptor, AuthorityKind::system_trust);
  check(loaded_system.fingerprint() == system.fingerprint());

  const auto longest = std::string(63, 'a') + "." + std::string(63, 'b') + "." + std::string(63, 'c') + "." + std::string(61, 'd');
  for (const auto &hostname : {std::string{"api.example.com"}, longest}) {
    auto leaf = authority.mint(hostname);
    TlsKey issuer{X509_get_pubkey(authority.certificate())};
    check(X509_verify(leaf.certificate.get(), issuer.get()) == 1);
    check(X509_check_host(leaf.certificate.get(), hostname.data(), hostname.size(), 0, nullptr) == 1);
    check(X509_check_host(leaf.certificate.get(), "another.example.com", 19, 0, nullptr) == 0);
    check(X509_check_ca(leaf.certificate.get()) == 0 && X509_check_private_key(leaf.certificate.get(), leaf.key.get()) == 1);
    check(i2d_X509(leaf.certificate.get(), nullptr) <= static_cast<int>(CertificatePair::maximum_der_bytes));
  }
  for (const auto hostname : {"", "*.example.com", "bad,name", "a..b", "https://example.com"}) {
    rejected([&] { authority.mint(hostname); });
  }

  const PemDocument root{system.certificate()};
  authority.writeBundle(descriptor, root.bytes());
  Vector<unsigned char, Memory> bundle{AllocatorRef<unsigned char, Memory>{memory}};
  check(readPrivateFile(descriptor, "ca-bundle.pem", bundle, PemDocument::maximum_bytes * 2));
  const PemDocument own{authority.certificate()};
  check(bundle.size() == root.bytes().size() + own.bytes().size());
  check(std::equal(root.bytes().begin(), root.bytes().end(), bundle.begin()));
  check(std::equal(own.bytes().begin(), own.bytes().end(), bundle.begin() + root.bytes().size()));

  check(::unlinkat(descriptor, "ca-cert.pem", 0) == 0);
  rejected([&] { CertificateAuthority<Memory>::loadOrCreate(memory, library, descriptor, AuthorityKind::private_local); });
  check(writePrivateFile(descriptor, "ca-cert.pem", own.bytes(), PrivateFileMode::create_only) == 0);
  check(::fchmodat(descriptor, "ca-key.pem", 0644, 0) == 0);
  rejected([&] { CertificateAuthority<Memory>::loadOrCreate(memory, library, descriptor, AuthorityKind::private_local); });
  check(::fchmodat(descriptor, "ca-key.pem", 0600, 0) == 0);

  const auto replacement = CertificatePair::authority("telar local CA", CertificatePair::private_lifetime);
  const PemDocument other_key{replacement.key.get()};
  check(writePrivateFile(descriptor, "ca-key.pem", other_key.bytes(), PrivateFileMode::replace) == 0);
  rejected([&] { CertificateAuthority<Memory>::loadOrCreate(memory, library, descriptor, AuthorityKind::private_local); });
  Vector<unsigned char, Memory> retained{AllocatorRef<unsigned char, Memory>{memory}};
  check(readPrivateFile(descriptor, "ca-key.pem", retained, PemDocument::maximum_bytes) && std::ranges::equal(retained, other_key.bytes()));
  eraseSensitive(retained.data(), retained.size());
}

static void testAuthorityValidation() {
  auto pair = CertificatePair::authority("telar local CA", CertificatePair::private_lifetime);
  pair.validateAuthority("telar local CA", false);
  rejected([&] { pair.validateAuthority("another issuer", false); });
  rejected([&] { pair.validateAuthority("telar local CA", true); });
  const PemDocument key{pair.key.get()};
  const PemDocument certificate{pair.certificate.get()};
  auto decoded = CertificatePair::parse(key.bytes(), certificate.bytes());
  decoded.validateAuthority("telar local CA", false);

  TlsBuffer encrypted{BIO_new(BIO_s_mem())};
  constexpr unsigned char password[] = "fixture";
  check(PEM_write_bio_PrivateKey(encrypted.get(), pair.key.get(), EVP_aes_256_cbc(), password, sizeof(password) - 1, nullptr, nullptr) == 1);
  char *data = nullptr;
  const auto length = BIO_get_mem_data(encrypted.get(), &data);
  rejected([&] { CertificatePair::parse({reinterpret_cast<const unsigned char *>(data), static_cast<std::size_t>(length)}, certificate.bytes()); });

  check(X509_gmtime_adj(X509_getm_notAfter(pair.certificate.get()), -1) != nullptr && X509_sign(pair.certificate.get(), pair.key.get(), EVP_sha256()) > 0);
  rejected([&] { pair.validateAuthority("telar local CA", false); });
}

static void numericCertificates() {
  const auto issuer = CertificatePair::authority("Numeric test", CertificatePair::private_lifetime);
  for (const auto host : {"127.0.0.1", "::1", "2001:db8::1234"}) {
    const auto leaf = issuer.mint(host);
    check(X509_check_ip_asc(leaf.certificate.get(), host, 0) == 1);
    check(X509_check_ip_asc(leaf.certificate.get(), "192.0.2.1", 0) == 0);
  }
}

int main(int argc, char **argv) {
  try {
    SystemAllocator system;
    BudgetAllocator budget{system, 64 * 1024 * 1024};
    SynchronizedAllocator memory{budget};
    {
      const bool tracing = argc == 3 && std::string_view{argv[1]} == "--trace";
#if TELAR_DEBUG
      trace::Session tracing_session{memory, tracing ? argv[2] : nullptr};
#else
      check(!tracing);
#endif
      const TlsLibrary library{memory};
      if (argc == 3 && std::string_view{argv[1]} == "--system-authority") {
        createProxyTrustFixture(memory, library, argv[2]);
      } else if (argc == 3 && std::string_view{argv[1]} == "--system-leaf") {
        FileDescriptor directory{::open(argv[2], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
        check(static_cast<bool>(directory));
        auto authority = CertificateAuthority<decltype(memory)>::loadExisting(memory, library, directory.get(), AuthorityKind::system_trust);
        check(authority.has_value());
        check(!authority->expiresWithin(proxy_trust::rotation_window + std::chrono::hours{24}));
        const auto leaf = authority->mint("validation.invalid");
        const PemDocument certificate{leaf.certificate.get()};
        check(writePrivateFile(directory.get(), "fixture-system-leaf.pem", certificate.bytes(), PrivateFileMode::replace) == 0);
      } else if (argc == 3 && std::string_view{argv[1]} == "--authority") {
        createPrivateDirectory(argv[2]);
        FileDescriptor directory{::open(argv[2], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
        check(static_cast<bool>(directory));
        auto authority = CertificateAuthority<decltype(memory)>::loadOrCreate(memory, library, directory.get(), AuthorityKind::private_local);
        auto leaf = authority.mint("validation.invalid");
        const PemDocument certificate{leaf.certificate.get()};
        check(writePrivateFile(directory.get(), "fixture-leaf.pem", certificate.bytes(), PrivateFileMode::replace) == 0);
        const auto fingerprint = authority.fingerprint();
        std::printf("%.*s\n", static_cast<int>(fingerprint.size()), fingerprint.data());
      } else {
        check(argc == 1 || tracing);
        testTlsMemory();
        testTlsAlpn();
        testTlsSession(memory, library);
        testProxyService(memory, library);
        testTlsTrust(memory, library);
        testProxyTrust(memory, library);
        testAuthorities(memory, library);
        testAuthorityValidation();
        numericCertificates();
      }
    }
    if (budget.liveBytes() != 0) {
      std::fprintf(stderr, "TLS retained %zu bytes after cleanup (%zu allocations)\n", budget.liveBytes(), budget.allocations());
    }
    check(budget.liveBytes() == 0);
    std::puts("TLS tests passed");
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
