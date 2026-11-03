#pragma once

#include "handle.hpp"
#include "telar_base/memory/erase_sensitive.hpp"
#include <cstdint>
#include <span>

namespace telar::runtime {

class PemDocument {
public:
  static constexpr std::size_t maximum_bytes = 4096;

  explicit PemDocument(EVP_PKEY *key) {
    requireTls(buffer_ != nullptr, "Allocate TLS key encoding");
    requireTls(PEM_write_bio_PrivateKey(buffer_.get(), key, nullptr, nullptr, 0, nullptr, nullptr) == 1, "Encode TLS private key");
    requireTls(bytes().size() <= maximum_bytes, "TLS private key exceeds its bound");
  }

  explicit PemDocument(X509 *certificate) {
    requireTls(buffer_ != nullptr, "Allocate TLS certificate encoding");
    requireTls(PEM_write_bio_X509(buffer_.get(), certificate) == 1, "Encode TLS certificate");
    requireTls(bytes().size() <= maximum_bytes, "TLS certificate exceeds its bound");
  }

  PemDocument(const PemDocument &) = delete;
  PemDocument &operator=(const PemDocument &) = delete;

  std::span<const std::uint8_t> bytes() const noexcept {
    char *data = nullptr;
    const auto length = BIO_get_mem_data(buffer_.get(), &data);
    return {reinterpret_cast<const std::uint8_t *>(data), length > 0 ? static_cast<std::size_t>(length) : 0};
  }

private:
  static void clearBuffer(BIO *buffer) noexcept {
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
