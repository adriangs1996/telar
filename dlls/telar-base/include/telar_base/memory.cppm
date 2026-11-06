module;

#include "telar_base/memory/allocator.hpp"
#include <cstdint>
#include <span>


#include <cassert>
#include <cstring>


#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <mutex>
#include <optional>
#include <type_traits>
#include <utility>


#include <stdexcept>
#include <string_view>


#include <bit>

export module telar.base.memory;


// Interface: telar_base/memory/buffer_allocator.cppm
export {
namespace telar {

template <Allocator Upstream>
class BufferAllocator {
public:
  static constexpr bool thread_safe = false;

  inline explicit BufferAllocator(Upstream &upstream, std::span<std::byte> buffer) noexcept
      : upstream_(upstream), buffer_(buffer) {}

  BufferAllocator(const BufferAllocator &) = delete;
  BufferAllocator &operator=(const BufferAllocator &) = delete;

  inline void *allocate(std::size_t size, std::size_t alignment) noexcept {
    if (used_ == buffer_.size()) {
      return upstream_.allocate(size, alignment);
    }

    void *available = buffer_.data() + used_;
    auto remaining = buffer_.size() - used_;
    if (void *aligned = std::align(alignment, size, available, remaining)) {
      used_ = buffer_.size() - remaining + size;
      return aligned;
    }

    return upstream_.allocate(size, alignment);
  }

  inline void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    const auto address = reinterpret_cast<std::uintptr_t>(pointer);
    const auto beginning = reinterpret_cast<std::uintptr_t>(buffer_.data());
    if (address >= beginning && address - beginning < buffer_.size()) {
      return;
    }

    upstream_.deallocate(pointer, size, alignment);
  }

private:
  Upstream &upstream_;
  std::span<std::byte> buffer_;
  std::size_t used_ = 0;
};

template <Allocator Upstream>
BufferAllocator(Upstream &upstream, std::span<std::byte> buffer) -> BufferAllocator<Upstream>;

}
}

// Interface: telar_base/memory/byte_queue.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class ByteQueue {
public:
  inline explicit ByteQueue(Memory &memory, std::size_t limit) noexcept
      : memory_(memory),
        limit_(limit) {}

  inline ~ByteQueue() {
    if (bytes_ != nullptr) {
      memory_.deallocate(bytes_, capacity_, alignof(std::uint8_t));
    }
  }

  ByteQueue(const ByteQueue &) = delete;
  ByteQueue &operator=(const ByteQueue &) = delete;

  inline std::span<const std::uint8_t> readable() const noexcept {
    return {bytes_ == nullptr ? nullptr : bytes_ + consumed_, size()};
  }

  inline std::span<std::uint8_t> appendUninitialized(std::size_t count) {
    if (count > limit_ - size()) {
      throw std::bad_alloc{};
    }

    if (count > capacity_ - written_) {
      compact();
      reserve(written_ + count);
    }

    auto *start = bytes_ == nullptr ? nullptr : bytes_ + written_;
    written_ += count;
    return {start, count};
  }

  inline void append(std::span<const std::uint8_t> input) {
    auto output = appendUninitialized(input.size());
    std::copy(input.begin(), input.end(), output.begin());
  }

  inline std::span<std::uint8_t> insertUninitialized(std::size_t offset, std::size_t count) {
    const auto previous_size = size();
    assert(offset <= previous_size);
    appendUninitialized(count);
    auto *start = bytes_ + consumed_ + offset;
    std::memmove(start + count, start, previous_size - offset);
    return {start, count};
  }

  inline void consume(std::size_t count) noexcept {
    assert(count <= size());
    consumed_ += count;
    if (consumed_ == written_) {
      clear();
    }
  }

  inline void truncate(std::size_t length) noexcept {
    assert(length <= size());
    written_ = consumed_ + length;
  }

  inline void overwrite(std::size_t offset, std::span<const std::uint8_t> bytes) noexcept {
    assert(offset <= size() && bytes.size() <= size() - offset);
    std::memmove(bytes_ + consumed_ + offset, bytes.data(), bytes.size());
  }

  inline void erase(std::size_t offset, std::size_t count) noexcept {
    assert(offset <= size() && count <= size() - offset);
    if (offset == 0) {
      consume(count);
      return;
    }

    auto *start = bytes_ + consumed_ + offset;
    std::memmove(start, start + count, size() - offset - count);
    written_ -= count;
  }

  inline void clear() noexcept {
    written_ = 0;
    consumed_ = 0;
  }

  inline void reserve(std::size_t requested) {
    requested = std::min(requested, limit_);
    if (requested <= capacity_) {
      return;
    }

    const auto doubled = capacity_ > limit_ / 2 ? limit_ : capacity_ * 2;
    const auto capacity = std::max(requested, doubled);
    auto *storage = static_cast<std::uint8_t *>(memory_.allocate(capacity, alignof(std::uint8_t)));
    if (storage == nullptr) {
      throw std::bad_alloc{};
    }

    const auto retained = readable();
    std::copy(retained.begin(), retained.end(), storage);
    if (bytes_ != nullptr) {
      memory_.deallocate(bytes_, capacity_, alignof(std::uint8_t));
    }
    written_ = retained.size();
    consumed_ = 0;
    bytes_ = storage;
    capacity_ = capacity;
  }

  inline std::size_t size() const noexcept {
    return written_ - consumed_;
  }

  inline bool empty() const noexcept {
    return size() == 0;
  }

private:
  inline void compact() noexcept {
    if (consumed_ != 0) {
      const auto remaining = size();
      std::memmove(bytes_, bytes_ + consumed_, remaining);
      written_ = remaining;
      consumed_ = 0;
    }
  }

  Memory &memory_;
  std::size_t limit_;
  std::uint8_t *bytes_ = nullptr;
  std::size_t capacity_ = 0;
  std::size_t written_ = 0;
  std::size_t consumed_ = 0;
};

}
}

// Interface: telar_base/memory/c_allocation_blocks.cppm
export {
namespace telar {

template <Allocator Memory>
class CAllocationBlocks {
public:
  inline explicit CAllocationBlocks(Memory &memory) noexcept : memory_(memory) {}

  inline void *allocate(std::size_t size) noexcept {
    if (size > std::numeric_limits<std::size_t>::max() - sizeof(Header)) {
      return nullptr;
    }
    auto *header = static_cast<Header *>(memory_.allocate(sizeof(Header) + size, alignof(Header)));
    if (header == nullptr) {
      return nullptr;
    }
    std::construct_at(header, Header{size});
    return header + 1;
  }

  inline void *allocateZeroed(std::size_t count, std::size_t size) noexcept {
    if (size != 0 && count > std::numeric_limits<std::size_t>::max() / size) {
      return nullptr;
    }
    auto *pointer = allocate(count * size);
    if (pointer != nullptr) {
      std::memset(pointer, 0, count * size);
    }
    return pointer;
  }

  inline void release(void *pointer) noexcept {
    if (pointer != nullptr) {
      auto *header = static_cast<Header *>(pointer) - 1;
      memory_.deallocate(header, sizeof(Header) + header->size, alignof(Header));
    }
  }

  inline void *resize(void *pointer, std::size_t size) noexcept {
    if (pointer == nullptr) {
      return allocate(size);
    }
    if (size == 0) {
      release(pointer);
      return nullptr;
    }

    auto *replacement = allocate(size);
    if (replacement != nullptr) {
      const auto *header = static_cast<const Header *>(pointer) - 1;
      std::memcpy(replacement, pointer, std::min(header->size, size));
      release(pointer);
    }
    return replacement;
  }

private:
  struct alignas(std::max_align_t) Header {
    std::size_t size;
  };

  Memory &memory_;
};

template <Allocator Memory>
CAllocationBlocks(Memory &memory) -> CAllocationBlocks<Memory>;

}
}

// Interface: telar_base/memory/drop_channel.cppm
export {
namespace telar::runtime {

struct TransferQueueMetrics {
  std::uint64_t queued = 0;
  std::uint64_t high_water = 0;
  std::uint64_t dropped = 0;
};

enum class ChannelPolicy { best_effort,
                           keep_oldest,
                           keep_newest };

template <typename Value, std::size_t Capacity, ChannelPolicy policy = ChannelPolicy::best_effort>
  requires std::is_nothrow_move_constructible_v<Value> && std::is_nothrow_swappable_v<Value>
class DropChannel {
  static_assert(Capacity != 0);

public:
  inline bool publish(Value value) noexcept {
    std::optional<Value> discarded;
    const auto lock = acquire();
    if (!lock.owns_lock() || closed_) {
      dropped_.fetch_add(1, std::memory_order_relaxed);
      return false;
    }

    if (count_ == Capacity) {
      dropped_.fetch_add(1, std::memory_order_relaxed);
      if constexpr (policy == ChannelPolicy::keep_newest) {
        discarded = take();
      } else {
        return false;
      }
    }

    slots_[(head_ + count_) % Capacity].emplace(std::move(value));
    ++count_;
    queued_.store(count_, std::memory_order_relaxed);
    high_water_.store(std::max(high_water_.load(std::memory_order_relaxed), static_cast<std::uint64_t>(count_)), std::memory_order_relaxed);
    ready_.notify_one();
    return true;
  }

  inline std::optional<Value> receive() {
    std::unique_lock lock{mutex_};
    ready_.wait(lock, [&] { return count_ != 0 || closed_; });
    return take();
  }

  inline std::optional<Value> tryReceive() noexcept {
    const auto lock = acquire();
    return lock.owns_lock() ? take() : std::nullopt;
  }

  inline void close() noexcept {
    std::array<std::optional<Value>, Capacity> discarded;
    {
      const std::lock_guard lock{mutex_};
      closed_ = true;
      discarded.swap(slots_);
      count_ = 0;
      head_ = 0;
      queued_.store(0, std::memory_order_relaxed);
    }
    ready_.notify_all();
  }

  inline TransferQueueMetrics metrics() const noexcept {
    return {queued_.load(std::memory_order_relaxed), high_water_.load(std::memory_order_relaxed), dropped_.load(std::memory_order_relaxed)};
  }

private:
  inline std::unique_lock<std::mutex> acquire() noexcept {
    if constexpr (policy == ChannelPolicy::best_effort) {
      return std::unique_lock{mutex_, std::try_to_lock};
    } else {
      return std::unique_lock{mutex_};
    }
  }

  inline std::optional<Value> take() noexcept {
    if (count_ == 0) {
      return std::nullopt;
    }
    auto value = std::move(slots_[head_]);
    slots_[head_].reset();
    head_ = (head_ + 1) % Capacity;
    --count_;
    queued_.store(count_, std::memory_order_relaxed);
    return value;
  }

  std::mutex mutex_;
  std::condition_variable ready_;
  std::array<std::optional<Value>, Capacity> slots_;
  std::size_t head_ = 0;
  std::size_t count_ = 0;
  bool closed_ = false;
  std::atomic<std::uint64_t> queued_{0};
  std::atomic<std::uint64_t> high_water_{0};
  std::atomic<std::uint64_t> dropped_{0};
};

}
}

// Interface: telar_base/memory/erase_sensitive.cppm
export {
namespace telar {

inline void eraseSensitive(void *storage, std::size_t length) noexcept {
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
class ErasingAllocator {
public:
  static constexpr bool thread_safe = ConcurrentAllocator<Upstream>;

  inline explicit ErasingAllocator(Upstream &upstream) noexcept
      : upstream_(upstream) {}

  inline void *allocate(std::size_t size, std::size_t alignment) noexcept {
    return upstream_.allocate(size, alignment);
  }

  inline void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    if (pointer != nullptr) {
      eraseSensitive(pointer, size);
      upstream_.deallocate(pointer, size, alignment);
    }
  }

private:
  Upstream &upstream_;
};

template <Allocator Upstream>
ErasingAllocator(Upstream &upstream) -> ErasingAllocator<Upstream>;

}
}

// Interface: telar_base/memory/recycling_allocator.cppm
export {
namespace telar {

template <Allocator Upstream>
class RecyclingAllocator {
public:
  static constexpr bool thread_safe = false;

  inline explicit RecyclingAllocator(Upstream &upstream) noexcept : upstream_(upstream) {}

  inline ~RecyclingAllocator() {
    for (std::size_t index = 0; index < available_.size(); ++index) {
      const auto capacity = (index + 1) * block_alignment;
      while (auto *block = available_[index]) {
        available_[index] = block->next;
        eraseSensitive(block, capacity);
        upstream_.deallocate(block, capacity, block_alignment);
      }
    }
  }

  RecyclingAllocator(const RecyclingAllocator &) = delete;
  RecyclingAllocator &operator=(const RecyclingAllocator &) = delete;

  inline void *allocate(std::size_t size, std::size_t alignment) noexcept {
    if (!recyclable(size, alignment)) {
      return upstream_.allocate(size, alignment);
    }

    const auto index = bucket(size);
    const auto capacity = (index + 1) * block_alignment;
    if (auto *block = available_[index]) {
      available_[index] = block->next;
      retained_bytes_ -= capacity;
      return block;
    }
    return upstream_.allocate(capacity, block_alignment);
  }

  inline void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
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

    available_[index] = std::construct_at(static_cast<Block *>(pointer), Block{available_[index]});
    retained_bytes_ += capacity;
  }

  inline std::size_t retainedBytes() const noexcept { return retained_bytes_; }

  static constexpr std::size_t maximum_retained_bytes = 512 * 1024;

private:
  struct Block {
    Block *next;
  };

  inline static bool recyclable(std::size_t size, std::size_t alignment) noexcept {
    return size != 0 && size <= maximum_block_bytes && alignment <= block_alignment;
  }

  inline static std::size_t bucket(std::size_t size) noexcept {
    return (size - 1) / block_alignment;
  }

  static constexpr std::size_t block_alignment = alignof(std::max_align_t);
  static constexpr std::size_t maximum_block_bytes = 4096;
  Upstream &upstream_;
  std::array<Block *, maximum_block_bytes / block_alignment> available_{};
  std::size_t retained_bytes_ = 0;
};

}
}

// Interface: telar_base/memory/retained_stream.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class RetainedStream {
  using Byte = std::uint8_t;

public:
  inline explicit RetainedStream(Memory &memory, std::size_t capacity)
      : memory_(memory),
        capacity_(capacity) {
    bytes_ = static_cast<Byte *>(memory_.allocate(capacity_, alignof(Byte)));
    if (bytes_ == nullptr) {
      throw std::bad_alloc{};
    }
  }

  inline ~RetainedStream() {
    memory_.deallocate(bytes_, capacity_, alignof(Byte));
  }

  RetainedStream(const RetainedStream &) = delete;
  RetainedStream &operator=(const RetainedStream &) = delete;

  inline void append(std::span<const Byte> bytes) noexcept {
    total_ += bytes.size();
    bytes = bytes.last(std::min(bytes.size(), capacity_));
    const auto start = static_cast<std::size_t>((total_ - bytes.size()) % capacity_);
    const auto first = std::min(bytes.size(), capacity_ - start);
    std::memcpy(bytes_ + start, bytes.data(), first);
    std::memcpy(bytes_, bytes.data() + first, bytes.size() - first);
  }

  inline std::span<const Byte> read(std::uint64_t offset, std::span<Byte> destination) const noexcept {
    if (offset < retainedOffset() || offset >= total_) {
      return {};
    }

    const auto count = static_cast<std::size_t>(std::min<std::uint64_t>(destination.size(), total_ - offset));
    const auto start = static_cast<std::size_t>(offset % capacity_);
    const auto first = std::min(count, capacity_ - start);
    std::memcpy(destination.data(), bytes_ + start, first);
    std::memcpy(destination.data() + first, bytes_, count - first);
    return destination.first(count);
  }

  inline std::uint64_t total() const noexcept {
    return total_;
  }

  inline std::uint64_t retainedOffset() const noexcept {
    return total_ - std::min<std::uint64_t>(total_, capacity_);
  }

private:
  Memory &memory_;
  Byte *bytes_;
  std::size_t capacity_;
  std::uint64_t total_ = 0;
};

template <Allocator Memory>
RetainedStream(Memory &memory, std::size_t capacity) -> RetainedStream<Memory>;

}
}

// Interface: telar_base/memory/sensitive_allocation.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class SensitiveAllocation {
public:
  inline explicit SensitiveAllocation(Memory &memory, std::size_t size) : memory_(&memory), size_(size) {
    if (size != 0) {
      storage_ = static_cast<std::uint8_t *>(memory.allocate(size, alignof(std::uint8_t)));
      if (storage_ == nullptr) {
        throw std::bad_alloc{};
      }
    }
  }

  inline ~SensitiveAllocation() { release(); }

  SensitiveAllocation(const SensitiveAllocation &) = delete;
  SensitiveAllocation &operator=(const SensitiveAllocation &) = delete;

  inline SensitiveAllocation(SensitiveAllocation &&other) noexcept
      : memory_(other.memory_), storage_(std::exchange(other.storage_, nullptr)), size_(std::exchange(other.size_, 0)) {}

  SensitiveAllocation &operator=(SensitiveAllocation &&other) noexcept {
    if (this != &other) {
      release();
      memory_ = other.memory_;
      storage_ = std::exchange(other.storage_, nullptr);
      size_ = std::exchange(other.size_, 0);
    }
    return *this;
  }

  inline std::span<std::uint8_t> bytes() noexcept { return {storage_, size_}; }
  inline std::span<const std::uint8_t> bytes() const noexcept { return {storage_, size_}; }

private:
  inline void release() noexcept {
    ErasingAllocator sensitive{*memory_};
    sensitive.deallocate(storage_, size_, alignof(std::uint8_t));
  }

  Memory *memory_;
  std::uint8_t *storage_ = nullptr;
  std::size_t size_;
};

template <Allocator Memory>
SensitiveAllocation(Memory &memory, std::size_t size) -> SensitiveAllocation<Memory>;

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

  SensitiveBuffer(const SensitiveBuffer &) = delete;
  SensitiveBuffer &operator=(const SensitiveBuffer &) = delete;

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

  inline SensitiveText(const SensitiveText &other) noexcept {
    copy(other);
  }

  SensitiveText &operator=(const SensitiveText &other) noexcept {
    if (this != &other) {
      clear();
      copy(other);
    }

    return *this;
  }

  inline SensitiveText(SensitiveText &&other) noexcept {
    copy(other);
    other.clear();
  }

  SensitiveText &operator=(SensitiveText &&other) noexcept {
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
  inline void copy(const SensitiveText &other) noexcept {
    length_ = other.length_;
    std::memcpy(bytes_.data(), other.bytes_.data(), length_);
  }

  std::array<char, Capacity> bytes_;
  std::size_t length_ = 0;
};

}
}

// Interface: telar_base/memory/slot_indexes.cppm
export {
namespace telar::runtime {

template <std::size_t Capacity>
class SlotIndexes {
  static_assert(Capacity > 0);

public:
  inline void insert(std::size_t index) noexcept {
    words_[index / word_bits] |= std::uint64_t{1} << (index % word_bits);
  }

  inline void erase(std::size_t index) noexcept {
    words_[index / word_bits] &= ~(std::uint64_t{1} << (index % word_bits));
  }

  inline std::optional<std::size_t> firstUnused() const noexcept {
    for (std::size_t word = 0; word < words_.size(); ++word) {
      if (const auto available = ~words_[word]; available != 0) {
        const auto index = word * word_bits + std::countr_zero(available);
        return index < Capacity ? std::optional{index} : std::nullopt;
      }
    }
    return std::nullopt;
  }

  template <typename Visitor>
  inline void forEach(Visitor &&visit) const {
    for (std::size_t word = 0; word < words_.size(); ++word) {
      auto remaining = words_[word];
      while (remaining != 0) {
        const auto bit = std::countr_zero(remaining);
        remaining &= remaining - 1;
        visit(word * word_bits + bit);
      }
    }
  }

private:
  static constexpr std::size_t word_bits = 64;
  std::array<std::uint64_t, (Capacity + word_bits - 1) / word_bits> words_{};
};

}
}
