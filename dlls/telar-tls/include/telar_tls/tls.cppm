module;
#include "telar_platform/trace_macro.hpp"
#include <stdlib.h>
#include <limits>
#include <utility>
#include <mutex>
#include <new>
#include <string>
#include <vector>
#include <type_traits>
#include <variant>
#include <bit>

#include <exception>
#include <memory>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

#include <string_view>
#include <algorithm>
#include <arpa/inet.h>
#include <array>
#include <cstddef>
#include <optional>

#include <cstring>
#include <cstdint>
#include <span>

#include <chrono>
#include <cstdlib>
#include <ctime>

#include <openssl/crypto.h>
#include <stdexcept>

#include <cerrno>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
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
#include <unistd.h>

#include <concepts>

#include "telar_platform/process_environment.h"

#include <charconv>
#include <spawn.h>
#include <sys/wait.h>

#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif

#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif

#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif

#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif

#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif

#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#endif

export module telar.tls;

export import telar.config;


export import telar.base.memory;


export import telar.platform;


export import telar.base.text;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: telar_tls/handle.cppm
export {
namespace telar::runtime {

class TlsError : public std::exception {
public:
  inline explicit TlsError(const char *operation) noexcept
      : operation_(operation),
        code_(ERR_get_error()) {}

  inline const char *what() const noexcept override {
    return operation_;
  }

  inline unsigned long code() const noexcept {
    return code_;
  }

private:
  const char *operation_;
  unsigned long code_;
};

inline void requireTls(bool succeeded, const char *operation) {
  if (!succeeded) {
    throw TlsError{operation};
  }
}

template <typename Value, auto Destroy>
struct TlsDeleter {
  inline void operator()(Value *value) const noexcept {
    Destroy(value);
  }
};

template <typename Value, auto Destroy>
using TlsHandle = std::unique_ptr<Value, TlsDeleter<Value, Destroy>>;

using TlsKey = TlsHandle<EVP_PKEY, EVP_PKEY_free>;
using TlsCertificate = TlsHandle<X509, X509_free>;
using TlsBuffer = TlsHandle<BIO, BIO_free>;
using TlsContext = TlsHandle<SSL_CTX, SSL_CTX_free>;
using TlsConnection = TlsHandle<SSL, SSL_free>;

}
}

// Interface: telar_tls/hostname.cppm
export {
namespace telar::runtime {

class TlsHostname {
public:
  inline static bool numeric(std::string_view host) noexcept {
    if (host.empty() || host.size() >= INET6_ADDRSTRLEN || host.contains('\0')) { return false; }
    std::array<char, INET6_ADDRSTRLEN> text{};
    std::ranges::copy(host, text.begin());
    in6_addr address{};
    return ::inet_pton(AF_INET, text.data(), &address) == 1 || ::inet_pton(AF_INET6, text.data(), &address) == 1;
  }

  inline static bool valid(std::string_view host) noexcept { return ProxyHostname::validTarget(host) || numeric(host); }
};

}
}

// Interface: telar_tls/pem_document.cppm
export {
namespace telar::runtime {

class PemDocument {
public:
  static constexpr std::size_t maximum_bytes = 4096;

  inline explicit PemDocument(EVP_PKEY *key) {
    requireTls(buffer_ != nullptr, "Allocate TLS key encoding");
    requireTls(PEM_write_bio_PrivateKey(buffer_.get(), key, nullptr, nullptr, 0, nullptr, nullptr) == 1, "Encode TLS private key");
    requireTls(bytes().size() <= maximum_bytes, "TLS private key exceeds its bound");
  }

  inline explicit PemDocument(X509 *certificate) {
    requireTls(buffer_ != nullptr, "Allocate TLS certificate encoding");
    requireTls(PEM_write_bio_X509(buffer_.get(), certificate) == 1, "Encode TLS certificate");
    requireTls(bytes().size() <= maximum_bytes, "TLS certificate exceeds its bound");
  }

  PemDocument(const PemDocument &) = delete;
  PemDocument &operator=(const PemDocument &) = delete;

  inline std::span<const std::uint8_t> bytes() const noexcept {
    char *data = nullptr;
    const auto length = BIO_get_mem_data(buffer_.get(), &data);
    return {reinterpret_cast<const std::uint8_t *>(data), length > 0 ? static_cast<std::size_t>(length) : 0};
  }

private:
  inline static void clearBuffer(BIO *buffer) noexcept {
    BUF_MEM *storage = nullptr;
    BIO_get_mem_ptr(buffer, &storage);
    if (storage != nullptr && storage->data != nullptr) {
      eraseSensitive(storage->data, storage->max);
    }
    BIO_free(buffer);
  }

  TlsHandle<BIO, clearBuffer> buffer_{BIO_new(BIO_s_mem())};
};

}
}

// Interface: telar_tls/certificate_pair.cppm
export {
namespace telar::runtime {

struct CertificatePair {
  static constexpr std::size_t maximum_der_bytes = 2048;
  static constexpr auto backdate = std::chrono::hours{1};
  static constexpr auto private_lifetime = std::chrono::days{3650};
  static constexpr auto system_lifetime = std::chrono::days{30};
  static constexpr auto leaf_lifetime = std::chrono::days{30};

  TlsKey key;
  TlsCertificate certificate;

  inline static CertificatePair authority(std::string_view name, std::chrono::seconds lifetime) {
    TELAR_TRACE("tls.generateAuthority");
    auto pair = create(name, lifetime);
    requireTls(X509_set_issuer_name(pair.certificate.get(), X509_get_subject_name(pair.certificate.get())) == 1, "Set authority issuer");
    extension(pair.certificate.get(), NID_basic_constraints, "critical,CA:TRUE");
    extension(pair.certificate.get(), NID_key_usage, "critical,keyCertSign,cRLSign");
    extension(pair.certificate.get(), NID_subject_key_identifier, "hash");
    pair.sign(pair.key.get());
    return pair;
  }

  inline CertificatePair mint(std::string_view hostname) const {
    TELAR_TRACE("tls.mintCertificate");
    requireTls(TlsHostname::valid(hostname), "Invalid TLS certificate hostname");
    auto leaf = create(hostname, leaf_lifetime);
    requireTls(X509_set_issuer_name(leaf.certificate.get(), X509_get_subject_name(certificate.get())) == 1, "Set leaf issuer");
    extension(leaf.certificate.get(), NID_basic_constraints, "critical,CA:FALSE");
    extension(leaf.certificate.get(), NID_key_usage, "critical,digitalSignature");
    extension(leaf.certificate.get(), NID_ext_key_usage, "serverAuth");
    // Older persisted authorities may lack a subject key identifier. In that
    // case the issuer name and serial still identify the correct signing CA.
    extension(leaf.certificate.get(), NID_authority_key_identifier, "keyid,issuer", certificate.get());

    const std::string_view prefix = TlsHostname::numeric(hostname) ? "IP:" : "DNS:";
    std::array<char, 4 + ProxyHostname::maximum_bytes + 1> alternative{};
    std::copy(prefix.begin(), prefix.end(), alternative.begin());
    std::copy(hostname.begin(), hostname.end(), alternative.begin() + prefix.size());
    extension(leaf.certificate.get(), NID_subject_alt_name, alternative.data());
    leaf.sign(key.get());
    return leaf;
  }

  inline static CertificatePair parse(std::span<const std::uint8_t> key_pem, std::span<const std::uint8_t> certificate_pem) {
    requireTls(!key_pem.empty() && key_pem.size() <= PemDocument::maximum_bytes, "Invalid TLS key size");
    requireTls(!certificate_pem.empty() && certificate_pem.size() <= PemDocument::maximum_bytes, "Invalid TLS certificate size");
    TlsBuffer key_input{BIO_new_mem_buf(key_pem.data(), static_cast<int>(key_pem.size()))};
    TlsBuffer certificate_input{BIO_new_mem_buf(certificate_pem.data(), static_cast<int>(certificate_pem.size()))};
    requireTls(key_input != nullptr && certificate_input != nullptr, "Allocate TLS parser");

    CertificatePair pair;
    pair.key.reset(PEM_read_bio_PrivateKey(key_input.get(), nullptr, &refusePassword, nullptr));
    pair.certificate.reset(PEM_read_bio_X509(certificate_input.get(), nullptr, nullptr, nullptr));
    requireTls(pair.key != nullptr && pair.certificate != nullptr, "Decode TLS authority");
    return pair;
  }

  inline void validateAuthority(std::string_view name, bool system) const {
    requireTls(EVP_PKEY_is_a(key.get(), "EC") == 1, "TLS authority requires an EC key");
    std::array<char, 80> group;
    std::size_t length = 0;
    requireTls(EVP_PKEY_get_group_name(key.get(), group.data(), group.size(), &length) == 1 && std::string_view{group.data(), length} == "prime256v1", "TLS authority requires a P-256 key");
    requireTls(X509_check_private_key(certificate.get(), key.get()) == 1, "TLS authority key does not match its certificate");
    requireTls(X509_verify(certificate.get(), key.get()) == 1, "TLS authority signature is invalid");
    requireTls(X509_check_ca(certificate.get()) > 0, "TLS certificate is not an authority");
    TlsHandle<ASN1_TIME, ASN1_TIME_free> now{ASN1_TIME_set(nullptr, std::time(nullptr))};
    requireTls(now != nullptr, "Read TLS validation time");
    const int begins = ASN1_TIME_compare(X509_get0_notBefore(certificate.get()), now.get());
    const int ends = ASN1_TIME_compare(X509_get0_notAfter(certificate.get()), now.get());
    requireTls(begins >= -1 && begins <= 0 && ends >= 0, "TLS authority is outside its validity period");
    const auto encoded_length = i2d_X509(certificate.get(), nullptr);
    requireTls(encoded_length > 0 && encoded_length <= static_cast<int>(maximum_der_bytes), "TLS authority exceeds its DER bound");

    TlsHandle<X509_NAME, X509_NAME_free> expected{X509_NAME_new()};
    requireTls(expected != nullptr, "Allocate TLS authority name");
    setName(expected.get(), name);
    requireTls(X509_NAME_cmp(expected.get(), X509_get_subject_name(certificate.get())) == 0 && X509_NAME_cmp(expected.get(), X509_get_issuer_name(certificate.get())) == 0, "TLS authority name does not match");
    if (system) {
      int days = 0;
      int seconds = 0;
      requireTls(ASN1_TIME_diff(&days, &seconds, X509_get0_notBefore(certificate.get()), X509_get0_notAfter(certificate.get())) == 1 && std::chrono::days{days} + std::chrono::seconds{seconds} <= system_lifetime + backdate, "TLS system authority lifetime is too long");
    }
  }

private:
  inline static CertificatePair create(std::string_view name, std::chrono::seconds lifetime) {
    TlsHandle<EVP_PKEY_CTX, EVP_PKEY_CTX_free> generator{EVP_PKEY_CTX_new_id(EVP_PKEY_EC, nullptr)};
    requireTls(generator != nullptr, "Allocate TLS key generator");
    requireTls(EVP_PKEY_keygen_init(generator.get()) == 1 && EVP_PKEY_CTX_set_ec_paramgen_curve_nid(generator.get(), NID_X9_62_prime256v1) == 1, "Configure TLS P-256 key generator");
    EVP_PKEY *generated = nullptr;
    const auto result = EVP_PKEY_keygen(generator.get(), &generated);
    CertificatePair pair{TlsKey{generated}, TlsCertificate{X509_new()}};
    requireTls(result == 1 && pair.key != nullptr && pair.certificate != nullptr, "Generate TLS key pair");
    constexpr long version_three = 2;
    requireTls(X509_set_version(pair.certificate.get(), version_three) == 1 && X509_set_pubkey(pair.certificate.get(), pair.key.get()) == 1, "Set TLS certificate public key");

    std::uint64_t serial;
    randomBytes(&serial, sizeof(serial));
    serial >>= 1;
    requireTls(ASN1_INTEGER_set_uint64(X509_get_serialNumber(pair.certificate.get()), serial == 0 ? 1 : serial) == 1, "Set TLS certificate serial");
    const auto backdate_seconds = std::chrono::duration_cast<std::chrono::seconds>(backdate).count();
    requireTls(X509_gmtime_adj(X509_getm_notBefore(pair.certificate.get()), -backdate_seconds) != nullptr && X509_gmtime_adj(X509_getm_notAfter(pair.certificate.get()), lifetime.count()) != nullptr, "Set TLS certificate validity");
    TlsHandle<X509_NAME, X509_NAME_free> subject{X509_NAME_new()};
    requireTls(subject != nullptr, "Allocate TLS certificate subject");
    setName(subject.get(), name);
    requireTls(X509_set_subject_name(pair.certificate.get(), subject.get()) == 1, "Set TLS certificate subject");
    return pair;
  }

  inline static void setName(X509_NAME *destination, std::string_view name) {
    requireTls(!name.empty() && name.size() <= ProxyHostname::maximum_bytes && !name.contains('\0'), "Invalid TLS certificate name");
    requireTls(X509_NAME_add_entry_by_NID(destination, NID_commonName, V_ASN1_UTF8STRING, reinterpret_cast<const unsigned char *>(name.data()), static_cast<int>(name.size()), -1, 0) == 1, "Set TLS certificate name");
  }

  inline static void extension(X509 *certificate, int identifier, const char *value, X509 *issuer = nullptr) {
    X509V3_CTX context{};
    X509V3_set_ctx(&context, issuer, certificate, nullptr, nullptr, 0);
    TlsHandle<X509_EXTENSION, X509_EXTENSION_free> extension{X509V3_EXT_conf_nid(nullptr, &context, identifier, value)};
    requireTls(extension != nullptr && X509_add_ext(certificate, extension.get(), -1) == 1, "Set TLS certificate extension");
  }

  inline void sign(EVP_PKEY *issuer) {
    requireTls(X509_sign(certificate.get(), issuer, EVP_sha256()) > 0, "Sign TLS certificate");
    const auto length = i2d_X509(certificate.get(), nullptr);
    requireTls(length > 0 && length <= static_cast<int>(maximum_der_bytes), "TLS certificate exceeds its DER bound");
  }

  inline static int refusePassword(char *, int, int, void *) noexcept {
    return 0;
  }
};

}
}

// Interface: telar_tls/library.cppm
export {
namespace telar::runtime {

// OPENSSL_cleanup must hand every allocation back before memory_ is cleared;
// only the managed OpenSSL build, patched to clean up immediately, does that.
static_assert(std::string_view{OPENSSL_VERSION_STR} == TELAR_OPENSSL_VERSION, "TLS allocator ownership requires the managed OpenSSL headers");

template <ConcurrentAllocator Memory>
class TlsLibrary {
public:
  inline explicit TlsLibrary(Memory &memory) {
    if (used_ || CRYPTO_set_mem_functions(&allocate, &reallocate, &deallocate) != 1) {
      throw std::logic_error{"TLS allocation must be configured once before using OpenSSL"};
    }

    used_ = true;
    memory_ = &memory;
    if (OPENSSL_init_ssl(OPENSSL_INIT_NO_ATEXIT | OPENSSL_INIT_NO_LOAD_CONFIG, nullptr) != 1) {
      OPENSSL_cleanup();
      memory_ = nullptr;
      throw std::bad_alloc{};
    }
  }

  inline ~TlsLibrary() {
    OPENSSL_cleanup();
    memory_ = nullptr;
  }

  TlsLibrary(const TlsLibrary &) = delete;
  TlsLibrary &operator=(const TlsLibrary &) = delete;

  inline bool uses(const Memory &memory) const noexcept {
    return memory_ == &memory;
  }

private:
  inline static void *allocate(std::size_t size, const char *, int) noexcept {
    if (memory_ == nullptr || size == 0) {
      return nullptr;
    }
    return CAllocationBlocks{*memory_}.allocate(size);
  }

  inline static void deallocate(void *pointer, const char *, int) noexcept {
    if (pointer == nullptr) {
      return;
    }

    CAllocationBlocks{*memory_}.release(pointer);
  }

  inline static void *reallocate(void *pointer, std::size_t size, const char *file, int line) noexcept {
    if (size == 0) {
      deallocate(pointer, file, line);
      return nullptr;
    }

    return memory_ == nullptr ? nullptr : CAllocationBlocks{*memory_}.resize(pointer, size);
  }

  // OpenSSL cannot be reinitialized after cleanup, and its callbacks have no context argument.
  inline static Memory *memory_ = nullptr;
  inline static bool used_ = false;
};

template <ConcurrentAllocator Memory>
TlsLibrary(Memory &memory) -> TlsLibrary<Memory>;

}
}

// Interface: telar_tls/authority.cppm
export {
namespace telar::runtime {

enum class AuthorityKind {
  private_local,
  system_trust
};

struct AuthorityFiles {
  std::string_view key;
  std::string_view certificate;

  static constexpr AuthorityFiles forKind(AuthorityKind kind) noexcept {
    return kind == AuthorityKind::system_trust ? AuthorityFiles{"ca-system-key.pem", "ca-system-cert.pem"} : AuthorityFiles{"ca-key.pem", "ca-cert.pem"};
  }
};

template <ConcurrentAllocator Memory>
class CertificateAuthority {
public:
  static constexpr std::string_view common_name = "telar local CA";

  inline static CertificateAuthority loadOrCreate(Memory &memory, const TlsLibrary<Memory> &library, int directory, AuthorityKind kind) {
    if (auto existing = loadExisting(memory, library, directory, kind)) {
      return std::move(*existing);
    }

    return create(memory, library, directory, AuthorityFiles::forKind(kind), kind);
  }

  inline static std::optional<CertificateAuthority> loadExisting(Memory &memory, const TlsLibrary<Memory> &library, int directory, AuthorityKind kind) {
    TELAR_TRACE("tls.loadAuthority");
    requireTls(library.uses(memory), "TLS authority allocator does not match its library");
    const auto files = AuthorityFiles::forKind(kind);
    ErasingAllocator sensitive_memory{memory};
    Vector<unsigned char, decltype(sensitive_memory)> key_bytes{AllocatorRef<unsigned char, decltype(sensitive_memory)>{sensitive_memory}};
    Vector<unsigned char, Memory> certificate_bytes{AllocatorRef<unsigned char, Memory>{memory}};
    const bool has_key = readPrivateFile(directory, files.key, key_bytes, PemDocument::maximum_bytes);
    const bool has_certificate = readPrivateFile(directory, files.certificate, certificate_bytes, PemDocument::maximum_bytes);
    requireTls(has_key == has_certificate, "TLS authority is incomplete");

    if (!has_key) {
      return std::nullopt;
    }

    auto pair = CertificatePair::parse(key_bytes, certificate_bytes);
    pair.validateAuthority(common_name, kind == AuthorityKind::system_trust);
    return CertificateAuthority{memory, std::move(pair)};
  }

  inline static CertificateAuthority create(Memory &memory, const TlsLibrary<Memory> &library, int directory, AuthorityFiles files, AuthorityKind kind) {
    requireTls(library.uses(memory), "TLS authority allocator does not match its library");
    const auto lifetime = kind == AuthorityKind::system_trust ? CertificatePair::system_lifetime : CertificatePair::private_lifetime;
    auto pair = CertificatePair::authority(common_name, lifetime);
    const PemDocument key{pair.key.get()};
    const PemDocument certificate{pair.certificate.get()};
    if (const int error = writePrivateFile(directory, files.key, key.bytes(), PrivateFileMode::create_only)) {
      throw SystemError{"Publish TLS authority key", error};
    }
    if (const int error = writePrivateFile(directory, files.certificate, certificate.bytes(), PrivateFileMode::create_only)) {
      std::array<char, NAME_MAX + 1> name{};
      std::copy(files.key.begin(), files.key.end(), name.begin());
      ::unlinkat(directory, name.data(), 0);
      throw SystemError{"Publish TLS authority certificate", error};
    }

    return CertificateAuthority{memory, std::move(pair)};
  }

  inline CertificatePair mint(std::string_view hostname) const {
    return pair_.mint(hostname);
  }

  inline X509 *certificate() const noexcept {
    return pair_.certificate.get();
  }

  inline std::array<char, 40> fingerprint() const {
    return fingerprint<20>(EVP_sha1());
  }

  inline std::array<char, 64> fingerprintSha256() const {
    return fingerprint<32>(EVP_sha256());
  }

private:
  template <std::size_t digest_bytes>
  inline std::array<char, digest_bytes * 2> fingerprint(const EVP_MD *algorithm) const {
    std::array<unsigned char, EVP_MAX_MD_SIZE> digest;
    unsigned length = 0;
    requireTls(X509_digest(certificate(), algorithm, digest.data(), &length) == 1 && length == digest_bytes, "Compute TLS authority fingerprint");
    constexpr std::string_view hexadecimal = "0123456789ABCDEF";
    std::array<char, digest_bytes * 2> result;
    for (std::size_t index = 0; index < digest_bytes; ++index) {
      result[index * 2] = hexadecimal[digest[index] >> 4];
      result[index * 2 + 1] = hexadecimal[digest[index] & 15];
    }
    return result;
  }

public:
  inline bool expiresWithin(std::chrono::seconds duration) const {
    TlsHandle<ASN1_TIME, ASN1_TIME_free> deadline{ASN1_TIME_adj(nullptr, std::time(nullptr), 0, duration.count())};
    requireTls(deadline != nullptr, "Compute TLS authority expiration deadline");
    const int comparison = ASN1_TIME_compare(X509_get0_notAfter(certificate()), deadline.get());
    requireTls(comparison != -2, "Read TLS authority expiration");
    return comparison <= 0;
  }

  inline void writeBundle(int directory, std::span<const std::uint8_t> roots) const {
    constexpr std::size_t maximum_root_bytes = 4 * 1024 * 1024;
    requireTls(roots.size() <= maximum_root_bytes, "TLS root bundle exceeds its bound");
    const PemDocument own{certificate()};
    Vector<std::uint8_t, Memory> bundle{AllocatorRef<std::uint8_t, Memory>{memory_}};
    bundle.reserve(roots.size() + own.bytes().size());
    bundle.insert(bundle.end(), roots.begin(), roots.end());
    bundle.insert(bundle.end(), own.bytes().begin(), own.bytes().end());
    if (const int error = writePrivateFile(directory, "ca-bundle.pem", bundle, PrivateFileMode::replace)) {
      throw SystemError{"Publish TLS trust bundle", error};
    }
  }

private:
  inline explicit CertificateAuthority(Memory &memory, CertificatePair pair) noexcept
      : memory_(memory),
        pair_(std::move(pair)) {}

  Memory &memory_;
  CertificatePair pair_;
};

}
}

// Interface: telar_tls/authority_directory.cppm
export {
namespace telar::runtime {

template <Allocator Memory, EnvironmentLookup Environment>
String<Memory> proxyAuthorityDirectory(Memory &memory, const Environment &environment) {
  String<Memory> path{environment.lookup("XDG_DATA_HOME"), AllocatorRef<char, Memory>{memory}};
  if (path.empty() || path.front() != '/') {
    path = environment.lookup("HOME");
    if (path.empty()) {
      throw std::invalid_argument{"Home directory unavailable for proxy"};
    }

    path += "/.local/share";
  }

  path += "/telar/proxy";
  return path;
}

}
}

// Interface: telar_tls/trust/command.cppm
export {

namespace telar::runtime::proxy_trust {

template <typename Executor>
concept TrustCommandExecutor = requires(Executor &executor, std::span<const std::string_view> arguments) {
  { executor.run(arguments) } -> std::same_as<void>;
};

template <Allocator Memory>
class SystemCommand {
public:
  inline explicit SystemCommand(Memory &memory, FILE *output) noexcept : memory_(memory), output_(output) {}

  inline void run(std::span<const std::string_view> arguments) {
    Vector<String<Memory>, Memory> owned{AllocatorRef<String<Memory>, Memory>{memory_}};
    Vector<char *, Memory> pointers{AllocatorRef<char *, Memory>{memory_}};
    String<Memory> line{"telar proxy trust: exec", AllocatorRef<char, Memory>{memory_}};
    owned.reserve(arguments.size());
    pointers.reserve(arguments.size() + 1);
    for (const auto argument : arguments) {
      if (argument.contains('\0')) {
        throw std::invalid_argument{"Invalid proxy trust command argument"};
      }

      owned.emplace_back(argument, AllocatorRef<char, Memory>{memory_});
      line += ' ';
      appendJsonString(line, argument);
    }

    line += '\n';
    if (std::fwrite(line.data(), 1, line.size(), output_) != line.size() || std::fflush(output_) != 0) {
      throw SystemError{"Print proxy trust command", EIO};
    }
    for (auto &argument : owned) {
      pointers.push_back(argument.data());
    }
    pointers.push_back(nullptr);

    pid_t child;
    if (const int error = ::posix_spawn(&child, pointers.front(), nullptr, nullptr, pointers.data(), environ)) {
      throw SystemError{"Start proxy trust command", error};
    }

    int status;
    pid_t waited;
    do {
      waited = ::waitpid(child, &status, 0);
    } while (waited < 0 && errno == EINTR);
    if (waited < 0) {
      throw SystemError{"Wait for proxy trust command"};
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
      throw SystemError{"Proxy trust command failed", EIO};
    }
  }

private:
  Memory &memory_;
  FILE *output_;
};

template <Allocator Memory>
SystemCommand(Memory &memory, FILE *output) -> SystemCommand<Memory>;

}
}

// Interface: telar_tls/trust/record.cppm
export {
namespace telar::runtime::proxy_trust {

enum class Backend { macos,
                     update_ca_certificates,
                     trust };

inline std::string_view backendName(Backend backend) noexcept {
  switch (backend) {
  case Backend::macos:
    return "macos";
  case Backend::update_ca_certificates:
    return "update-ca-certificates";
  case Backend::trust:
    return "trust";
  }

  std::unreachable();
}

struct Record {
  static constexpr std::string_view filename = "trust-install.json";
  static constexpr std::size_t maximum_bytes = 4096;

  Backend backend = Backend::macos;
  std::array<char, 40> fingerprint;
  FixedText<PATH_MAX> store;

  template <Allocator Memory>
  inline static Record parse(Memory &memory, std::string_view source) {
    validateUtf8(source);
    constexpr auto names = std::to_array<std::string_view>({"version", "backend", "fingerprint", "store_path"});
    JsonFields fields{memory, JsonValue::parse(source), names};
    if (!SchemaVersion<Memory>::isOne(memory, fields.required("version"))) {
      throw std::invalid_argument{"Invalid proxy trust record version"};
    }

    Record record;
    const auto backend = fields.string("backend");
    if (backend == "macos") {
      record.backend = Backend::macos;
    } else if (backend == "update-ca-certificates") {
      record.backend = Backend::update_ca_certificates;
    } else if (backend == "trust") {
      record.backend = Backend::trust;
    } else {
      throw std::invalid_argument{"Invalid proxy trust backend"};
    }

    const auto fingerprint = fields.string("fingerprint");
    if (fingerprint.size() != record.fingerprint.size()) {
      throw std::invalid_argument{"Invalid proxy trust fingerprint"};
    }
    for (std::size_t index = 0; index < fingerprint.size(); ++index) {
      const char byte = fingerprint[index];
      if (byte >= 'a' && byte <= 'f') {
        record.fingerprint[index] = byte - 'a' + 'A';
      } else if ((byte >= 'A' && byte <= 'F') || (byte >= '0' && byte <= '9')) {
        record.fingerprint[index] = byte;
      } else {
        throw std::invalid_argument{"Invalid proxy trust fingerprint"};
      }
    }

    const auto store = fields.string("store_path");
    if (store.empty() || store.front() != '/' || store.contains('\0')) {
      throw std::invalid_argument{"Invalid proxy trust store path"};
    }

    record.store.assign(store);
    return record;
  }

  template <Allocator Memory>
  inline static std::optional<Record> read(Memory &memory, int directory) {
    Vector<unsigned char, Memory> source{AllocatorRef<unsigned char, Memory>{memory}};
    if (!readPrivateFile(directory, filename, source, maximum_bytes - 1)) {
      return std::nullopt;
    }

    return parse(memory, {reinterpret_cast<const char *>(source.data()), source.size()});
  }

  template <Allocator Memory>
  inline void write(Memory &memory, int directory) const {
    String<Memory> source{"{\n  \"version\": 1,\n  \"backend\": ", AllocatorRef<char, Memory>{memory}};
    appendJsonString(source, backendName(backend));
    source += ",\n  \"fingerprint\": ";
    appendJsonString(source, {fingerprint.data(), fingerprint.size()});
    source += ",\n  \"store_path\": ";
    appendJsonString(source, store.view());
    source += "\n}\n";
    if (source.size() > maximum_bytes) {
      throw std::length_error{"Proxy trust record exceeds its bound"};
    }
    if (const int error = writePrivateFile(directory, filename, {reinterpret_cast<const unsigned char *>(source.data()), source.size()}, PrivateFileMode::replace)) {
      throw SystemError{"Publish proxy trust record", error};
    }
  }
};

}
}

// Interface: telar_tls/trust/destination.cppm
export {
namespace telar::runtime::proxy_trust {

inline constexpr std::string_view linux_certificate_path = "/usr/local/share/ca-certificates/telar-proxy.crt";

struct Destination {
  inline Destination(std::string_view path) : Destination(Backend::macos, path) {}

  template <typename Text>
    requires std::convertible_to<const Text &, std::string_view>
  Destination(const Text &path) : Destination(std::string_view{path}) {}

  inline Destination(Backend selected, std::string_view path) : backend(selected) {
    store.assign(path);
  }

  Backend backend;
  FixedText<PATH_MAX> store;
};

}
}

// Interface: telar_tls/trust/paths.cppm
export {
namespace telar::runtime::proxy_trust {

template <Allocator Memory>
class Paths {
public:
  inline explicit Paths(Memory &memory, std::string_view directory)
      : directory_(directory, AllocatorRef<char, Memory>{memory}) {
    if (directory.empty() || directory.front() != '/' || directory.contains('\0') || directory.size() + AuthorityFiles::forKind(AuthorityKind::system_trust).certificate.size() + 1 >= PATH_MAX) {
      throw std::invalid_argument{"Proxy authority directory must be an absolute bounded path"};
    }
  }

  inline const String<Memory> &directory() const noexcept { return directory_; }

  inline String<Memory> file(std::string_view name) const {
    auto path = directory_;
    path += '/';
    path += name;
    if (path.size() >= PATH_MAX) {
      throw std::length_error{"Proxy authority file path exceeds its bound"};
    }

    return path;
  }

  inline FileDescriptor open() const {
    // A path that names no directory holds no trust record, as for Zig.
    FileDescriptor descriptor{::open(directory_.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
    if (!descriptor && errno != ENOENT && errno != ENOTDIR) {
      throw SystemError{"Open proxy authority directory"};
    }

    return descriptor;
  }

  inline FileDescriptor prepare() const {
    createPrivateDirectory(directory_);
    auto descriptor = open();
    if (!descriptor) {
      throw SystemError{"Open prepared proxy authority directory", ENOENT};
    }

    validateDirectory(descriptor.get());
    return descriptor;
  }

  inline static void validateDirectory(int descriptor) {
    struct stat state{};
    if (::fstat(descriptor, &state) != 0 || !S_ISDIR(state.st_mode) || state.st_uid != ::geteuid() || (state.st_mode & 0077) != 0) {
      throw SystemError{"Validate proxy authority directory", EACCES};
    }
  }

  template <EnvironmentLookup Environment>
  inline static String<Memory> keychain(Memory &memory, const Environment &environment) {
    const auto home = environment.lookup("HOME");
    String<Memory> result{home, AllocatorRef<char, Memory>{memory}};
    if (home.empty()) {
      return result;
    }

    result += "/Library/Keychains/login.keychain-db";
    if (result.front() != '/' || result.size() > PATH_MAX || result.contains('\0')) {
      throw std::invalid_argument{"Invalid proxy trust keychain path"};
    }

    return result;
  }

  template <EnvironmentLookup Environment>
  inline Destination nativeDestination(Memory &memory, const Environment &environment, std::optional<Backend> selected = std::nullopt) const {
#if defined(__APPLE__)
    if (selected && *selected != Backend::macos) {
      throw std::invalid_argument{"Linux trust backend is not supported on macOS"};
    }
    return Destination{keychain(memory, environment)};
#else
    (void)environment;
    auto backend = selected.value_or(Backend::trust);
    if (!selected) {
      const auto directory = open();
      if (directory) {
        if (const auto record = Record::read(memory, directory.get())) {
          backend = record->backend;
        }
      }
    }
    if (backend == Backend::macos) {
      throw std::invalid_argument{"macOS trust backend is not supported on Linux"};
    }
    return Destination{backend, backend == Backend::trust ? std::string_view{file(AuthorityFiles::forKind(AuthorityKind::system_trust).certificate)} : linux_certificate_path};
#endif
  }

private:
  String<Memory> directory_;
};

template <Allocator Memory>
Paths(Memory &memory, std::string_view directory) -> Paths<Memory>;

}
}

// Interface: telar_tls/trust/inspection.cppm
export {
namespace telar::runtime::proxy_trust {

enum class Status { absent,
                    installed,
                    stale };

inline std::string_view statusName(Status status) noexcept {
  switch (status) {
  case Status::absent:
    return "absent";
  case Status::installed:
    return "installed";
  case Status::stale:
    return "stale";
  }

  std::unreachable();
}

struct Inspection {
  Status status = Status::absent;
  std::optional<Record> record;
};

inline constexpr auto rotation_window = std::chrono::hours{24};

inline void validateTarget(const Record &record, const Destination &destination) {
  if (record.backend != destination.backend || record.store.view() != destination.store.view()) {
    throw std::invalid_argument{"Invalid proxy trust record target"};
  }
}

template <ConcurrentAllocator Memory>
Inspection inspect(Memory &memory, const TlsLibrary<Memory> &library, const Paths<Memory> &paths, const Destination &destination) noexcept {
  Inspection result;
  try {
    const auto directory = paths.open();
    if (!directory) {
      return result;
    }

    result.record = Record::read(memory, directory.get());
    if (!result.record) {
      return result;
    }

    validateTarget(*result.record, destination);
    Paths<Memory>::validateDirectory(directory.get());
    const auto authority = CertificateAuthority<Memory>::loadExisting(memory, library, directory.get(), AuthorityKind::system_trust);
    result.status = authority && authority->fingerprint() == result.record->fingerprint && !authority->expiresWithin(rotation_window) ? Status::installed : Status::stale;
  } catch (...) {
    result.status = Status::stale;
  }

  return result;
}

}
}

// Interface: telar_tls/trust/prepared_authority.cppm
export {
namespace telar::runtime::proxy_trust {

struct AuthorityPreparation {
  AuthorityKind kind = AuthorityKind::system_trust;
  bool force_rotation = false;
};

template <ConcurrentAllocator Memory>
class PreparedAuthority {
public:
  inline explicit PreparedAuthority(Memory &memory, const TlsLibrary<Memory> &library, int directory, AuthorityPreparation options = {})
      : directory_(directory), canonical_(AuthorityFiles::forKind(options.kind)) {
    try {
      auto existing = CertificateAuthority<Memory>::loadExisting(memory, library, directory, options.kind);
      if (existing && !options.force_rotation && !existing->expiresWithin(rotation_window)) {
        authority_.emplace(std::move(*existing));
        return;
      }
    } catch (const TlsError &) {
    } catch (const SystemError &) {
    }

    std::uint64_t nonce;
    randomBytes(&nonce, sizeof(nonce));
    makeName(key_, canonical_.key, "rotate", nonce);
    makeName(certificate_, canonical_.certificate, "rotate", nonce);
    makeName(previous_key_, canonical_.key, "previous", nonce);
    makeName(previous_certificate_, canonical_.certificate, "previous", nonce);
    authority_.emplace(CertificateAuthority<Memory>::create(memory, library, directory, {key_.data(), certificate_.data()}, options.kind));
    temporary_ = true;
  }

  inline ~PreparedAuthority() {
    if (activated_ && !committed_) {
      restore(certificate_, canonical_.certificate.data());
      restore(key_, canonical_.key.data());
    }
    if (saved_certificate_) {
      restorePrevious(previous_certificate_, canonical_.certificate.data());
    }
    if (saved_key_) {
      restorePrevious(previous_key_, canonical_.key.data());
    }
    if (temporary_) {
      ::unlinkat(directory_, key_.data(), 0);
      ::unlinkat(directory_, certificate_.data(), 0);
    }
  }

  PreparedAuthority(const PreparedAuthority &) = delete;
  PreparedAuthority &operator=(const PreparedAuthority &) = delete;

  inline std::string_view certificateName() const noexcept {
    return temporary_ && !activated_ ? std::string_view{certificate_.data()} : canonical_.certificate;
  }

  inline const CertificateAuthority<Memory> &authority() const noexcept { return *authority_; }

  inline void activate() {
    if (!temporary_) {
      return;
    }

    saved_key_ = savePrevious(canonical_.key.data(), previous_key_);
    saved_certificate_ = savePrevious(canonical_.certificate.data(), previous_certificate_);
    rename(key_.data(), canonical_.key.data());
    try {
      rename(certificate_.data(), canonical_.certificate.data());
    } catch (...) {
      restore(key_, canonical_.key.data());
      throw;
    }

    activated_ = true;
  }

  inline void commit() noexcept {
    committed_ = true;
    if (saved_key_) {
      ::unlinkat(directory_, previous_key_.data(), 0);
      saved_key_ = false;
    }
    if (saved_certificate_) {
      ::unlinkat(directory_, previous_certificate_.data(), 0);
      saved_certificate_ = false;
    }
  }

private:
  using Filename = std::array<char, NAME_MAX + 1>;

  inline static void makeName(Filename &output, std::string_view base, const char *operation, std::uint64_t nonce) {
    const int size = std::snprintf(output.data(), output.size(), "%.*s.%s-%016llx", static_cast<int>(base.size()), base.data(), operation, static_cast<unsigned long long>(nonce));
    if (size < 0 || static_cast<std::size_t>(size) >= output.size()) {
      throw std::length_error{"Proxy authority temporary filename exceeds its bound"};
    }
  }

  inline void rename(const char *source, const char *destination) {
    if (renameAt(directory_, source, directory_, destination, RenameMode::create_only) != 0) {
      throw SystemError{"Activate proxy authority"};
    }
  }

  inline bool savePrevious(const char *source, const Filename &destination) {
    if (renameAt(directory_, source, directory_, destination.data(), RenameMode::create_only) == 0) {
      return true;
    }
    if (errno == ENOENT) {
      return false;
    }

    throw SystemError{"Preserve previous proxy authority"};
  }

  inline void restore(const Filename &temporary, const char *canonical) noexcept {
    if (::renameat(directory_, canonical, directory_, temporary.data()) != 0) {
      std::fprintf(stderr, "telar proxy trust: could not roll back %s: %s\n", canonical, std::strerror(errno));
    }
  }

  inline void restorePrevious(const Filename &previous, const char *canonical) noexcept {
    if (::renameat(directory_, previous.data(), directory_, canonical) != 0) {
      std::fprintf(stderr, "telar proxy trust: could not restore %s: %s\n", canonical, std::strerror(errno));
    }
  }

  int directory_;
  AuthorityFiles canonical_;
  std::optional<CertificateAuthority<Memory>> authority_;
  Filename key_;
  Filename certificate_;
  Filename previous_key_;
  Filename previous_certificate_;
  bool temporary_ = false;
  bool activated_ = false;
  bool committed_ = false;
  bool saved_key_ = false;
  bool saved_certificate_ = false;
};

template <ConcurrentAllocator Memory>
PreparedAuthority(Memory &memory, const TlsLibrary<Memory> &library, int directory) -> PreparedAuthority<Memory>;

}
}

// Interface: telar_tls/trust/service.cppm
export {
namespace telar::runtime::proxy_trust {

enum class Action { install, uninstall, rotate };

template <ConcurrentAllocator Memory, TrustCommandExecutor Executor>
class Service {
public:
  inline explicit Service(Memory &memory, const TlsLibrary<Memory> &library, const Paths<Memory> &paths, Executor &executor, Destination destination) noexcept
      : memory_(memory), library_(library), paths_(paths), executor_(executor), destination_(destination) {}

  inline Inspection inspect() const noexcept {
    return proxy_trust::inspect(memory_, library_, paths_, destination_);
  }

  inline Record install(const std::optional<Record> &previous, bool force_rotation = false) {
    TELAR_TRACE("proxy.installSystemTrust");
    if (destination_.store.view().empty()) {
      throw std::invalid_argument{"Home directory unavailable for proxy trust"};
    }
    if (previous) {
      validateTarget(*previous, destination_);
    }

    const auto directory = paths_.prepare();
    PreparedAuthority prepared{memory_, library_, directory.get(), AuthorityPreparation{.force_rotation = force_rotation}};
    const auto certificate = paths_.file(prepared.certificateName());
    Record replacement;
    replacement.backend = destination_.backend;
    replacement.fingerprint = prepared.authority().fingerprint();
    replacement.store = destination_.store;
    installAuthority(certificate);

    try {
      if (previous && previous->fingerprint != replacement.fingerprint && previous->backend != Backend::update_ca_certificates) {
        remove(*previous);
      }

      prepared.activate();
      replacement.write(memory_, directory.get());
      prepared.commit();
    } catch (...) {
      try {
        remove(replacement);
      } catch (const std::exception &error) {
        std::fprintf(stderr, "telar proxy trust: could not remove partially installed authority: %s\n", error.what());
      }

      throw;
    }

    return replacement;
  }

  inline void uninstall(const Record &record) {
    TELAR_TRACE("proxy.removeSystemTrust");
    validateTarget(record, destination_);
    const auto directory = paths_.open();
    if (!directory) {
      throw SystemError{"Proxy trust record disappeared", ENOENT};
    }

    remove(record);
    if (::unlinkat(directory.get(), Record::filename.data(), 0) != 0) {
      throw SystemError{"Remove proxy trust record"};
    }
  }

  inline std::optional<Record> rotateIfNeeded() {
    const auto current = inspect();
    if (current.status != Status::stale || !current.record) {
      return std::nullopt;
    }
    if (destination_.backend != Backend::macos) {
      return std::nullopt;
    }

    return install(current.record);
  }

private:
  inline void installAuthority(std::string_view certificate) {
    switch (destination_.backend) {
    case Backend::macos:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-k", destination_.store.view(), certificate}));
      break;
    case Backend::update_ca_certificates:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/bin/install", "-m", "0644", certificate, destination_.store.view()}));
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/sbin/update-ca-certificates"}));
      break;
    case Backend::trust:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/bin/trust", "anchor", certificate}));
      break;
    }
  }

  inline void remove(const Record &record) {
    switch (record.backend) {
    case Backend::macos:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/security", "delete-certificate", "-t", "-Z", {record.fingerprint.data(), record.fingerprint.size()}, record.store.view()}));
      break;
    case Backend::update_ca_certificates:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/bin/rm", "-f", record.store.view()}));
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/sbin/update-ca-certificates"}));
      break;
    case Backend::trust:
      executor_.run(std::to_array<std::string_view>({"/usr/bin/sudo", "--", "/usr/bin/trust", "anchor", "--remove", record.store.view()}));
      break;
    }
  }

  Memory &memory_;
  const TlsLibrary<Memory> &library_;
  const Paths<Memory> &paths_;
  Executor &executor_;
  Destination destination_;
};

template <ConcurrentAllocator Memory, TrustCommandExecutor Executor>
Service(Memory &memory, const TlsLibrary<Memory> &library, const Paths<Memory> &paths, Executor &executor, Destination destination) -> Service<Memory, Executor>;

}
}
