#pragma once

#include "../platform/write_private_file.hpp"
#include "certificate_pair.hpp"
#include "library.hpp"
#include "telar_base/memory/erasing_allocator.hpp"
#include "telar_platform/private_file.hpp"
#include <optional>

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

  static CertificateAuthority loadOrCreate(Memory &memory, const TlsLibrary<Memory> &library, int directory, AuthorityKind kind) {
    if (auto existing = loadExisting(memory, library, directory, kind)) {
      return std::move(*existing);
    }

    return create(memory, library, directory, AuthorityFiles::forKind(kind), kind);
  }

  static std::optional<CertificateAuthority> loadExisting(Memory &memory, const TlsLibrary<Memory> &library, int directory, AuthorityKind kind) {
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

  static CertificateAuthority create(Memory &memory, const TlsLibrary<Memory> &library, int directory, AuthorityFiles files, AuthorityKind kind) {
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

  CertificatePair mint(std::string_view hostname) const {
    return pair_.mint(hostname);
  }

  X509 *certificate() const noexcept {
    return pair_.certificate.get();
  }

  std::array<char, 40> fingerprint() const {
    return fingerprint<20>(EVP_sha1());
  }

  std::array<char, 64> fingerprintSha256() const {
    return fingerprint<32>(EVP_sha256());
  }

private:
  template <std::size_t digest_bytes>
  std::array<char, digest_bytes * 2> fingerprint(const EVP_MD *algorithm) const {
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
  bool expiresWithin(std::chrono::seconds duration) const {
    TlsHandle<ASN1_TIME, ASN1_TIME_free> deadline{ASN1_TIME_adj(nullptr, std::time(nullptr), 0, duration.count())};
    requireTls(deadline != nullptr, "Compute TLS authority expiration deadline");
    const int comparison = ASN1_TIME_compare(X509_get0_notAfter(certificate()), deadline.get());
    requireTls(comparison != -2, "Read TLS authority expiration");
    return comparison <= 0;
  }

  void writeBundle(int directory, std::span<const std::uint8_t> roots) const {
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
  explicit CertificateAuthority(Memory &memory, CertificatePair pair) noexcept
      : memory_(memory),
        pair_(std::move(pair)) {}

  Memory &memory_;
  CertificatePair pair_;
};

}
