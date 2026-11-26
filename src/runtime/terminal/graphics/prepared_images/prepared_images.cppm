module;

#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.terminal.graphics.prepared_images;

import std;

import telar.platform.graphics;

import telar.runtime.terminal.graphics_storage;
import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.runtime.terminal.kitty;
import telar.runtime.terminal.control;
import telar.base.ds;

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

      [[nodiscard]] std::span<const std::uint8_t> pixels() const noexcept;

      [[nodiscard]] std::size_t byteCount() const noexcept;

      [[nodiscard]] std::string_view name() const noexcept;

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
      SharedImageStorage::Name name_{};
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

      ds::Option<FrozenImage> take(ImageKey key) noexcept;

      bool put(ImageKey key, FrozenImage&& image) noexcept;

      // Generic over the caller's predicate, so it stays here.
      template <typename Consumer>
      [[tbc::generic]] inline void discardUnwanted(const Consumer& wanted) noexcept {
        for (auto& slot : entries_.viewMut()) {
          if (slot && !wanted(slot->key, true)) {
            slot.reset();
          }
        }
      }

      void clear() noexcept;

#if TELAR_DIAGNOSTICS
      std::uint64_t takePreparedCount() noexcept;

      [[nodiscard]] std::size_t storedBytes() const noexcept;
#endif

    private:
      struct Entry {
        ImageKey key;
        FrozenImage frozen;
      };

      void retain(std::span<const GraphicsImageView> images) noexcept;

      [[nodiscard]] bool covered(ImageKey key) const noexcept;

      ds::Option<Entry>* availableSlot(std::uint32_t identity) noexcept;

      void remember(ImageKey key) noexcept;

      static constexpr std::size_t prepared_capacity = 4;
      ConcurrentMemory& memory_;
      MediaAllocator<ConcurrentMemory>& budget_;
      ds::Array<ds::Option<Entry>, prepared_capacity> entries_;
      ds::Array<ImageKey, graphics_image_count * 2> frozen_{};
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

      ds::Option<FrozenImage> take(ImageKey key, bool shared);

      void process(std::span<const GraphicsImageView> images) noexcept;

      // Generic over the caller's predicate, so it stays here.
      template <typename Consumer>
      [[tbc::generic]] inline void discardUnwanted(const Consumer& wanted) noexcept {
        for (auto& entry : entries_.viewMut()) {
          if (entry && !wanted(entry->key, entry->shared)) {
            entry.reset();
          }
        }
      }

      void clear() noexcept;

#if TELAR_DIAGNOSTICS
      [[nodiscard]] std::size_t storedBytes() const noexcept;
#endif

    private:
      enum class State : std::uint8_t {
        pending,
        ready,
        failed,
      };

      struct Entry {
        ImageKey key;
        bool shared;
        State state = State::pending;
        ds::Option<FrozenImage> frozen;
      };

      static constexpr std::size_t request_capacity = 8;
      ConcurrentMemory& memory_;
      MediaAllocator<ConcurrentMemory>& budget_;
      ds::Array<ds::Option<Entry>, request_capacity> entries_;
    };

  }
}
