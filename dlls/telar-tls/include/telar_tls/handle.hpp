#pragma once

#include <exception>
#include <memory>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

namespace telar::runtime {

class TlsError : public std::exception {
public:
  explicit TlsError(const char *operation) noexcept
      : operation_(operation),
        code_(ERR_get_error()) {}

  const char *what() const noexcept override {
    return operation_;
  }

  unsigned long code() const noexcept {
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
  void operator()(Value *value) const noexcept {
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
