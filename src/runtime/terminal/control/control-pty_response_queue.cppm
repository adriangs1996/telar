module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.terminal.control:pty_response_queue;

import std;
import telar.tbc;
import telar.base.ds;

export namespace telar::runtime {

  // Responses a terminal produces and its pane's writer drains, under one mutex. Like a Rust channel, it
  // is shared by both ends and its implementation is trusted.
  class TBC_SHARED PtyResponseQueue {
  public:
    static constexpr std::size_t message_capacity = 64;
    static constexpr std::size_t message_byte_capacity = 1024;
    static constexpr std::size_t total_byte_capacity = 2 * 1024 * 1024;

    struct Snapshot {
      std::size_t messages;
      std::size_t bytes;
      std::uint64_t dropped;
    };

    // Response bytes are initialized when a slot is published, without clearing the entire queue at construction.
    PtyResponseQueue() noexcept;

    // A controller batches consecutive native replies under one lock. It must
    // release this lease before any backend write or callback can produce data.
    class Producer {
    public:
      explicit Producer(PtyResponseQueue& queue);

      bool tryPush(std::span<const std::uint8_t> response) noexcept;

      // Generic over the reply's length, which the caller fixes, so it stays here.
      template <std::size_t Length>
      TBC_GENERIC bool tryPushFixed(const std::array<std::uint8_t, Length>& response) noexcept {
        static_assert(Length <= message_byte_capacity);

        if (!acquire()) {
          return false;
        }

        return queue_.appendFixed(response);
      }

      bool tryPushOwned(std::span<const std::uint8_t> response, std::shared_ptr<const void> owner) noexcept;

      void release() noexcept;

    private:
      bool acquire();

      PtyResponseQueue& queue_;
      std::unique_lock<std::mutex> lock_;
    };

    struct Batch {
      std::span<const std::span<const std::uint8_t>> first;
      std::span<const std::span<const std::uint8_t>> second;
      std::size_t offset = 0;
      std::size_t count = 0;
      std::size_t bytes = 0;

      [[nodiscard]] constexpr std::span<const std::uint8_t> message(std::size_t index) const noexcept {
        TELAR_ASSERT(index < count);
        const auto value = index < first.size() ? first[index] : second[index - first.size()];

        return value.subspan(index == 0 ? offset : 0);
      }
    };

    bool push(std::span<const std::uint8_t> response) noexcept;

    bool tryPush(std::span<const std::uint8_t> response) noexcept;

    // Large replies retain immutable allocator-owned storage as one message, so
    // other producers cannot interleave bytes in the middle of a control string.
    bool tryPushOwned(std::span<const std::uint8_t> response, std::shared_ptr<const void> owner) noexcept;

    bool hasCapacityFor(std::size_t bytes) const noexcept;

    bool closed() const noexcept;

    // A retained worker ACK owns the next free slot. Native producers yield
    // their lease while the worker drains, avoiding starvation under query load.
    bool retainWorkerPriority() noexcept;

    void releaseWorkerPriority() noexcept;

    // A single consumer may borrow the head until consume or clear; producers only append behind it.
    ds::Option<std::span<const std::uint8_t>> peek() const noexcept;

    Batch peekBatch() const noexcept;

    // The batch borrows slot metadata and payload until the single consumer
    // consumes or clears. Producers publish exclusively behind its fixed prefix;
    // wrapping never overwrites an admitted slot before that consumer releases it.
    void consumeBytes(std::size_t bytes) noexcept;

    std::span<const std::uint8_t> readable() const noexcept;

    void consume(std::size_t bytes) noexcept;

    bool empty() const noexcept;

    // Workers may reject future publication, but only the single consumer may
    // clear storage: it can still be borrowing an owned reply for writev.
    void stopProducing() noexcept;

    // Closing permanently cancels this pane generation, including late worker callbacks.
    void close() noexcept;

    void clear() noexcept;

    Snapshot snapshot() const noexcept;

  private:
    // A reply without an owner is copied into its slot.
    bool append(std::span<const std::uint8_t> response) noexcept;

    // An owned reply keeps its view, and its owner keeps the bytes behind that view alive.
    bool append(std::span<const std::uint8_t> response, std::shared_ptr<const void> owner) noexcept;

    // A fixed reply copies its known length, which the producer's caller fixes, so it stays here.
    template <std::size_t Length>
    TBC_GENERIC bool appendFixed(const std::array<std::uint8_t, Length>& response) noexcept {
      if (!admits(Length)) {
        return false;
      }

      const auto index = (head_ + count_) % message_capacity;

      std::memcpy(bytes_[index].data(), response.data(), Length);
      commit(index, std::span<const std::uint8_t>{bytes_[index]}.first(Length));
      return true;
    }

    constexpr void commit(const std::size_t index, std::span<const std::uint8_t> view) noexcept {
      views_[index] = view;
      lengths_[index] = static_cast<std::uint32_t>(view.size());
      byte_count_ += view.size();
      ++count_;
    }

    constexpr bool admits(std::size_t bytes) const noexcept {
      return !closed_ && count_ != message_capacity && bytes <= total_byte_capacity - byte_count_;
    }

    void consumeHead(std::size_t bytes) noexcept;

    void clearLocked() noexcept;

    mutable std::mutex mutex_;
    std::array<std::array<std::uint8_t, message_byte_capacity>, message_capacity> bytes_;
    std::array<std::uint32_t, message_capacity> lengths_;
    std::array<std::shared_ptr<const void>, message_capacity> owned_;
    std::array<std::span<const std::uint8_t>, message_capacity> views_;
    std::size_t head_ = 0;
    std::size_t count_ = 0;
    std::size_t offset_ = 0;
    std::size_t byte_count_ = 0;
    std::uint64_t dropped_ = 0;
    bool closed_ = false;
    std::size_t priority_workers_ = 0;
  };

}
