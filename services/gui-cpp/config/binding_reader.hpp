#pragma once

#include "config/key_chord_validator.hpp"
#include "input/action.hpp"
#include "input/binding.hpp"
#include "input/configuration.hpp"
#include "lua/value.hpp"
#include <algorithm>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <optional>

namespace telar::gui {

template <typename Reader>
concept BindingActionSource = requires(const Reader &reader, const runtime::lua::Value &value) {
  { reader.read(value, false) } -> std::same_as<std::optional<BindingAction>>;
};

class BindingReader {
public:
  template <BindingActionSource Actions>
  static void apply(const runtime::lua::Value &client, InputConfiguration &input, const Actions &actions) {
    if (!client.present()) {
      return;
    }

    const auto prefix = client.field("prefix");
    if (prefix.present()) {
      input.setPrefix(runtime::config::KeyChordValidator::parse(prefix));
    }

    const auto options = client.field("input");
    if (options.present()) {
      options.onlyFields({"escape_timeout_ms", "sequence_timeout_ms"});
      constexpr std::uint64_t minimum_timeout_ms = 10;
      constexpr std::uint64_t maximum_timeout_ms = 10'000;
      constexpr std::uint64_t nanoseconds_per_millisecond = 1'000'000;
      input.sequence_timeout_ns = options.field("sequence_timeout_ms").boundedInteger(input.sequence_timeout_ns / nanoseconds_per_millisecond, minimum_timeout_ms, maximum_timeout_ms) * nanoseconds_per_millisecond;
    }

    const auto bindings = client.field("keybindings");
    if (!bindings.present()) {
      return;
    }

    const auto count = bindings.listLength();
    input.length = 0;
    input.dropped = count - std::min(count, BindingLimits::bindings);
    for (std::size_t index = 0; index < std::min(count, BindingLimits::bindings); ++index) {
      const auto value = bindings.element(static_cast<lua_Integer>(index) + 1);
      auto binding = read(value, input.prefix);
      const auto action = actions.read(value.field("action"), value.field("expression").boolean(false));
      if (action) {
        binding.action = *action;
        input.configured[input.length++] = binding;
      }
    }
  }

private:
  static KeyBinding<BindingAction> read(const runtime::lua::Value &value, KeyChord prefix) {
    value.onlyFields({"keys", "action", "expression", "prefixed"});
    const auto prefixed = value.field("prefixed");
    if (!prefixed.present()) {
      prefixed.fail("must be a boolean");
    }

    KeyBinding<BindingAction> binding{.prefixed = prefixed.boolean(false)};
    const auto offset = static_cast<std::size_t>(binding.prefixed);
    const auto keys = value.field("keys");
    const auto count = keys.listLength();
    if (count == 0 || count > BindingLimits::keys - offset) {
      keys.fail("has an invalid number of binding keys");
    }

    if (binding.prefixed) {
      binding.keys[0] = prefix;
    }

    binding.length = count + offset;
    for (std::size_t index = 0; index < count; ++index) {
      binding.keys[index + offset] = runtime::config::KeyChordValidator::parse(keys.element(static_cast<lua_Integer>(index) + 1));
    }

    return binding;
  }
};

}
