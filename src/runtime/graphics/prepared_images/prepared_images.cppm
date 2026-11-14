module;
#include "telar_platform/trace_macro.hpp"
#include <cstddef>
#include <ghostty/vt.h>
#include <new>
#include <stdlib.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>

#include <cstdint>

#include "tbc/view.hpp"
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.graphics.prepared_images;

import std;

export import telar.platform.graphics;

export import telar.runtime.terminal.graphics_storage;
import telar.base.diagnostics;
import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;
import telar.runtime.diagnostics.operation;

// Interface: graphics/frozen_image.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class FrozenImage {
    public:
      inline explicit FrozenImage(Memory& memory, MediaAllocator<Memory>& budget, std::span<const std::uint8_t> pixels, bool shared)
          : memory_(&memory),
            budget_(&budget) {
        TELAR_TRACE("media.freezeImage");
        if (!budget_->reserve(pixels.size())) {
          throw std::bad_alloc{};
        }

        byte_count_ = pixels.size();
        reserved_bytes_ = pixels.size();

        try {
          if (shared && freezeShared(pixels)) {
            return;
          }

          pixels_ = static_cast<std::uint8_t*>(memory_->allocate(byte_count_, alignof(std::uint8_t)));
          if (pixels_ == nullptr) {
            throw std::bad_alloc{};
          }

          std::memcpy(pixels_, pixels.data(), pixels.size());
        } catch (...) {
          reset();
          throw;
        }
      }

      inline ~FrozenImage() {
        reset();
      }

      FrozenImage(const FrozenImage&) = delete;
      FrozenImage& operator=(const FrozenImage&) = delete;

      inline FrozenImage(FrozenImage&& other) noexcept {
        take(other);
      }

      FrozenImage& operator=(FrozenImage&& other) noexcept {
        if (this != &other) {
          reset();
          take(other);
        }

        return *this;
      }

      inline std::span<const std::uint8_t> pixels() const noexcept {
        return {pixels_, pixels_ == nullptr ? 0 : byte_count_};
      }

      inline std::size_t byteCount() const noexcept {
        return byte_count_;
      }

      inline std::string_view name() const noexcept {
        return name_.data();
      }

      inline void published() noexcept {
        owns_name_ = false;
      }

      inline static FrozenImage adoptSharedName(SharedImageStorage::Name name, std::size_t byte_count) noexcept {
        FrozenImage image;

        image.name_ = name;
        image.owns_name_ = true;
        image.byte_count_ = byte_count;
        return image;
      }

    private:
      FrozenImage() noexcept = default;

      inline bool freezeShared(std::span<const std::uint8_t> pixels) noexcept {
        auto shared = SharedImageStorage::create(pixels.size());
        if (!shared) {
          return false;
        }

        std::memcpy(shared->mapping().bytes().data(), pixels.data(), pixels.size());
        name_ = shared->takeName();
        owns_name_ = true;
        return true;
      }

      inline void removeName() noexcept {
        if (owns_name_) {
          ::shm_unlink(name_.data());
        }

        name_[0] = '\0';
        owns_name_ = false;
      }

      inline void reset() noexcept {
        removeName();
        if (pixels_ != nullptr) {
          memory_->deallocate(pixels_, byte_count_, alignof(std::uint8_t));
          pixels_ = nullptr;
        }

        if (reserved_bytes_ != 0) {
          budget_->release(std::exchange(reserved_bytes_, 0));
        }

        byte_count_ = 0;
      }

      inline void take(FrozenImage& other) noexcept {
        memory_ = other.memory_;
        budget_ = other.budget_;
        pixels_ = std::exchange(other.pixels_, nullptr);
        byte_count_ = std::exchange(other.byte_count_, 0);
        reserved_bytes_ = std::exchange(other.reserved_bytes_, 0);
        name_ = other.name_;
        other.name_[0] = '\0';
        owns_name_ = std::exchange(other.owns_name_, false);
      }

      Memory* memory_ = nullptr;
      MediaAllocator<Memory>* budget_ = nullptr;
      std::uint8_t* pixels_ = nullptr;
      std::size_t byte_count_ = 0;
      std::size_t reserved_bytes_ = 0;
      std::array<char, 32> name_{};
      bool owns_name_ = false;
    };

  }
}

// Interface: graphics/prepared_images.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class PreparedImages {
    public:
      inline explicit PreparedImages(Memory& memory, MediaAllocator<Memory>& budget) noexcept
          : memory_(memory),
            budget_(budget) {}

      inline void prepare(std::span<const GraphicsImageView> images) noexcept {
        TELAR_TRACE("media.prepareShared");
        retain(images);
        for (const auto& image : images) {
          if (covered(image.description.key)) {
            continue;
          }

          auto* slot = availableSlot(image.description.key.image_id);
          if (slot == nullptr) {
            continue;
          }

          slot->reset();
          try {
            FrozenImage<Memory> frozen{memory_, budget_, image.pixels, true};
            if (frozen.name().empty()) {
              continue;
            }

            slot->emplace(Entry{image.description.key, std::move(frozen)});
            remember(image.description.key);
            TELAR_DIAGNOSTIC(diagnostics::accumulate(prepared_count_));
          } catch (...) {
          }
        }
      }

      inline std::optional<FrozenImage<Memory>> take(ImageKey key) noexcept {
        for (auto& slot : entries_) {
          if (slot && sameImage(slot->key, key)) {
            auto frozen = std::move(slot->frozen);

            slot.reset();
            return frozen;
          }
        }

        return std::nullopt;
      }

      inline bool put(ImageKey key, FrozenImage<Memory>&& image) noexcept {
        auto* slot = availableSlot(key.image_id);
        if (slot == nullptr) {
          return false;
        }

        slot->emplace(Entry{key, std::move(image)});
        remember(key);
        return true;
      }

      template <typename Consumer>
      inline void discardUnwanted(const Consumer& wanted) noexcept {
        for (auto& slot : entries_) {
          if (slot && !wanted(slot->key, true)) {
            slot.reset();
          }
        }
      }

      inline void clear() noexcept {
        for (auto& slot : entries_) {
          slot.reset();
        }

        frozen_.fill({});
      }

#if TELAR_DIAGNOSTICS
      inline std::uint64_t takePreparedCount() noexcept {
        return std::exchange(prepared_count_, 0);
      }

      inline std::size_t storedBytes() const noexcept {
        std::size_t bytes = 0;

        for (const auto& entry : entries_) {
          if (entry) {
            bytes += entry->frozen.byteCount();
          }
        }

        return bytes;
      }
#endif

    private:
      struct Entry {
        ImageKey key;
        FrozenImage<Memory> frozen;
      };

      inline void retain(std::span<const GraphicsImageView> images) noexcept {
        for (auto& slot : entries_) {
          if (slot && std::ranges::none_of(images, [&](const auto& image) {
                return sameImage(slot->key, image.description.key);
              })) {
            slot.reset();
          }
        }

        for (auto& key : frozen_) {
          if (key.image_id != 0 && std::ranges::none_of(images, [&](const auto& image) {
                return key.image_id == image.description.key.image_id;
              })) {
            key = {};
          }
        }
      }

      inline bool covered(ImageKey key) const noexcept {
        return std::ranges::any_of(frozen_, [&](auto known) {
          return known.image_id == key.image_id && known.generation >= key.generation;
        });
      }

      inline std::optional<Entry>* availableSlot(std::uint32_t identity) noexcept {
        std::optional<Entry>* free = nullptr;

        for (auto& slot : entries_) {
          if (slot && slot->key.image_id == identity) {
            return &slot;
          }

          if (!slot && free == nullptr) {
            free = &slot;
          }
        }

        return free;
      }

      inline void remember(ImageKey key) noexcept {
        auto found = std::ranges::find_if(frozen_, [&](auto known) {
          return known.image_id == key.image_id;
        });
        if (found == frozen_.end()) {
          found = std::ranges::find_if(frozen_, [](auto known) {
            return known.image_id == 0;
          });
        }

        if (found != frozen_.end()) {
          *found = key;
        }
      }

      static constexpr std::size_t prepared_capacity = 4;
      Memory& memory_;
      MediaAllocator<Memory>& budget_;
      std::array<std::optional<Entry>, prepared_capacity> entries_;
      std::array<ImageKey, graphics_image_count * 2> frozen_{};
#if TELAR_DIAGNOSTICS
      std::uint64_t prepared_count_ = 0;
#endif
    };

  }
}

// Interface: graphics/transfer_requests.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class TransferRequests {
    public:
      inline explicit TransferRequests(Memory& memory, MediaAllocator<Memory>& budget) noexcept
          : memory_(memory),
            budget_(budget) {}

      inline bool request(ImageKey key, bool shared) noexcept {
        std::optional<Entry>* free = nullptr;

        for (auto& entry : entries_) {
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

      inline std::optional<FrozenImage<Memory>> take(ImageKey key, bool shared) {
        for (auto& entry : entries_) {
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

      inline void process(std::span<const GraphicsImageView> images) noexcept {
        TELAR_TRACE("media.prepareTransfers");
        for (auto& entry : entries_) {
          if (!entry) {
            continue;
          }

          const auto image = std::ranges::find_if(images, [&](const auto& image) {
            return sameImage(entry->key, image.description.key);
          });
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
      inline void discardUnwanted(const Consumer& wanted) noexcept {
        for (auto& entry : entries_) {
          if (entry && !wanted(entry->key, entry->shared)) {
            entry.reset();
          }
        }
      }

      inline void clear() noexcept {
        for (auto& entry : entries_) {
          entry.reset();
        }
      }

#if TELAR_DIAGNOSTICS
      inline std::size_t storedBytes() const noexcept {
        std::size_t bytes = 0;

        for (const auto& entry : entries_) {
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
        failed,
      };

      struct Entry {
        ImageKey key;
        bool shared;
        State state = State::pending;
        std::optional<FrozenImage<Memory>> frozen{};
      };

      Memory& memory_;
      MediaAllocator<Memory>& budget_;
      std::array<std::optional<Entry>, 8> entries_;
    };

  }
}
