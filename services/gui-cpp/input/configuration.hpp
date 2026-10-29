#pragma once

#include "action.hpp"
#include "binding.hpp"
#include "default_bindings.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

namespace telar::gui {

struct InputConfiguration {
  using Binding = KeyBinding<BindingAction>;

  KeyChord prefix{.key = KeyChord::Key::character, .character = 'b', .modifiers = static_cast<unsigned>(KeyChord::Modifier::control)};
  std::uint64_t sequence_timeout_ns = BindingLimits::sequence_timeout_ns;
  std::array<Binding, BindingLimits::bindings> configured{};
  std::size_t length = 0;
  std::size_t dropped = 0;

  void setPrefix(KeyChord key) noexcept {
    prefix = key;
    for (auto &binding : std::span{configured}.first(length)) {
      if (binding.prefixed) {
        binding.keys[0] = key;
      }
    }
  }

  [[nodiscard]] BindingMap<BindingAction> compile() const {
    auto resolved = configured;
    auto count = length;
    const auto explicit_bindings = std::span{configured}.first(length);
    for (const auto &original : default_bindings) {
      const Binding binding{.keys = {prefix, original.suffix}, .length = 2, .action = original.action, .prefixed = true};
      const bool overridden = std::ranges::any_of(explicit_bindings, [&](const auto &configured) {
        return configured.conflictsWith(binding);
      });
      if (!overridden && count < resolved.size()) {
        resolved[count++] = binding;
      }
    }

    return BindingMap<BindingAction>{std::span{resolved}.first(count)};
  }
};

}
