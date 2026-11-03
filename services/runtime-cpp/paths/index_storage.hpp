#pragma once

#include "telar_base/memory/allocator.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <atomic>

namespace telar::runtime {

struct IndexedPath {
  std::uint32_t offset;
  std::uint16_t length;
  PathKind kind;
};

enum class PathBuildFailure {
  none,
  unreadable,
  allocation
};

template <Allocator Memory>
class PathIndexStorage {
public:
  static constexpr std::size_t maximum_entries = 512 * 1024;
  static constexpr std::size_t maximum_bytes = 32 * 1024 * 1024;

  explicit PathIndexStorage(Memory &memory)
      : memory_(memory) {
    bytes_ = static_cast<char *>(memory_.allocate(maximum_bytes, alignof(char)));
    if (bytes_ == nullptr) {
      throw std::bad_alloc{};
    }

    entries_ = static_cast<IndexedPath *>(memory_.allocate(entry_bytes, alignof(IndexedPath)));
    if (entries_ == nullptr) {
      memory_.deallocate(bytes_, maximum_bytes, alignof(char));
      throw std::bad_alloc{};
    }
  }

  ~PathIndexStorage() {
    memory_.deallocate(entries_, entry_bytes, alignof(IndexedPath));
    memory_.deallocate(bytes_, maximum_bytes, alignof(char));
  }

  PathIndexStorage(const PathIndexStorage &) = delete;
  PathIndexStorage &operator=(const PathIndexStorage &) = delete;

  void reset() noexcept {
    count = 0;
    bytes_used = 0;
    truncated = false;
    failure = PathBuildFailure::none;
    published.store(0, std::memory_order_relaxed);
    complete.store(false, std::memory_order_relaxed);
    cancelled.store(false, std::memory_order_relaxed);
  }

  bool append(std::string_view relative, PathKind kind) noexcept {
    if (count == maximum_entries || relative.size() > maximum_bytes - bytes_used) {
      truncated = true;
      return false;
    }

    std::copy(relative.begin(), relative.end(), bytes_ + bytes_used);
    entries_[count++] = {static_cast<std::uint32_t>(bytes_used), static_cast<std::uint16_t>(relative.size()), kind};
    bytes_used += relative.size();
    if (count % publication_batch == 0) {
      published.store(count, std::memory_order_release);
    }
    return true;
  }

  const IndexedPath &entry(std::size_t index) const noexcept {
    return entries_[index];
  }

  std::string_view path(const IndexedPath &entry) const noexcept {
    return {bytes_ + entry.offset, entry.length};
  }

  void finish() noexcept {
    published.store(count, std::memory_order_release);
    complete.store(true, std::memory_order_release);
  }

  // One builder appends to fixed storage; readers access only the released prefix.
  std::atomic<std::size_t> published{0};
  std::atomic<bool> complete{false};
  std::atomic<bool> cancelled{false};
  std::size_t count = 0;
  std::size_t bytes_used = 0;
  bool truncated = false;
  PathBuildFailure failure = PathBuildFailure::none;

private:
  static constexpr std::size_t entry_bytes = maximum_entries * sizeof(IndexedPath);
  static constexpr std::size_t publication_batch = 1024;
  Memory &memory_;
  char *bytes_;
  IndexedPath *entries_;
};

}
