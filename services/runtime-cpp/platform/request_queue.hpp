#pragma once

#include "telar_base/memory/allocator.hpp"
#include <cassert>
#include <optional>
#include <type_traits>

namespace telar::runtime {

template <typename Value, std::size_t Capacity, ConcurrentAllocator Memory>
class RequestQueue {
  static_assert(Capacity != 0 && std::is_nothrow_move_constructible_v<Value>);

public:
  explicit RequestQueue(Memory &memory)
      : slots_(Capacity, AllocatorRef<std::optional<Value>, Memory>{memory}) {}

  bool empty() const noexcept {
    return count_ == 0;
  }

  bool full() const noexcept {
    return count_ == Capacity;
  }

  std::size_t size() const noexcept {
    return count_;
  }

  Value &operator[](std::size_t offset) noexcept {
    assert(offset < count_);
    return *slots_[(head_ + offset) % Capacity];
  }

  const Value &operator[](std::size_t offset) const noexcept {
    assert(offset < count_);
    return *slots_[(head_ + offset) % Capacity];
  }

  template <typename... Arguments>
  Value &emplace(Arguments &&...arguments) {
    assert(!full());
    auto &value = slots_[(head_ + count_) % Capacity].emplace(std::forward<Arguments>(arguments)...);
    ++count_;
    return value;
  }

  void removeLast() noexcept {
    assert(!empty());
    --count_;
    slots_[(head_ + count_) % Capacity].reset();
  }

  Value take() noexcept {
    assert(!empty());
    auto value = std::move(*slots_[head_]);
    slots_[head_].reset();
    head_ = (head_ + 1) % Capacity;
    --count_;
    return value;
  }

  void swap(RequestQueue &other) noexcept {
    assert(slots_.get_allocator() == other.slots_.get_allocator());
    slots_.swap(other.slots_);
    std::swap(head_, other.head_);
    std::swap(count_, other.count_);
  }

private:
  Vector<std::optional<Value>, Memory> slots_;
  std::size_t head_ = 0;
  std::size_t count_ = 0;
};

}
