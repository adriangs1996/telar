#pragma once

#include <array>
#include <cstdint>
#include <openssl/sha.h>
#include <string_view>

namespace telar::runtime {

class Sha256 {
public:
  Sha256() noexcept { SHA256_Init(&context_); }

  void update(std::string_view bytes) noexcept {
    SHA256_Update(&context_, bytes.data(), bytes.size());
  }

  std::array<std::uint8_t, SHA256_DIGEST_LENGTH> finish() noexcept {
    std::array<std::uint8_t, SHA256_DIGEST_LENGTH> digest;
    SHA256_Final(digest.data(), &context_);
    return digest;
  }

private:
  SHA256_CTX context_;
};

}
