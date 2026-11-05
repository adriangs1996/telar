#pragma once

#include "telar_platform/error.hpp"
#include <array>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <span>
#include <unistd.h>

namespace telar::runtime {

class SystemCertificates {
  struct FreeEncoded {
    void operator()(unsigned char *bytes) const noexcept { OPENSSL_free(bytes); }
  };

  // telar links its own OpenSSL, whose default bundle path matches only some
  // distributions. These are the bundles Go's crypto/x509 looks for, in order.
  static constexpr std::array bundles{
    "/etc/ssl/certs/ca-certificates.crt",                // Debian, Ubuntu, Gentoo and others
    "/etc/pki/tls/certs/ca-bundle.crt",                  // Fedora, RHEL 6
    "/etc/ssl/ca-bundle.pem",                            // openSUSE
    "/etc/pki/tls/cacert.pem",                           // OpenELEC
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", // CentOS, RHEL 7
    "/etc/ssl/cert.pem",                                 // Alpine
  };

  static const char *bundle() noexcept {
    const auto *path = std::getenv(X509_get_default_cert_file_env());
    if (path != nullptr && path[0] != '\0') {
      return path;
    }

    for (const auto *candidate : bundles) {
      if (::access(candidate, R_OK) == 0) {
        return candidate;
      }
    }

    return bundles.back();
  }

public:
  template <typename Consumer>
  static void read(Consumer &&consume) {
    const auto *path = bundle();
    const std::unique_ptr<BIO, decltype(&BIO_free)> file{BIO_new_file(path, "r"), &BIO_free};
    if (!file) {
      throw SystemError{"Open system certificate bundle", EACCES};
    }

    std::size_t count = 0;
    for (;;) {
      const std::unique_ptr<X509, decltype(&X509_free)> certificate{PEM_read_bio_X509_AUX(file.get(), nullptr, nullptr, nullptr), &X509_free};
      if (!certificate) {
        if (!BIO_eof(file.get()) || count == 0) {
          throw SystemError{"Read system certificate bundle", EINVAL};
        }
        ERR_clear_error();
        return;
      }
      ++count;
      if (X509_check_trust(certificate.get(), X509_TRUST_SSL_SERVER, 0) == X509_TRUST_REJECTED) {
        continue;
      }

      unsigned char *encoded = nullptr;
      const auto length = i2d_X509(certificate.get(), &encoded);
      const std::unique_ptr<unsigned char, FreeEncoded> bytes{encoded};
      if (length <= 0 || encoded == nullptr) {
        throw SystemError{"Encode system certificate", EINVAL};
      }
      consume(std::span<const std::uint8_t>{bytes.get(), static_cast<std::size_t>(length)});
    }
  }
};

}
