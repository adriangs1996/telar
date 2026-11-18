module;
#include "tbc/annotations.hpp"

export module telar.base.memory.sensitive;

import std;
import telar.tbc;
import telar.base.memory.allocators;

// Interface: telar_base/memory/erase_sensitive.cppm
export {
  namespace telar {

    // Zeroes the bytes in a way the compiler cannot drop as a dead store.
    void eraseSensitive(void* storage, std::size_t length) noexcept;

  }
}

// Interface: telar_base/memory/erasing_allocator.cppm
export {
  namespace telar {

    // The release path of every secure container and of SensitiveAllocation, over any composed upstream.
    template <Allocator Upstream>
    class TBC_SHARED TBC_GENERIC ErasingAllocator {
    public:
      static constexpr bool thread_safe = ConcurrentAllocator<Upstream>;
      static constexpr bool erasing = true;

      inline explicit ErasingAllocator(Upstream& upstream) noexcept
          : upstream_(upstream) {}

      inline void* allocate(std::size_t size, std::size_t alignment) noexcept {
        return upstream_.allocate(size, alignment);
      }

      inline void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept {
        if (pointer != nullptr) {
          eraseSensitive(pointer, size);
          upstream_.deallocate(pointer, size, alignment);
        }
      }

    private:
      Upstream& upstream_;
    };

    template <Allocator Upstream>
    ErasingAllocator(Upstream& upstream) -> ErasingAllocator<Upstream>;

  }
}

// Interface: telar_base/memory/recycling_allocator.cppm
export {
  namespace telar {

    template <Allocator Upstream>
    class TBC_SHARED RecyclingAllocator {
    public:
      static constexpr bool thread_safe = false;
      // Every block it releases or keeps for reuse is erased first.
      static constexpr bool erasing = true;

      explicit RecyclingAllocator(Upstream& upstream) noexcept;
      ~RecyclingAllocator();

      RecyclingAllocator(const RecyclingAllocator&) = delete;
      RecyclingAllocator& operator=(const RecyclingAllocator&) = delete;

      void* allocate(std::size_t size, std::size_t alignment) noexcept;
      void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept;
      std::size_t retainedBytes() const noexcept;

      static constexpr std::size_t maximum_retained_bytes = 512 * 1024;

    private:
      struct Block {
        Block* next;
      };

      static bool recyclable(std::size_t size, std::size_t alignment) noexcept;
      static std::size_t bucket(std::size_t size) noexcept;

      static constexpr std::size_t block_alignment = alignof(std::max_align_t);
      static constexpr std::size_t maximum_block_bytes = 4096;
      Upstream& upstream_;
      std::array<Block*, maximum_block_bytes / block_alignment> available_{};
      std::size_t retained_bytes_ = 0;
    };

  }
}

// Instantiated in the implementation unit for the erased interfaces and for base's own allocators,
// which the tests of the services that use them still pass.
namespace telar {
  extern template class RecyclingAllocator<Memory>;
  extern template class RecyclingAllocator<ConcurrentMemory>;
  extern template class RecyclingAllocator<SystemAllocator>;
  extern template class RecyclingAllocator<BudgetAllocator<SystemAllocator>>;
}

// Interface: telar_base/memory/sensitive_allocation.cppm
export {
  namespace telar::runtime {

    // Bytes erased on release, allocated from an allocator in region `a`.
    template <Allocator Memory>
    class TBC_GENERIC SensitiveAllocation {
    public:
      inline explicit SensitiveAllocation(tbc::view<Memory&, tbc::lt::a> memory, std::size_t size)
          : memory_(&memory),
            size_(size) {
        if (size != 0) {
          storage_ = static_cast<std::uint8_t*>(memory.allocate(size, alignof(std::uint8_t)));
          if (storage_ == nullptr) {
            throw std::bad_alloc{};
          }
        }
      }

      inline ~SensitiveAllocation() {
        release();
      }

      SensitiveAllocation(const SensitiveAllocation&) = delete;
      SensitiveAllocation& operator=(const SensitiveAllocation&) = delete;

      inline SensitiveAllocation(SensitiveAllocation&& other) noexcept
          : memory_(other.memory_),
            storage_(std::exchange(other.storage_, nullptr)),
            size_(std::exchange(other.size_, 0)) {}

      SensitiveAllocation& operator=(SensitiveAllocation&& other) noexcept {
        if (this != &other) {
          release();
          memory_ = other.memory_;
          storage_ = std::exchange(other.storage_, nullptr);
          size_ = std::exchange(other.size_, 0);
        }

        return *this;
      }

      inline std::span<std::uint8_t> bytesMut() noexcept {
        return {storage_, size_};
      }

      inline std::span<const std::uint8_t> bytes() const noexcept {
        return {storage_, size_};
      }

    private:
      inline void release() noexcept {
        ErasingAllocator sensitive{*memory_};

        sensitive.deallocate(storage_, size_, alignof(std::uint8_t));
      }

      tbc::view<Memory*, tbc::lt::a> memory_;
      std::uint8_t* storage_ = nullptr;
      std::size_t size_;
    };

    template <Allocator Memory>
    SensitiveAllocation(Memory& memory, std::size_t size) -> SensitiveAllocation<Memory>;

  }
}

// Interface: telar_base/memory/sensitive_buffer.cppm
export {
  namespace telar::runtime {

    // Generic over its capacity, so no implementation unit can instantiate it for every importer.
    template <std::size_t Capacity>
    class TBC_GENERIC SensitiveBuffer {
    public:
      inline SensitiveBuffer() noexcept {}

      inline ~SensitiveBuffer() {
        eraseSensitive(bytes_.data(), bytes_.size());
      }

      SensitiveBuffer(const SensitiveBuffer&) = delete;
      SensitiveBuffer& operator=(const SensitiveBuffer&) = delete;

      inline std::span<std::uint8_t, Capacity> bytes() noexcept {
        return bytes_;
      }

    private:
      std::array<std::uint8_t, Capacity> bytes_;
    };

  }
}

// Interface: telar_base/memory/sensitive_text.cppm
export {
  namespace telar::runtime {

    // Generic over its capacity, so no implementation unit can instantiate it for every importer.
    template <std::size_t Capacity>
    class TBC_GENERIC SensitiveText {
    public:
      inline SensitiveText() noexcept {}

      inline ~SensitiveText() {
        clear();
      }

      inline SensitiveText(const SensitiveText& other) noexcept {
        copy(other);
      }

      SensitiveText& operator=(const SensitiveText& other) noexcept {
        if (this != &other) {
          clear();
          copy(other);
        }

        return *this;
      }

      inline SensitiveText(SensitiveText&& other) noexcept {
        copy(other);
        other.clear();
      }

      SensitiveText& operator=(SensitiveText&& other) noexcept {
        if (this != &other) {
          clear();
          copy(other);
          other.clear();
        }

        return *this;
      }

      inline void append(std::string_view text) {
        if (text.size() > Capacity - length_) {
          throw std::length_error{"Sensitive text exceeds its capacity"};
        }

        if (!text.empty()) {
          std::memcpy(bytes_.data() + length_, text.data(), text.size());
          length_ += text.size();
        }
      }

      inline void truncate(std::size_t length) noexcept {
        if (length < length_) {
          eraseSensitive(bytes_.data() + length, length_ - length);
          length_ = length;
        }
      }

      inline void clear() noexcept {
        truncate(0);
      }

      inline std::string_view view() const noexcept {
        return {bytes_.data(), length_};
      }

    private:
      inline void copy(const SensitiveText& other) noexcept {
        length_ = other.length_;
        std::memcpy(bytes_.data(), other.bytes_.data(), length_);
      }

      std::array<char, Capacity> bytes_;
      std::size_t length_ = 0;
    };

  }
}
