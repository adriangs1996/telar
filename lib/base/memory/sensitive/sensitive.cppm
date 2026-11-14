module;
#include "tbc/view.hpp"

export module telar.base.memory.sensitive;

import std;
import telar.base.memory.allocators;

// Interface: telar_base/memory/erase_sensitive.cppm
export {
  namespace telar {

    inline void eraseSensitive(void* storage, std::size_t length) noexcept {
      if (length == 0) {
        return;
      }

      std::memset(storage, 0, length);
      // The memory clobber preserves the wipe after the buffer's final use without forcing byte stores.
      asm volatile("" : : "r"(storage) : "memory");
    }

  }
}

// Interface: telar_base/memory/erasing_allocator.cppm
export {
  namespace telar {

    template <Allocator Upstream>
    class TBC_SHARED ErasingAllocator {
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

      inline explicit RecyclingAllocator(Upstream& upstream) noexcept
          : upstream_(upstream) {}

      inline ~RecyclingAllocator() {
        for (std::size_t index = 0; index < available_.size(); ++index) {
          const auto capacity = (index + 1) * block_alignment;

          while (auto* block = available_[index]) {
            available_[index] = block->next;
            eraseSensitive(block, capacity);
            upstream_.deallocate(block, capacity, block_alignment);
          }
        }
      }

      RecyclingAllocator(const RecyclingAllocator&) = delete;
      RecyclingAllocator& operator=(const RecyclingAllocator&) = delete;

      inline void* allocate(std::size_t size, std::size_t alignment) noexcept {
        if (!recyclable(size, alignment)) {
          return upstream_.allocate(size, alignment);
        }

        const auto index = bucket(size);
        const auto capacity = (index + 1) * block_alignment;

        if (auto* block = available_[index]) {
          available_[index] = block->next;
          retained_bytes_ -= capacity;
          return block;
        }

        return upstream_.allocate(capacity, block_alignment);
      }

      inline void deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept {
        if (pointer == nullptr) {
          return;
        }

        if (!recyclable(size, alignment)) {
          eraseSensitive(pointer, size);
          upstream_.deallocate(pointer, size, alignment);
          return;
        }

        const auto index = bucket(size);
        const auto capacity = (index + 1) * block_alignment;

        eraseSensitive(pointer, capacity);
        if (capacity > maximum_retained_bytes - retained_bytes_) {
          upstream_.deallocate(pointer, capacity, block_alignment);
          return;
        }

        available_[index] = std::construct_at(static_cast<Block*>(pointer), Block{available_[index]});
        retained_bytes_ += capacity;
      }

      inline std::size_t retainedBytes() const noexcept {
        return retained_bytes_;
      }

      static constexpr std::size_t maximum_retained_bytes = 512 * 1024;

    private:
      struct Block {
        Block* next;
      };

      inline static bool recyclable(std::size_t size, std::size_t alignment) noexcept {
        return size != 0 && size <= maximum_block_bytes && alignment <= block_alignment;
      }

      inline static std::size_t bucket(std::size_t size) noexcept {
        return (size - 1) / block_alignment;
      }

      static constexpr std::size_t block_alignment = alignof(std::max_align_t);
      static constexpr std::size_t maximum_block_bytes = 4096;
      Upstream& upstream_;
      std::array<Block*, maximum_block_bytes / block_alignment> available_{};
      std::size_t retained_bytes_ = 0;
    };

  }
}

// Interface: telar_base/memory/sensitive_allocation.cppm
export {
  namespace telar::runtime {

    // Bytes erased on release, allocated from an allocator in region `a`.
    template <Allocator Memory>
    class SensitiveAllocation {
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

      inline std::span<std::uint8_t> bytes() noexcept {
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

    template <std::size_t Capacity>
    class SensitiveBuffer {
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

    template <std::size_t Capacity>
    class SensitiveText {
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
