module;
#include <openssl/md5.h>
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

// OpenSSL's digest headers stay in this module's global fragments only; importers reach them
// through these declarations instead of including them.
export {
  using ::SHA_CTX;

  using ::MD5;
  using ::SHA1_Final;
  using ::SHA1_Init;
  using ::SHA1_Update;
  using ::SHA256;
}

// Macros do not cross an import. Each constant the tree reads is captured while the headers still
// define it, undefined, and exported under its own name.
#define TELAR_SHA256_CONSTANTS(X) \
  X(MD5_DIGEST_LENGTH)            \
  X(SHA256_DIGEST_LENGTH)         \
  X(SHA_DIGEST_LENGTH)

namespace telar::runtime::sha256::captured {

#define TELAR_SHA256_CAPTURE(name) inline constexpr auto name##_ = name;
  TELAR_SHA256_CONSTANTS(TELAR_SHA256_CAPTURE)

}

#undef MD5_DIGEST_LENGTH
#undef SHA256_DIGEST_LENGTH
#undef SHA_DIGEST_LENGTH

#define TELAR_SHA256_CONSTANT(name) inline constexpr auto name = telar::runtime::sha256::captured::name##_;

export {
  TELAR_SHA256_CONSTANTS(TELAR_SHA256_CONSTANT)
}
