#pragma once

#include "config/key_chord.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <stdexcept>
#include <tuple>

namespace telar::gui {

using runtime::config::KeyChord;

struct BindingLimits {
  static constexpr std::size_t bindings = 256;
  static constexpr std::size_t keys = 5;
  static constexpr std::size_t physical_keys = 64;
  static constexpr std::uint64_t sequence_timeout_ns = std::uint64_t{1000} * 1000 * 1000;
};

inline int compareChords(KeyChord left, KeyChord right) noexcept {
  const auto left_value = std::tie(left.key, left.character, left.modifiers);
  const auto right_value = std::tie(right.key, right.character, right.modifiers);

  if (left_value < right_value) {
    return -1;
  }

  return static_cast<int>(left_value > right_value);
}

template <typename Action>
struct KeyBinding {
  std::array<KeyChord, BindingLimits::keys> keys{};
  std::size_t length = 0;
  Action action{};
  bool prefixed = false;

  [[nodiscard]] std::span<const KeyChord> sequence() const noexcept {
    return std::span{keys}.first(length);
  }

  [[nodiscard]] bool conflictsWith(const KeyBinding &other) const noexcept {
    const auto shared = std::min(length, other.length);

    return std::equal(keys.begin(), keys.begin() + shared, other.keys.begin());
  }
};

template <typename Action>
class BindingMap {
public:
  struct Range {
    std::size_t begin = 0;
    std::size_t end = 0;
  };

  explicit BindingMap(std::span<const KeyBinding<Action>> bindings = {}) {
    if (bindings.size() > BindingLimits::bindings) {
      throw std::invalid_argument{"Too many key bindings"};
    }

    for (const auto &binding : bindings) {
      if (binding.length == 0 || binding.length > BindingLimits::keys) {
        throw std::invalid_argument{"A binding must contain one to five keys"};
      }

      bindings_[length_] = binding;
      order_[length_] = static_cast<std::uint16_t>(length_);
      ++length_;
    }

    const auto ordered = std::span{order_}.first(length_);
    std::ranges::sort(ordered, [this](auto left, auto right) {
      return std::lexicographical_compare(bindings_[left].sequence().begin(), bindings_[left].sequence().end(), bindings_[right].sequence().begin(), bindings_[right].sequence().end(), [](KeyChord first, KeyChord second) {
        return compareChords(first, second) < 0;
      });
    });

    for (std::size_t index = 1; index < length_; ++index) {
      if (at(index - 1).conflictsWith(at(index))) {
        throw std::invalid_argument{"Duplicate or ambiguous binding sequence"};
      }
    }
  }

  [[nodiscard]] std::size_t size() const noexcept {
    return length_;
  }

  [[nodiscard]] std::span<const KeyBinding<Action>> configured() const noexcept {
    return std::span{bindings_}.first(length_);
  }

  [[nodiscard]] const KeyBinding<Action> &at(std::size_t index) const noexcept {
    return bindings_[order_[index]];
  }

  [[nodiscard]] Range match(Range candidates, std::size_t depth, KeyChord key) const noexcept {
    const auto first = boundary(candidates, depth, key, false);
    const auto last = boundary({first, candidates.end}, depth, key, true);

    return {first, last};
  }

private:
  [[nodiscard]] std::size_t boundary(Range range, std::size_t depth, KeyChord key, bool inclusive) const noexcept {
    while (range.begin < range.end) {
      const auto middle = range.begin + ((range.end - range.begin) / 2);
      const auto compared = compareChords(at(middle).keys[depth], key);
      if (compared < 0 || (inclusive && compared == 0)) {
        range.begin = middle + 1;
      } else {
        range.end = middle;
      }
    }

    return range.begin;
  }

  std::array<KeyBinding<Action>, BindingLimits::bindings> bindings_{};
  std::array<std::uint16_t, BindingLimits::bindings> order_{};
  std::size_t length_ = 0;
};

}
