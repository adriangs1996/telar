module;
#include "telar_base/diagnostics/config.hpp"

export module telar.base.memory.containers;

import std;
import telar.tbc;
import telar.base.memory.allocators;
import telar.base.ds;

export {
  namespace telar::runtime {

    template <std::size_t Capacity>
    class [[tbc::generic]] FixedText {
    public:
      FixedText() noexcept {} // NOLINT(modernize-use-equals-default): user-provided, so that value-initializing one leaves its bytes unwritten

      // Copies and moves copy only the text, not the bytes past it.
      FixedText(const FixedText& other) noexcept {
        copy(other.view());
      }

      FixedText(FixedText&& other) noexcept {
        copy(other.view());
      }

      FixedText& operator=(const FixedText& other) noexcept {
        if (this != &other) {
          copy(other.view());
        }

        return *this;
      }

      FixedText& operator=(FixedText&& other) noexcept {
        if (this != &other) {
          copy(other.view());
        }

        return *this;
      }

      ~FixedText() = default;

      void assign(std::string_view text) {
        if (text.size() > Capacity) {
          throw std::length_error{"Fixed text capacity exceeded"};
        }

        copy(text);
      }

      [[nodiscard]] std::string_view view() const noexcept {
        return {bytes_.data(), length_};
      }

      // Equal texts are equal, whatever the bytes past them hold.
      friend bool operator==(const FixedText& left, const FixedText& right) noexcept {
        return left.view() == right.view();
      }

    private:
      // The text may be a part of this one's, which lies at or after where it goes.
      void copy(std::string_view text) noexcept {
        if (text.data() != bytes_.data()) {
          std::ranges::copy(text, bytes_.viewMut().begin());
        }

        length_ = text.size();
      }

      ds::Array<char, Capacity> bytes_;
      std::size_t length_ = 0;
    };

    // The message an error carries. It joins its parts when the error is thrown and keeps what fits
    // in its capacity, so throwing never allocates and never fails for lack of memory; the NUL after
    // it lets `what()` hand it out as it is.
    //
    // The parts are separate arguments, each read as a std::string_view: a braced pair of texts would
    // otherwise build one view from two unrelated pointers.
    template <std::size_t Capacity>
    class [[tbc::generic]] ErrorText {
    public:
      template <typename... Parts>
        requires(sizeof...(Parts) != 0 && (std::is_convertible_v<const Parts&, std::string_view> && ...))
      explicit ErrorText(const Parts&... parts) noexcept {
        (append(parts), ...);
        bytes_.atMut(length_) = '\0';
      }

      [[nodiscard]] const char* cStr() const noexcept {
        return bytes_.data();
      }

      [[nodiscard]] std::string_view view() const noexcept {
        return {bytes_.data(), length_};
      }

    private:
      void append(std::string_view part) noexcept {
        const auto count = std::min(part.size(), Capacity - length_);

        std::ranges::copy(std::span<const char>{part}.first(count), bytes_.viewMut().subspan(length_).begin());
        length_ += count;
      }

      ds::Array<char, Capacity + 1> bytes_;
      std::size_t length_ = 0;
    };

  }
}

// Interface: telar_base/memory/byte_queue.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class [[tbc::generic]] ByteQueue {
    public:
      inline explicit ByteQueue(Memory& memory, std::size_t limit) noexcept
          : memory_(memory),
            limit_(limit) {}

      inline ~ByteQueue() {
        if (bytes_ != nullptr) {
          memory_.deallocate(bytes_, capacity_, alignof(std::uint8_t));
        }
      }

      ByteQueue(const ByteQueue&) = delete;
      ByteQueue& operator=(const ByteQueue&) = delete;
      ByteQueue(ByteQueue&&) = delete;
      ByteQueue& operator=(ByteQueue&&) = delete;

      // Exchanges contents with a queue of the same allocator, as Rust's `mem::swap` moves buffers.
      inline void swap(ByteQueue& other) noexcept {
        TELAR_ASSERT(&memory_ == &other.memory_);
        std::swap(limit_, other.limit_);
        std::swap(bytes_, other.bytes_);
        std::swap(capacity_, other.capacity_);
        std::swap(written_, other.written_);
        std::swap(consumed_, other.consumed_);
      }

      [[nodiscard]] inline std::span<const std::uint8_t> readable() const noexcept {
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

        auto* start = bytes_ == nullptr ? nullptr : bytes_ + written_;

        written_ += count;
        return {start, count};
      }

      inline void append(std::span<const std::uint8_t> input) {
        auto output = appendUninitialized(input.size());

        std::copy(input.begin(), input.end(), output.begin());
      }

      inline std::span<std::uint8_t> insertUninitialized(std::size_t offset, std::size_t count) {
        const auto previous_size = size();

        TELAR_ASSERT(offset <= previous_size);
        appendUninitialized(count);
        auto* start = bytes_ + consumed_ + offset;

        std::memmove(start + count, start, previous_size - offset);
        return {start, count};
      }

      inline void consume(std::size_t count) noexcept {
        TELAR_ASSERT(count <= size());
        consumed_ += count;
        if (consumed_ == written_) {
          clear();
        }
      }

      inline void truncate(std::size_t length) noexcept {
        TELAR_ASSERT(length <= size());
        written_ = consumed_ + length;
      }

      inline void overwrite(std::size_t offset, std::span<const std::uint8_t> bytes) noexcept {
        TELAR_ASSERT(offset <= size() && bytes.size() <= size() - offset);
        std::memmove(bytes_ + consumed_ + offset, bytes.data(), bytes.size());
      }

      inline void erase(std::size_t offset, std::size_t count) noexcept {
        TELAR_ASSERT(offset <= size() && count <= size() - offset);
        if (offset == 0) {
          consume(count);
          return;
        }

        auto* start = bytes_ + consumed_ + offset;

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
        auto* storage = static_cast<std::uint8_t*>(memory_.allocate(capacity, alignof(std::uint8_t)));
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

      [[nodiscard]] inline std::size_t size() const noexcept {
        return written_ - consumed_;
      }

      [[nodiscard]] inline bool empty() const noexcept {
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

      Memory& memory_;
      std::size_t limit_;
      std::uint8_t* bytes_ = nullptr;
      std::size_t capacity_ = 0;
      std::size_t written_ = 0;
      std::size_t consumed_ = 0;
    };

  }
}

// Interface: telar_base/memory/byte_storage.cppm
export {
  namespace telar::runtime {

    // Bytes from an allocator in region `a`, left as the allocator returns them: for a buffer its
    // owner writes before it reads, where zeroing it first would be wasted work.
    template <Allocator Memory>
    class ByteStorage {
    public:
      explicit ByteStorage(tbc::mut_a<Memory> memory, std::size_t size);
      ~ByteStorage();

      ByteStorage(const ByteStorage&) = delete;
      ByteStorage& operator=(const ByteStorage&) = delete;
      ByteStorage(ByteStorage&&) = delete;
      ByteStorage& operator=(ByteStorage&&) = delete;

      std::span<std::uint8_t> bytesMut() noexcept;
      [[nodiscard]] std::span<const std::uint8_t> bytes() const noexcept;

    private:
      tbc::mut_a<Memory> memory_;
      std::uint8_t* storage_ = nullptr;
      std::size_t size_;
    };

  }
}

// Instantiated in the implementation unit for the erased interfaces and for base's own allocators,
// which the tests of the services that use them still pass.
namespace telar::runtime {
  extern template class ByteStorage<Memory>;
  extern template class ByteStorage<ConcurrentMemory>;
  extern template class ByteStorage<SystemAllocator>;
  extern template class ByteStorage<BudgetAllocator<SystemAllocator>>;
}

// Interface: telar_base/memory/c_allocation_blocks.cppm
export {
  namespace telar {

    // The allocation hook of the C libraries, over the composed allocators that hand it their memory.
    template <Allocator Memory>
    class [[tbc::shared]] [[tbc::generic]] CAllocationBlocks {
    public:
      inline explicit CAllocationBlocks(Memory& memory) noexcept
          : memory_(memory) {}

      inline void* allocate(std::size_t size) noexcept {
        if (size > std::numeric_limits<std::size_t>::max() - sizeof(Header)) {
          return nullptr;
        }

        auto* header = static_cast<Header*>(memory_.allocate(sizeof(Header) + size, alignof(Header)));
        if (header == nullptr) {
          return nullptr;
        }

        std::construct_at(header, Header{size});
        return header + 1;
      }

      inline void* allocateZeroed(std::size_t count, std::size_t size) noexcept {
        if (size != 0 && count > std::numeric_limits<std::size_t>::max() / size) {
          return nullptr;
        }

        auto* pointer = allocate(count * size);
        if (pointer != nullptr) {
          std::memset(pointer, 0, count * size);
        }

        return pointer;
      }

      inline void release(void* pointer) noexcept {
        if (pointer != nullptr) {
          auto* header = static_cast<Header*>(pointer) - 1;

          memory_.deallocate(header, sizeof(Header) + header->size, alignof(Header));
        }
      }

      inline void* resize(void* pointer, std::size_t size) noexcept {
        if (pointer == nullptr) {
          return allocate(size);
        }

        if (size == 0) {
          release(pointer);
          return nullptr;
        }

        auto* replacement = allocate(size);
        if (replacement != nullptr) {
          const auto* header = static_cast<const Header*>(pointer) - 1;

          std::memcpy(replacement, pointer, std::min(header->size, size));
          release(pointer);
        }

        return replacement;
      }

    private:
      struct alignas(std::max_align_t) Header {
        std::size_t size;
      };

      Memory& memory_;
    };

    template <Allocator Memory>
    CAllocationBlocks(Memory& memory) -> CAllocationBlocks<Memory>;

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

    enum class ChannelPolicy : std::uint8_t {
      best_effort,
      keep_oldest,
      keep_newest,
    };

    // A bounded channel between threads, as a Rust channel is: both ends share it. Generic over the
    // value it carries, so no implementation unit can instantiate it for every importer.
    template <typename Value, std::size_t Capacity, ChannelPolicy policy = ChannelPolicy::best_effort>
      requires std::is_nothrow_move_constructible_v<Value> && std::is_nothrow_swappable_v<Value>
    class [[tbc::shared]] [[tbc::generic]] DropChannel {
      static_assert(Capacity != 0);

    public:
      inline bool publish(Value value) noexcept {
        ds::Option<Value> discarded;
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

        slots_.atMut((head_ + count_) % Capacity).emplace(std::move(value));
        ++count_;
        queued_.store(count_, std::memory_order_relaxed);
        high_water_.store(std::max(high_water_.load(std::memory_order_relaxed), static_cast<std::uint64_t>(count_)), std::memory_order_relaxed);
        ready_.notify_one();
        return true;
      }

      inline ds::Option<Value> receive() {
        std::unique_lock lock{mutex_};

        ready_.wait(lock, [&] {
          return count_ != 0 || closed_;
        });

        return take();
      }

      inline ds::Option<Value> tryReceive() noexcept {
        const auto lock = acquire();

        return lock.owns_lock() ? take() : ds::none;
      }

      inline void close() noexcept {
        ds::Array<ds::Option<Value>, Capacity> discarded;

        {
          const std::scoped_lock lock{mutex_};

          closed_ = true;
          std::swap(discarded, slots_);
          count_ = 0;
          head_ = 0;
          queued_.store(0, std::memory_order_relaxed);
        }

        ready_.notify_all();
      }

      inline TransferQueueMetrics metrics() const noexcept {
        return {.queued = queued_.load(std::memory_order_relaxed), .high_water = high_water_.load(std::memory_order_relaxed), .dropped = dropped_.load(std::memory_order_relaxed)};
      }

    private:
      inline std::unique_lock<std::mutex> acquire() noexcept {
        if constexpr (policy == ChannelPolicy::best_effort) {
          return std::unique_lock{mutex_, std::try_to_lock};
        } else {
          return std::unique_lock{mutex_};
        }
      }

      inline ds::Option<Value> take() noexcept {
        if (count_ == 0) {
          return ds::none;
        }

        auto value = std::move(slots_.atMut(head_));

        slots_.atMut(head_).reset();
        head_ = (head_ + 1) % Capacity;
        --count_;
        queued_.store(count_, std::memory_order_relaxed);
        return value;
      }

      std::mutex mutex_;
      std::condition_variable ready_;
      ds::Array<ds::Option<Value>, Capacity> slots_;
      std::size_t head_ = 0;
      std::size_t count_ = 0;
      bool closed_ = false;
      std::atomic<std::uint64_t> queued_{0};
      std::atomic<std::uint64_t> high_water_{0};
      std::atomic<std::uint64_t> dropped_{0};
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
      explicit RetainedStream(Memory& memory, std::size_t capacity);
      ~RetainedStream();

      RetainedStream(const RetainedStream&) = delete;
      RetainedStream& operator=(const RetainedStream&) = delete;
      RetainedStream(RetainedStream&&) = delete;
      RetainedStream& operator=(RetainedStream&&) = delete;

      void append(std::span<const Byte> bytes) noexcept;
      // The bytes copied into the caller's destination, not a view of the stream.
      [[nodiscard]] tbc::val_a<std::span<const Byte>> read(std::uint64_t offset, tbc::val_a<std::span<Byte>> destination) const noexcept;
      [[nodiscard]] std::uint64_t total() const noexcept;
      [[nodiscard]] std::uint64_t retainedOffset() const noexcept;

    private:
      Memory& memory_;
      Byte* bytes_;
      std::size_t capacity_;
      std::uint64_t total_ = 0;
    };

    template <Allocator Memory>
    RetainedStream(Memory& memory, std::size_t capacity) -> RetainedStream<Memory>;

  }
}

// Instantiated in the implementation unit for the erased interfaces and for base's own allocators,
// which the tests of the services that use them still pass.
namespace telar::runtime {
  extern template class RetainedStream<Memory>;
  extern template class RetainedStream<ConcurrentMemory>;
  extern template class RetainedStream<SystemAllocator>;
  extern template class RetainedStream<BudgetAllocator<SystemAllocator>>;
}

// Interface: telar_base/memory/slot_indexes.cppm
export {
  namespace telar::runtime {

    template <std::size_t Capacity>
    class [[tbc::generic]] SlotIndexes {
      static_assert(Capacity > 0);

    public:
      inline void insert(std::size_t index) noexcept {
        words_.atMut(index / word_bits) |= std::uint64_t{1} << (index % word_bits);
      }

      inline void erase(std::size_t index) noexcept {
        words_.atMut(index / word_bits) &= ~(std::uint64_t{1} << (index % word_bits));
      }

      [[nodiscard]] inline ds::Option<std::size_t> firstUnused() const noexcept {
        for (std::size_t word = 0; word < words_.size(); ++word) {
          if (const auto available = ~words_[word]; available != 0) {
            const auto index = (word * word_bits) + std::countr_zero(available);

            return index < Capacity ? ds::Option{index} : ds::none;
          }
        }

        return ds::none;
      }

      // Takes the visitor itself, as the lambdas callers pass build it in place.
      template <typename Visitor>
      inline void forEach(Visitor visit) const {
        for (std::size_t word = 0; word < words_.size(); ++word) {
          auto remaining = words_[word];

          while (remaining != 0) {
            const auto bit = std::countr_zero(remaining);

            remaining &= remaining - 1;
            visit((word * word_bits) + bit);
          }
        }
      }

    private:
      static constexpr std::size_t word_bits = 64;
      ds::Array<std::uint64_t, (Capacity + word_bits - 1) / word_bits> words_{};
    };

  }
}
