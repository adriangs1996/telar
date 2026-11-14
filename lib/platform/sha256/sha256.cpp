module;
#include <openssl/sha.h>

module telar.platform.sha256;

import std;

namespace telar::runtime {

  Sha256::Sha256() noexcept {
    SHA256_Init(&context_);
  }

  void Sha256::update(std::string_view bytes) noexcept {
    SHA256_Update(&context_, bytes.data(), bytes.size());
  }

  std::array<std::uint8_t, SHA256_DIGEST_LENGTH> Sha256::finish() noexcept {
    std::array<std::uint8_t, SHA256_DIGEST_LENGTH> digest;

    SHA256_Final(digest.data(), &context_);
    return digest;
  }

}
