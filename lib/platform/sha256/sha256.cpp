module;
#include <openssl/evp.h>
#include <openssl/md5.h>
#include <openssl/sha.h>

module telar.platform.sha256;

import std;
import telar.base.ds;

namespace telar::runtime {

// The incremental hash goes through OpenSSL's low-level SHA-256, deprecated since 3.0 in favour of
// EVP: it keeps its context inline, where an EVP_MD_CTX is a heap allocation and a provider lookup
// per hash, and every file a git scan reads is hashed.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

  Sha256::Sha256() noexcept {
    SHA256_Init(&context_);
  }

  void Sha256::update(std::string_view bytes) noexcept {
    SHA256_Update(&context_, bytes.data(), bytes.size());
  }

  ds::Array<std::uint8_t, SHA256_DIGEST_LENGTH> Sha256::finish() noexcept {
    ds::Array<std::uint8_t, SHA256_DIGEST_LENGTH> digest;

    SHA256_Final(digest.dataMut(), &context_);
    return digest;
  }

#pragma clang diagnostic pop

  ds::Option<ds::Array<std::uint8_t, MD5_DIGEST_LENGTH>> md5(std::string_view bytes) noexcept {
    ds::Array<std::uint8_t, MD5_DIGEST_LENGTH> digest;
    std::size_t length = 0;
    if (EVP_Q_digest(nullptr, "MD5", nullptr, bytes.data(), bytes.size(), digest.dataMut(), &length) != 1 || length != digest.size()) {
      return ds::none;
    }

    return digest;
  }

}
