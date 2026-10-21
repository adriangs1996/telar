#pragma once

#include "keymap.hpp"

namespace keybindings {
  enum class KeyPhase {
    Press,
    Repeat,
    Release
  };

  struct KeyEvent {
    std::string_view chord;
    std::uint32_t physical;
    KeyPhase phase;
  };

  struct Decision {
    bool consumed = false;
    std::uint64_t action = 0;
  };

  // Single-threaded engine. Routing owns no callbacks and performs no allocations.
  class Router final {
  public:
    void configure(std::string_view prefix, std::span<const Binding> bindings);
    Decision route(const KeyEvent &event) noexcept;
    void cancel() noexcept;
    bool pending() const noexcept;

  private:
    static constexpr std::size_t maxPressedKeys = 64;

    Keymap keymap_;
    Keymap::Range candidates_;
    std::size_t depth_ = 0;
    std::array<std::uint32_t, maxPressedKeys> pressed_{};
    std::size_t pressed_count_ = 0;

    bool held(std::uint32_t physical) const noexcept;
    bool acquire(std::uint32_t physical) noexcept;
    bool release(std::uint32_t physical) noexcept;
  };
} // namespace keybindings
