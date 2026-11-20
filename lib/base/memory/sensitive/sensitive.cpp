module telar.base.memory.sensitive;

import std;
import telar.base.memory.allocators;

namespace telar {

  void eraseSensitive(void* storage, std::size_t length) noexcept {
    if (length == 0) {
      return;
    }

    std::fill_n(static_cast<std::byte*>(storage), length, std::byte{0});
    // The memory clobber preserves the wipe after the buffer's final use without forcing byte stores.
    asm volatile("" : : "r"(storage) : "memory"); // NOLINT(portability-no-assembler): no standard call keeps a wipe the compiler sees as dead
  }

  template <Allocator Upstream>
  RecyclingAllocator<Upstream>::RecyclingAllocator(Upstream& upstream) noexcept
      : upstream_(upstream) {}

  template <Allocator Upstream>
  RecyclingAllocator<Upstream>::~RecyclingAllocator() {
    for (std::size_t index = 0; index < available_.size(); ++index) {
      const auto capacity = (index + 1) * block_alignment;

      while (auto* block = available_[index]) {
        available_.atMut(index) = block->next;
        eraseSensitive(block, capacity);
        upstream_.deallocate(block, capacity, block_alignment);
      }
    }
  }

  template <Allocator Upstream>
  void* RecyclingAllocator<Upstream>::allocate(std::size_t size, std::size_t alignment) noexcept {
    if (!recyclable(size, alignment)) {
      return upstream_.allocate(size, alignment);
    }

    const auto index = bucket(size);
    const auto capacity = (index + 1) * block_alignment;

    if (auto* block = available_[index]) {
      available_.atMut(index) = block->next;
      retained_bytes_ -= capacity;
      return block;
    }

    return upstream_.allocate(capacity, block_alignment);
  }

  template <Allocator Upstream>
  void RecyclingAllocator<Upstream>::deallocate(void* pointer, std::size_t size, std::size_t alignment) noexcept {
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

    available_.atMut(index) = std::construct_at(static_cast<Block*>(pointer), Block{available_[index]});
    retained_bytes_ += capacity;
  }

  template <Allocator Upstream>
  std::size_t RecyclingAllocator<Upstream>::retainedBytes() const noexcept {
    return retained_bytes_;
  }

  template <Allocator Upstream>
  bool RecyclingAllocator<Upstream>::recyclable(std::size_t size, std::size_t alignment) noexcept {
    return size != 0 && size <= maximum_block_bytes && alignment <= block_alignment;
  }

  template <Allocator Upstream>
  std::size_t RecyclingAllocator<Upstream>::bucket(std::size_t size) noexcept {
    return (size - 1) / block_alignment;
  }

  template class RecyclingAllocator<Memory>;
  template class RecyclingAllocator<ConcurrentMemory>;
  template class RecyclingAllocator<SystemAllocator>;
  template class RecyclingAllocator<BudgetAllocator<SystemAllocator>>;

}
