#pragma once

#include "../error.hpp"
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <span>

namespace telar::runtime {

class SystemCertificates {
  struct FreeEncoded {
    void operator()(unsigned char *bytes) const noexcept { OPENSSL_free(bytes); }
  };

public:
  template <typename Consumer>
  static void read(Consumer &&consume) {
    const auto *path = std::getenv(X509_get_default_cert_file_env());
    if (path == nullptr || path[0] == '\0') {
      path = X509_get_default_cert_file();
    }

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
