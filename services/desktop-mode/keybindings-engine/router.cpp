#include "router.hpp"
#include <algorithm>
#include <utility>

namespace keybindings {
  void Router::configure(std::string_view prefix, std::span<const Binding> bindings) {
    Keymap replacement(prefix, bindings);
    keymap_ = std::move(replacement);
    cancel();
  }

  Decision Router::route(const KeyEvent &event) noexcept {
    switch (event.phase) {
    case KeyPhase::Repeat:
      return {.consumed = held(event.physical)};
    case KeyPhase::Release:
      return {.consumed = release(event.physical)};
    case KeyPhase::Press:
      break;
    default:
      return {};
    }

    // Unsupported native keys cancel a pending sequence just like Escape.
    const Chord key = parseChord(event.chord).value_or(Chord{});
    const auto matched = keymap_.match(pending() ? candidates_ : keymap_.all(), depth_, key);

    if (!pending() && matched.empty()) {
      release(event.physical);
      return {};
    }

    if (!acquire(event.physical)) {
      // Never swallow a press whose later release we cannot track.
      cancel();
      return {};
    }

    if (matched.empty() || (pending() && key == Chord{})) {
      cancel();
      return {.consumed = true};
    }

    const auto action = keymap_.action(matched, depth_ + 1);

    if (action != 0) {
      cancel();
      return {.consumed = true, .action = action};
    }

    candidates_ = matched;
    ++depth_;
    return {.consumed = true};
  }

  void Router::cancel() noexcept {
    // A reload or focus change cancels the sequence, but intercepted keys still
    // own their repeats and releases until the user lets go.
    candidates_ = keymap_.all();
    depth_ = 0;
  }

  bool Router::pending() const noexcept {
    return depth_ != 0;
  }

  bool Router::held(std::uint32_t physical) const noexcept {
    const auto pressed = std::span(pressed_).first(pressed_count_);
    return std::ranges::find(pressed, physical) != pressed.end();
  }

  bool Router::acquire(std::uint32_t physical) noexcept {
    if (held(physical)) {
      return true;
    }

    if (pressed_count_ == pressed_.size()) {
      return false;
    }

    pressed_[pressed_count_++] = physical;
    return true;
  }

  bool Router::release(std::uint32_t physical) noexcept {
    const auto pressed = std::span(pressed_).first(pressed_count_);
    const auto found = std::ranges::find(pressed, physical);

    if (found == pressed.end()) {
      return false;
    }

    *found = pressed_[--pressed_count_];
    return true;
  }
} // namespace keybindings
