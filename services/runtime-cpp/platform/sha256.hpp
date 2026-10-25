#pragma once

#include <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <string_view>

namespace telar::runtime {

class Sha256 {
public:
  Sha256() noexcept { CC_SHA256_Init(&context_); }

  void update(std::string_view bytes) noexcept {
    while (!bytes.empty()) {
      const auto count = std::min<std::size_t>(bytes.size(), std::numeric_limits<CC_LONG>::max());
      CC_SHA256_Update(&context_, bytes.data(), static_cast<CC_LONG>(count));
      bytes.remove_prefix(count);
    }
  }

  std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> finish() noexcept {
    std::array<std::uint8_t, CC_SHA256_DIGEST_LENGTH> digest;
    CC_SHA256_Final(digest.data(), &context_);
    return digest;
  }

private:
  CC_SHA256_CTX context_;
};

}
