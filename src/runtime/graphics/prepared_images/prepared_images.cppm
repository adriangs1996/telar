module;
#include "tbc/annotations.hpp"

#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.graphics.prepared_images;

import std;

import telar.platform.graphics;

import telar.runtime.terminal.graphics_storage;
import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.runtime.terminal.kitty;
import telar.runtime.terminal.control;

// Interface: graphics/frozen_image.cppm
export {
  namespace telar::runtime {

    class FrozenImage {
    public:
      explicit FrozenImage(ConcurrentMemory& memory, MediaAllocator<ConcurrentMemory>& budget, std::span<const std::uint8_t> pixels, bool shared);

      ~FrozenImage();

      FrozenImage(const FrozenImage&) = delete;
      FrozenImage& operator=(const FrozenImage&) = delete;

      FrozenImage(FrozenImage&& other) noexcept;

      FrozenImage& operator=(FrozenImage&& other) noexcept;

      std::span<const std::uint8_t> pixels() const noexcept;

      std::size_t byteCount() const noexcept;

      std::string_view name() const noexcept;

      void published() noexcept;

      static FrozenImage adoptSharedName(SharedImageStorage::Name name, std::size_t byte_count) noexcept;

    private:
      FrozenImage() noexcept = default;

      bool freezeShared(std::span<const std::uint8_t> pixels) noexcept;

      void removeName() noexcept;

      void reset() noexcept;

      void take(FrozenImage& other) noexcept;

      ConcurrentMemory* memory_ = nullptr;
      MediaAllocator<ConcurrentMemory>* budget_ = nullptr;
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

    class PreparedImages {
    public:
      explicit PreparedImages(ConcurrentMemory& memory, MediaAllocator<ConcurrentMemory>& budget) noexcept;

      void prepare(std::span<const GraphicsImageView> images) noexcept;

      std::optional<FrozenImage> take(ImageKey key) noexcept;

      bool put(ImageKey key, FrozenImage&& image) noexcept;

      // Generic over the caller's predicate, so it stays here.
      template <typename Consumer>
      TBC_GENERIC inline void discardUnwanted(const Consumer& wanted) noexcept {
        for (auto& slot : entries_) {
          if (slot && !wanted(slot->key, true)) {
            slot.reset();
          }
        }
      }

      void clear() noexcept;

#if TELAR_DIAGNOSTICS
      std::uint64_t takePreparedCount() noexcept;

      std::size_t storedBytes() const noexcept;
#endif

    private:
      struct Entry {
        ImageKey key;
        FrozenImage frozen;
      };

      void retain(std::span<const GraphicsImageView> images) noexcept;

      bool covered(ImageKey key) const noexcept;

      std::optional<Entry>* availableSlot(std::uint32_t identity) noexcept;

      void remember(ImageKey key) noexcept;

      static constexpr std::size_t prepared_capacity = 4;
      ConcurrentMemory& memory_;
      MediaAllocator<ConcurrentMemory>& budget_;
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

    class TransferRequests {
    public:
      explicit TransferRequests(ConcurrentMemory& memory, MediaAllocator<ConcurrentMemory>& budget) noexcept;

      bool request(ImageKey key, bool shared) noexcept;

      std::optional<FrozenImage> take(ImageKey key, bool shared);

      void process(std::span<const GraphicsImageView> images) noexcept;

      // Generic over the caller's predicate, so it stays here.
      template <typename Consumer>
      TBC_GENERIC inline void discardUnwanted(const Consumer& wanted) noexcept {
        for (auto& entry : entries_) {
          if (entry && !wanted(entry->key, entry->shared)) {
            entry.reset();
          }
        }
      }

      void clear() noexcept;

#if TELAR_DIAGNOSTICS
      std::size_t storedBytes() const noexcept;
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
        std::optional<FrozenImage> frozen{};
      };

      ConcurrentMemory& memory_;
      MediaAllocator<ConcurrentMemory>& budget_;
      std::array<std::optional<Entry>, 8> entries_;
    };

  }
}
