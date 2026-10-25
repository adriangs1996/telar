#pragma once

#include "../memory/c_allocation_blocks.hpp"
#include <cstring>
#include <openssl/crypto.h>
#include <openssl/ssl.h>
#include <stdexcept>

namespace telar::runtime {

static_assert(OPENSSL_VERSION_MAJOR == 3, "TLS allocator ownership requires OpenSSL 3 immediate cleanup");

template <ConcurrentAllocator Memory>
class TlsLibrary {
public:
  explicit TlsLibrary(Memory &memory) {
    if (used_ || CRYPTO_set_mem_functions(&allocate, &reallocate, &deallocate) != 1) {
      throw std::logic_error{"TLS allocation must be configured once before using OpenSSL"};
    }

    used_ = true;
    memory_ = &memory;
    if (OPENSSL_init_ssl(OPENSSL_INIT_NO_ATEXIT | OPENSSL_INIT_NO_LOAD_CONFIG, nullptr) != 1) {
      OPENSSL_cleanup();
      memory_ = nullptr;
      throw std::bad_alloc{};
    }
  }

  ~TlsLibrary() {
    OPENSSL_cleanup();
    memory_ = nullptr;
  }

  TlsLibrary(const TlsLibrary &) = delete;
  TlsLibrary &operator=(const TlsLibrary &) = delete;

  bool uses(const Memory &memory) const noexcept {
    return memory_ == &memory;
  }

private:
  static void *allocate(std::size_t size, const char *, int) noexcept {
    if (memory_ == nullptr || size == 0) {
      return nullptr;
    }
    return CAllocationBlocks{*memory_}.allocate(size);
  }

  static void deallocate(void *pointer, const char *, int) noexcept {
    if (pointer == nullptr) {
      return;
    }

    CAllocationBlocks{*memory_}.release(pointer);
  }

  static void *reallocate(void *pointer, std::size_t size, const char *file, int line) noexcept {
    if (size == 0) {
      deallocate(pointer, file, line);
      return nullptr;
    }

    return memory_ == nullptr ? nullptr : CAllocationBlocks{*memory_}.resize(pointer, size);
  }

  // OpenSSL cannot be reinitialized after cleanup, and its callbacks have no context argument.
  inline static Memory *memory_ = nullptr;
  inline static bool used_ = false;
};

}
