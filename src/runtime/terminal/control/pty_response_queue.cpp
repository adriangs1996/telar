module;
#include "telar_base/diagnostics/config.hpp"

module telar.runtime.terminal.control;

import telar.runtime.diagnostics.line;
import telar.base.ds;

namespace telar::runtime {

  PtyResponseQueue::PtyResponseQueue() noexcept = default; // NOLINT(cppcoreguidelines-pro-type-member-init): a slot's bytes are written when a reply is published, so zeroing the queue's 64 KiB at construction is work no reader needs

  PtyResponseQueue::Producer::Producer(PtyResponseQueue& queue)
      : queue_(queue),
        lock_(queue.mutex_, std::defer_lock) {}

  bool PtyResponseQueue::Producer::tryPush(std::span<const std::uint8_t> response) noexcept {
    if (!acquire()) {
      return false;
    }

    return queue_.append(response);
  }

  bool PtyResponseQueue::Producer::tryPushOwned(std::span<const std::uint8_t> response, std::shared_ptr<const void> owner) noexcept {
    if (!acquire()) {
      return false;
    }

    return queue_.append(response, std::move(owner));
  }

  void PtyResponseQueue::Producer::release() noexcept {
    if (lock_.owns_lock()) {
      lock_.unlock();
    }
  }

  bool PtyResponseQueue::Producer::acquire() {
    if (!lock_.owns_lock()) {
      lock_.lock();
      if (queue_.priority_workers_ != 0) {
        lock_.unlock();
        return false;
      }
    }

    return true;
  }

  bool PtyResponseQueue::push(std::span<const std::uint8_t> response) noexcept {
    const std::scoped_lock lock{mutex_};

    if (closed_) {
      return false;
    }

    if (!append(response)) {
      diagnostics::accumulate(dropped_);
      return false;
    }

    return true;
  }

  bool PtyResponseQueue::tryPush(std::span<const std::uint8_t> response) noexcept {
    const std::scoped_lock lock{mutex_};

    return append(response);
  }

  bool PtyResponseQueue::tryPushOwned(std::span<const std::uint8_t> response, std::shared_ptr<const void> owner) noexcept {
    const std::scoped_lock lock{mutex_};

    return append(response, std::move(owner));
  }

  bool PtyResponseQueue::hasCapacityFor(std::size_t bytes) const noexcept {
    const std::scoped_lock lock{mutex_};

    return !closed_ && count_ != message_capacity && bytes <= total_byte_capacity - byte_count_;
  }

  bool PtyResponseQueue::closed() const noexcept {
    const std::scoped_lock lock{mutex_};

    return closed_;
  }

  bool PtyResponseQueue::retainWorkerPriority() noexcept {
    const std::scoped_lock lock{mutex_};

    if (closed_) {
      return false;
    }

    ++priority_workers_;
    return true;
  }

  void PtyResponseQueue::releaseWorkerPriority() noexcept {
    const std::scoped_lock lock{mutex_};

    TELAR_ASSERT(priority_workers_ != 0);
    --priority_workers_;
  }

  bool PtyResponseQueue::append(std::span<const std::uint8_t> response) noexcept {
    if (!admits(response.size()) || response.size() > message_byte_capacity) {
      return false;
    }

    const auto index = (head_ + count_) % message_capacity;

    std::ranges::copy(response, bytes_.atMut(index).viewMut().begin());
    commit(index, std::span<const std::uint8_t>{bytes_[index]}.first(response.size()));
    return true;
  }

  bool PtyResponseQueue::append(std::span<const std::uint8_t> response, std::shared_ptr<const void> owner) noexcept {
    if (!owner) {
      return append(response);
    }

    if (!admits(response.size())) {
      return false;
    }

    const auto index = (head_ + count_) % message_capacity;

    owned_.atMut(index) = std::move(owner);
    commit(index, response);
    return true;
  }

  ds::Option<std::span<const std::uint8_t>> PtyResponseQueue::peek() const noexcept {
    const std::scoped_lock lock{mutex_};

    if (count_ == 0) {
      return ds::none;
    }

    const auto head = owned_[head_] ? views_[head_] : std::span<const std::uint8_t>{bytes_[head_]}.first(lengths_[head_]);

    return head.subspan(offset_);
  }

  PtyResponseQueue::Batch PtyResponseQueue::peekBatch() const noexcept {
    const std::scoped_lock lock{mutex_};
    const auto first_count = std::min(count_, message_capacity - head_);
    const auto entries = std::span{views_};

    return Batch{
        .first = entries.subspan(head_, first_count),
        .second = entries.first(count_ - first_count),
        .offset = offset_,
        .count = count_,
        .bytes = byte_count_,
    };
  }

  void PtyResponseQueue::consumeBytes(std::size_t bytes) noexcept {
    const std::scoped_lock lock{mutex_};

    TELAR_ASSERT(bytes <= byte_count_);
    while (count_ != 0) {
      const auto remaining = lengths_[head_] - offset_;
      const auto count = std::min<std::size_t>(remaining, bytes);

      consumeHead(count);
      bytes -= count;
      if (count < remaining || (bytes == 0 && (count_ == 0 || lengths_[head_] != 0))) {
        break;
      }
    }
  }

  std::span<const std::uint8_t> PtyResponseQueue::readable() const noexcept {
    return peek().valueOr(std::span<const std::uint8_t>{});
  }

  void PtyResponseQueue::consume(std::size_t bytes) noexcept {
    const std::scoped_lock lock{mutex_};

    TELAR_ASSERT(count_ != 0 && bytes <= lengths_[head_] - offset_);
    consumeHead(bytes);
  }

  void PtyResponseQueue::consumeHead(std::size_t bytes) noexcept {
    offset_ += bytes;
    byte_count_ -= bytes;
    if (offset_ == lengths_[head_]) {
      owned_.atMut(head_).reset();
      views_.atMut(head_) = {};
      head_ = (head_ + 1) % message_capacity;
      offset_ = 0;
      --count_;
    }
  }

  bool PtyResponseQueue::empty() const noexcept {
    const std::scoped_lock lock{mutex_};

    return count_ == 0;
  }

  void PtyResponseQueue::stopProducing() noexcept {
    const std::scoped_lock lock{mutex_};

    closed_ = true;
  }

  void PtyResponseQueue::close() noexcept {
    const std::scoped_lock lock{mutex_};

    closed_ = true;
    clearLocked();
  }

  void PtyResponseQueue::clear() noexcept {
    const std::scoped_lock lock{mutex_};

    clearLocked();
  }

  void PtyResponseQueue::clearLocked() noexcept {
    for (auto& owner : owned_.viewMut()) {
      owner.reset();
    }

    head_ = 0;
    count_ = 0;
    offset_ = 0;
    byte_count_ = 0;
  }

  PtyResponseQueue::Snapshot PtyResponseQueue::snapshot() const noexcept {
    const std::scoped_lock lock{mutex_};

    return {.messages = count_, .bytes = byte_count_, .dropped = dropped_};
  }

}
