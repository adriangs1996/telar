module telar.base.memory.containers;

import std;
import telar.tbc;
import telar.base.memory.allocators;

namespace telar::runtime {

  namespace {

    // The `count` bytes an allocator handed out at `bytes`.
    template <typename Byte>
    std::span<Byte> allocated(Byte* bytes, std::size_t count) noexcept {
      return {bytes, count}; // NOLINT(clang-diagnostic-unsafe-buffer-usage-in-container): every caller passes the size it allocated
    }

  }

  template <Allocator Memory>
  ByteStorage<Memory>::ByteStorage(tbc::mut_a<Memory> memory, std::size_t size)
      : memory_(memory),
        size_(size) {
    if (size != 0) {
      storage_ = static_cast<std::uint8_t*>(memory.allocate(size, alignof(std::uint8_t)));
      if (storage_ == nullptr) {
        throw std::bad_alloc{};
      }
    }
  }

  template <Allocator Memory>
  ByteStorage<Memory>::~ByteStorage() {
    if (storage_ != nullptr) {
      memory_.deallocate(storage_, size_, alignof(std::uint8_t));
    }
  }

  template <Allocator Memory>
  std::span<std::uint8_t> ByteStorage<Memory>::bytesMut() noexcept {
    return allocated(storage_, size_);
  }

  template <Allocator Memory>
  std::span<const std::uint8_t> ByteStorage<Memory>::bytes() const noexcept {
    return allocated(static_cast<const std::uint8_t*>(storage_), size_);
  }

  template class ByteStorage<Memory>;
  template class ByteStorage<ConcurrentMemory>;
  template class ByteStorage<SystemAllocator>;
  template class ByteStorage<BudgetAllocator<SystemAllocator>>;

  template <Allocator Memory>
  RetainedStream<Memory>::RetainedStream(Memory& memory, std::size_t capacity)
      : memory_(memory),
        capacity_(capacity) {
    bytes_ = static_cast<Byte*>(memory_.allocate(capacity_, alignof(Byte)));
    if (bytes_ == nullptr) {
      throw std::bad_alloc{};
    }
  }

  template <Allocator Memory>
  RetainedStream<Memory>::~RetainedStream() {
    memory_.deallocate(bytes_, capacity_, alignof(Byte));
  }

  template <Allocator Memory>
  void RetainedStream<Memory>::append(std::span<const Byte> bytes) noexcept {
    total_ += bytes.size();
    bytes = bytes.last(std::min(bytes.size(), capacity_));
    const auto start = static_cast<std::size_t>((total_ - bytes.size()) % capacity_);
    const auto first = std::min(bytes.size(), capacity_ - start);

    std::ranges::copy(bytes.first(first), allocated(bytes_, capacity_).subspan(start).begin());
    std::ranges::copy(bytes.subspan(first), allocated(bytes_, capacity_).begin());
  }

  template <Allocator Memory>
  auto RetainedStream<Memory>::read(std::uint64_t offset, tbc::val_a<std::span<Byte>> destination) const noexcept -> tbc::val_a<std::span<const Byte>> {
    if (offset < retainedOffset() || offset >= total_) {
      return {};
    }

    const auto count = static_cast<std::size_t>(std::min<std::uint64_t>(destination.size(), total_ - offset));
    const auto start = static_cast<std::size_t>(offset % capacity_);
    const auto first = std::min(count, capacity_ - start);
    const auto stored = allocated(static_cast<const Byte*>(bytes_), capacity_);

    std::ranges::copy(stored.subspan(start, first), destination.begin());
    std::ranges::copy(stored.first(count - first), destination.subspan(first).begin());
    return destination.first(count);
  }

  template <Allocator Memory>
  std::uint64_t RetainedStream<Memory>::total() const noexcept {
    return total_;
  }

  template <Allocator Memory>
  std::uint64_t RetainedStream<Memory>::retainedOffset() const noexcept {
    return total_ - std::min<std::uint64_t>(total_, capacity_);
  }

  template class RetainedStream<Memory>;
  template class RetainedStream<ConcurrentMemory>;
  template class RetainedStream<SystemAllocator>;
  template class RetainedStream<BudgetAllocator<SystemAllocator>>;

}
