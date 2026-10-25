#pragma once

#include "frozen_image.hpp"
#include "storage.hpp"

namespace telar::runtime {

template <Allocator Memory>
class TransferRequests {
public:
  explicit TransferRequests(Memory &memory, MediaAllocator<Memory> &budget) noexcept
      : memory_(memory),
        budget_(budget) {}

  bool request(ImageKey key, bool shared) noexcept {
    std::optional<Entry> *free = nullptr;
    for (auto &entry : entries_) {
      if (entry && entry->shared == shared && sameImage(entry->key, key)) {
        return false;
      }
      if (!entry && free == nullptr) {
        free = &entry;
      }
    }
    if (free == nullptr) {
      return false;
    }
    free->emplace(Entry{.key = key, .shared = shared});
    return true;
  }

  std::optional<FrozenImage<Memory>> take(ImageKey key, bool shared) {
    for (auto &entry : entries_) {
      if (!entry || entry->shared != shared || !sameImage(entry->key, key) || entry->state == State::pending) {
        continue;
      }

      const bool failed = entry->state == State::failed;
      auto frozen = std::move(entry->frozen);
      entry.reset();
      if (failed) {
        throw std::bad_alloc{};
      }
      return frozen;
    }
    return std::nullopt;
  }

  void process(std::span<const GraphicsImageView> images) noexcept {
    TELAR_TRACE("media.prepareTransfers");
    for (auto &entry : entries_) {
      if (!entry) {
        continue;
      }

      const auto image = std::ranges::find_if(images, [&](const auto &image) { return sameImage(entry->key, image.description.key); });
      if (image == images.end()) {
        entry.reset();
        continue;
      }
      if (entry->state != State::pending) {
        continue;
      }

      try {
        entry->frozen.emplace(memory_, budget_, image->pixels, entry->shared);
        entry->state = State::ready;
      } catch (...) {
        entry->state = State::failed;
      }
    }
  }

  template <typename Consumer>
  void discardUnwanted(const Consumer &wanted) noexcept {
    for (auto &entry : entries_) {
      if (entry && !wanted(entry->key, entry->shared)) {
        entry.reset();
      }
    }
  }

  void clear() noexcept {
    for (auto &entry : entries_) {
      entry.reset();
    }
  }

#if TELAR_DIAGNOSTICS
  std::size_t storedBytes() const noexcept {
    std::size_t bytes = 0;
    for (const auto &entry : entries_) {
      if (entry) {
        bytes += entry->frozen ? entry->frozen->byteCount() : 0;
      }
    }
    return bytes;
  }
#endif

private:
  enum class State {
    pending,
    ready,
    failed
  };

  struct Entry {
    ImageKey key;
    bool shared;
    State state = State::pending;
    std::optional<FrozenImage<Memory>> frozen{};
  };

  Memory &memory_;
  MediaAllocator<Memory> &budget_;
  std::array<std::optional<Entry>, 8> entries_;
};

}
