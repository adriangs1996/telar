#pragma once

#include "chord.hpp"
#include <array>
#include <cstddef>
#include <span>
#include <string>
#include <vector>

namespace keybindings {
  inline constexpr std::size_t maxBindings = 256;
  inline constexpr std::size_t maxSequenceLength = 5;

  struct Binding {
    std::uint64_t action;
    std::span<const std::string> keys;
  };

  class Keymap final {
  public:
    struct Range {
      std::size_t begin = 0;
      std::size_t end = 0;

      bool empty() const noexcept;
    };

    Keymap() = default;
    Keymap(std::string_view prefix, std::span<const Binding> bindings);

    Range all() const noexcept;
    Range match(Range candidates, std::size_t depth, Chord key) const noexcept;
    std::uint64_t action(Range candidates, std::size_t depth) const noexcept;

  private:
    struct Entry {
      std::array<Chord, maxSequenceLength> keys{};
      std::size_t length = 0;
      std::uint64_t action = 0;

      std::span<const Chord> sequence() const noexcept;
    };

    std::vector<Entry> entries_;
  };
} // namespace keybindings
