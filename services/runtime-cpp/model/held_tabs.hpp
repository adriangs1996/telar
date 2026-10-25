#pragma once

#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <optional>

namespace telar::runtime {

class HeldTabs {
public:
  static constexpr std::size_t capacity = 64;

  bool contains(TabLocation location) const noexcept {
    return find(location).has_value();
  }

  bool insert(TabLocation location) noexcept {
    if (contains(location)) {
      return true;
    }

    if (count_ == capacity) {
      return false;
    }

    locations_[count_++] = location;
    return true;
  }

  bool erase(TabLocation location) noexcept {
    const auto index = find(location);
    if (!index) {
      return false;
    }

    locations_[*index] = locations_[--count_];
    return true;
  }

  std::optional<TabLocation> pop() noexcept {
    if (count_ == 0) {
      return std::nullopt;
    }

    return locations_[--count_];
  }

private:
  std::optional<std::size_t> find(TabLocation location) const noexcept {
    for (std::size_t index = 0; index < count_; ++index) {
      const auto &candidate = locations_[index];
      if (candidate.workspace.kind == location.workspace.kind && candidate.workspace.id == location.workspace.id && candidate.tab_id == location.tab_id) {
        return index;
      }
    }

    return std::nullopt;
  }

  std::array<TabLocation, capacity> locations_;
  std::size_t count_ = 0;
};

}
