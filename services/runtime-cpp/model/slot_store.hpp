#pragma once

#include "identity_counter.hpp"
#include "telar_base/memory/allocator.hpp"
#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>

namespace telar::runtime {

template <typename Value, std::size_t Capacity, Allocator Memory>
class SlotStore {
  static_assert(Capacity > 0 && Capacity <= UINT16_MAX);

public:
  explicit SlotStore(Memory &memory) noexcept
      : memory_(memory) {}

  ~SlotStore() {
    for (auto *value : items_) {
      if (value != nullptr) {
        AllocationDeleter<Value, Memory>{memory_}(value);
      }
    }
  }

  SlotStore(const SlotStore &) = delete;
  SlotStore &operator=(const SlotStore &) = delete;

  std::uint64_t nextId() const {
    if (count_ == Capacity || next_id_ == 0) {
      throw std::bad_alloc{};
    }

    return next_id_;
  }

  std::uint64_t insert(std::uint64_t id, Owned<Value, Memory> value) {
    const auto handle = insertProvisional(id, std::move(value));
    advanceCounter(id + 1);
    return handle;
  }

  std::uint64_t insertProvisional(std::uint64_t id, Owned<Value, Memory> value) {
    if (id == 0 || count_ == Capacity || find(id) != nullptr) {
      throw std::bad_alloc{};
    }

    std::size_t slot = 0;
    while (items_[slot] != nullptr) {
      ++slot;
    }

    if (generations_[slot] == std::numeric_limits<std::uint64_t>::max() / Capacity - 1) {
      throw std::bad_alloc{};
    }

    ++generations_[slot];
    identities_[slot] = id;
    lookup_[bucket(id)] = static_cast<std::uint16_t>(slot + 1);
    items_[slot] = value.release();
    ++count_;
    return generations_[slot] * Capacity + slot;
  }

  Value *findHandle(std::uint64_t handle) const noexcept {
    const auto slot = handle % Capacity;
    return generations_[slot] == handle / Capacity ? items_[slot] : nullptr;
  }

  Value *find(std::uint64_t id) const noexcept {
    const auto slot = slotOf(id);
    return slot ? items_[*slot] : nullptr;
  }

  void erase(std::uint64_t id) noexcept {
    auto *value = find(id);
    if (value == nullptr) {
      return;
    }

    const auto position = bucket(id);
    const auto slot = lookup_[position] - 1;
    removeBucket(position);
    identities_[slot] = 0;
    items_[slot] = nullptr;
    --count_;
    AllocationDeleter<Value, Memory>{memory_}(value);
  }

  std::size_t size() const noexcept {
    return count_;
  }

  void advanceCounter(std::uint64_t next) noexcept {
    advanceIdentityCounter(next_id_, next);
  }

  std::uint64_t nextCounter() const noexcept {
    return next_id_;
  }

  std::span<Value *const> items() const noexcept {
    return items_;
  }

  std::optional<std::size_t> slotOf(std::uint64_t id) const noexcept {
    const auto stored = id == 0 ? 0 : lookup_[bucket(id)];
    return stored == 0 ? std::nullopt : std::optional<std::size_t>{stored - 1};
  }

private:
  static constexpr std::size_t lookup_capacity = 2 * Capacity;

  static std::size_t hash(std::uint64_t identity) noexcept {
    return static_cast<std::size_t>(identity % lookup_capacity);
  }

  std::size_t bucket(std::uint64_t identity) const noexcept {
    auto position = hash(identity);
    while (lookup_[position] != 0 && identities_[lookup_[position] - 1] != identity) {
      position = (position + 1) % lookup_capacity;
    }

    return position;
  }

  void removeBucket(std::size_t hole) noexcept {
    auto position = (hole + 1) % lookup_capacity;
    while (lookup_[position] != 0) {
      const auto origin = hash(identities_[lookup_[position] - 1]);
      const auto distance = (position + lookup_capacity - origin) % lookup_capacity;
      const auto hole_distance = (hole + lookup_capacity - origin) % lookup_capacity;
      if (hole_distance < distance) {
        lookup_[hole] = lookup_[position];
        hole = position;
      }

      position = (position + 1) % lookup_capacity;
    }

    lookup_[hole] = 0;
  }

  Memory &memory_;
  std::array<Value *, Capacity> items_{};
  std::array<std::uint64_t, Capacity> identities_{};
  std::array<std::uint64_t, Capacity> generations_{};
  std::array<std::uint16_t, lookup_capacity> lookup_{};
  std::uint64_t next_id_ = 1;
  std::size_t count_ = 0;
};

}
