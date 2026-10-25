#pragma once

#include "inspection.hpp"

namespace telar::runtime::proxy_trust {

template <ConcurrentAllocator Memory>
class PreparedAuthority {
public:
  explicit PreparedAuthority(Memory &memory, const TlsLibrary<Memory> &library, int directory)
      : directory_(directory) {
    try {
      auto existing = CertificateAuthority<Memory>::loadExisting(memory, library, directory, AuthorityKind::system_trust);
      if (existing && !existing->expiresWithin(rotation_window)) {
        authority_.emplace(std::move(*existing));
        return;
      }
    } catch (const TlsError &) {
    } catch (const SystemError &) {
    }

    std::uint64_t nonce;
    ::arc4random_buf(&nonce, sizeof(nonce));
    const auto canonical = AuthorityFiles::forKind(AuthorityKind::system_trust);
    makeName(key_, canonical.key, "rotate", nonce);
    makeName(certificate_, canonical.certificate, "rotate", nonce);
    makeName(previous_key_, canonical.key, "previous", nonce);
    makeName(previous_certificate_, canonical.certificate, "previous", nonce);
    authority_.emplace(CertificateAuthority<Memory>::create(memory, library, directory, {key_.data(), certificate_.data()}, AuthorityKind::system_trust));
    temporary_ = true;
  }

  ~PreparedAuthority() {
    if (activated_ && !committed_) {
      restore(certificate_, canonical_certificate);
      restore(key_, canonical_key);
    }
    if (saved_certificate_) {
      restorePrevious(previous_certificate_, canonical_certificate);
    }
    if (saved_key_) {
      restorePrevious(previous_key_, canonical_key);
    }
    if (temporary_) {
      ::unlinkat(directory_, key_.data(), 0);
      ::unlinkat(directory_, certificate_.data(), 0);
    }
  }

  PreparedAuthority(const PreparedAuthority &) = delete;
  PreparedAuthority &operator=(const PreparedAuthority &) = delete;

  std::string_view certificateName() const noexcept {
    return temporary_ && !activated_ ? std::string_view{certificate_.data()} : canonical_certificate;
  }

  const CertificateAuthority<Memory> &authority() const noexcept { return *authority_; }

  void activate() {
    if (!temporary_) {
      return;
    }

    saved_key_ = savePrevious(canonical_key, previous_key_);
    saved_certificate_ = savePrevious(canonical_certificate, previous_certificate_);
    rename(key_.data(), canonical_key);
    try {
      rename(certificate_.data(), canonical_certificate);
    } catch (...) {
      restore(key_, canonical_key);
      throw;
    }

    activated_ = true;
  }

  void commit() noexcept {
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
  static constexpr const char *canonical_key = "ca-system-key.pem";
  static constexpr const char *canonical_certificate = "ca-system-cert.pem";

  static void makeName(Filename &output, std::string_view base, const char *operation, std::uint64_t nonce) {
    const int size = std::snprintf(output.data(), output.size(), "%.*s.%s-%016llx", static_cast<int>(base.size()), base.data(), operation, static_cast<unsigned long long>(nonce));
    if (size < 0 || static_cast<std::size_t>(size) >= output.size()) {
      throw std::length_error{"Proxy authority temporary filename exceeds its bound"};
    }
  }

  void rename(const char *source, const char *destination) {
    if (::renameatx_np(directory_, source, directory_, destination, RENAME_EXCL) != 0) {
      throw SystemError{"Activate proxy authority"};
    }
  }

  bool savePrevious(const char *source, const Filename &destination) {
    if (::renameatx_np(directory_, source, directory_, destination.data(), RENAME_EXCL) == 0) {
      return true;
    }
    if (errno == ENOENT) {
      return false;
    }

    throw SystemError{"Preserve previous proxy authority"};
  }

  void restore(const Filename &temporary, const char *canonical) noexcept {
    if (::renameat(directory_, canonical, directory_, temporary.data()) != 0) {
      std::fprintf(stderr, "telar proxy trust: could not roll back %s: %s\n", canonical, std::strerror(errno));
    }
  }

  void restorePrevious(const Filename &previous, const char *canonical) noexcept {
    if (::renameat(directory_, previous.data(), directory_, canonical) != 0) {
      std::fprintf(stderr, "telar proxy trust: could not restore %s: %s\n", canonical, std::strerror(errno));
    }
  }

  int directory_;
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

}
