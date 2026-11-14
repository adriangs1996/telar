module;
#include <openssl/sha.h>

export module telar.platform.sha256;

import std;

// Interface: telar_platform/sha256.cppm
export {
  namespace telar::runtime {

    class Sha256 {
    public:
      Sha256() noexcept;

      void update(std::string_view bytes) noexcept;
      std::array<std::uint8_t, SHA256_DIGEST_LENGTH> finish() noexcept;

    private:
      SHA256_CTX context_;
    };

  }
}
