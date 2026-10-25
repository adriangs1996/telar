#pragma once

#include "../memory/allocator.hpp"
#include <cstring>
#include <sqlite3.h>
#include <stdexcept>

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class SqliteAllocator {
public:
  explicit SqliteAllocator(Memory &memory) {
    if (active_ != nullptr || sqlite3_config(SQLITE_CONFIG_GETMALLOC, &previous_) != SQLITE_OK) {
      throw std::logic_error{"SQLite allocation must be configured before opening databases"};
    }

    sqlite3_mem_methods methods{
        &allocate,
        &deallocate,
        &reallocate,
        &allocationSize,
        &roundedSize,
        &initialize,
        &shutdown,
        &memory,
    };
    if (sqlite3_config(SQLITE_CONFIG_MALLOC, &methods) != SQLITE_OK) {
      throw std::logic_error{"Cannot install the SQLite allocator"};
    }

    if (sqlite3_initialize() != SQLITE_OK) {
      sqlite3_shutdown();
      sqlite3_config(SQLITE_CONFIG_MALLOC, &previous_);
      active_ = nullptr;
      throw std::bad_alloc{};
    }
  }

  ~SqliteAllocator() {
    sqlite3_shutdown();
    sqlite3_config(SQLITE_CONFIG_MALLOC, &previous_);
    active_ = nullptr;
  }

  SqliteAllocator(const SqliteAllocator &) = delete;
  SqliteAllocator &operator=(const SqliteAllocator &) = delete;

private:
  struct alignas(std::max_align_t) Header {
    int bytes;
  };

  static int initialize(void *context) noexcept {
    active_ = static_cast<Memory *>(context);
    return SQLITE_OK;
  }

  static void shutdown(void *) noexcept {}

  static void *allocate(int bytes) noexcept {
    if (bytes <= 0) {
      return nullptr;
    }

    auto *header = static_cast<Header *>(active_->allocate(sizeof(Header) + static_cast<std::size_t>(bytes), alignof(Header)));
    if (header == nullptr) {
      return nullptr;
    }

    header->bytes = bytes;
    return header + 1;
  }

  static void deallocate(void *pointer) noexcept {
    if (pointer == nullptr) {
      return;
    }

    auto *header = static_cast<Header *>(pointer) - 1;
    active_->deallocate(header, sizeof(Header) + static_cast<std::size_t>(header->bytes), alignof(Header));
  }

  static void *reallocate(void *pointer, int bytes) noexcept {
    if (bytes == 0) {
      deallocate(pointer);
      return nullptr;
    }

    void *replacement = allocate(bytes);
    if (replacement != nullptr && pointer != nullptr) {
      std::memcpy(replacement, pointer, static_cast<std::size_t>(std::min(allocationSize(pointer), bytes)));
      deallocate(pointer);
    }

    return replacement;
  }

  static int allocationSize(void *pointer) noexcept {
    return (static_cast<Header *>(pointer) - 1)->bytes;
  }

  static int roundedSize(int bytes) noexcept {
    constexpr int alignment = alignof(Header);
    if (bytes <= 0 || bytes > std::numeric_limits<int>::max() - alignment + 1) {
      return 0;
    }

    return (bytes + alignment - 1) & ~(alignment - 1);
  }

  inline static Memory *active_ = nullptr;
  sqlite3_mem_methods previous_{};
};

template <ConcurrentAllocator Memory>
SqliteAllocator(Memory &memory) -> SqliteAllocator<Memory>;

}
