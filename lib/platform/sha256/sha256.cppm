module;
#include <openssl/sha.h>

export module telar.platform.sha256;

import std;

// Interface: telar_platform/sha256.cppm
export {
  namespace telar::runtime {

    class Sha256 {
    public:
      inline Sha256() noexcept {
        SHA256_Init(&context_);
      }

      inline void update(std::string_view bytes) noexcept {
        SHA256_Update(&context_, bytes.data(), bytes.size());
      }

      inline std::array<std::uint8_t, SHA256_DIGEST_LENGTH> finish() noexcept {
        std::array<std::uint8_t, SHA256_DIGEST_LENGTH> digest;

        SHA256_Final(digest.data(), &context_);
        return digest;
      }

    private:
      SHA256_CTX context_;
    };

  }
}
