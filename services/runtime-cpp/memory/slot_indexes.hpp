#pragma once

#include <array>
#include <bit>
#include <cstdint>
#include <optional>

namespace telar::runtime {

template <std::size_t Capacity>
class SlotIndexes {
  static_assert(Capacity > 0);

public:
  void insert(std::size_t index) noexcept {
    words_[index / word_bits] |= std::uint64_t{1} << (index % word_bits);
  }

  void erase(std::size_t index) noexcept {
    words_[index / word_bits] &= ~(std::uint64_t{1} << (index % word_bits));
  }

  std::optional<std::size_t> firstUnused() const noexcept {
    for (std::size_t word = 0; word < words_.size(); ++word) {
      if (const auto available = ~words_[word]; available != 0) {
        const auto index = word * word_bits + std::countr_zero(available);
        return index < Capacity ? std::optional{index} : std::nullopt;
      }
    }
    return std::nullopt;
  }

  template <typename Visitor>
  void forEach(Visitor &&visit) const {
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
