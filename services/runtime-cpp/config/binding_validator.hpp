#pragma once

#include "action_validator.hpp"
#include "binding_keymap.hpp"
#include "key_chord_validator.hpp"

namespace telar::runtime::config {

class BindingValidator {
public:
  static void validate(const lua::Value &bindings, const ActionValidator &actions, BindingKeymap &keymap, LimitNotices &limits) {
    if (!bindings.present()) {
      return;
    }

    constexpr auto maximum_bindings = BindingKeymap::maximum_bindings;
    keymap.clear();
    const auto listed = bindings.listLength();
    const auto count = std::min(listed, maximum_bindings);
    if (listed > maximum_bindings) {
      limits.add({"config.max_bindings", "key bindings", maximum_bindings, listed, {}});
    }
    for (std::size_t index = 1; index <= count; ++index) {
      const auto binding = bindings.element(index);
      binding.onlyFields({"keys", "action", "expression", "prefixed"});
      const auto prefix = binding.field("prefixed");
      if (!prefix.present()) {
        prefix.fail("must be a boolean");
      }

      const bool prefixed = prefix.boolean(false);
      const auto keys = binding.field("keys");
      const auto key_count = keys.listLength();
      constexpr std::size_t maximum_keys = 5;
      if (key_count == 0 || key_count > maximum_keys - prefixed) {
        keys.fail("has an invalid number of keys");
      }
      BindingKeymap::Sequence sequence{.length = key_count + prefixed, .prefixed = prefixed};
      if (prefixed) {
        sequence.keys[0] = keymap.prefix();
      }
      for (std::size_t key = 1; key <= key_count; ++key) {
        const auto parsed = KeyChordValidator::parse(keys.element(key));
        const auto position = key - 1 + prefixed;
        if (position < sequence.keys.size()) {
          sequence.keys[position] = parsed;
        }
      }

      if (actions.validate(binding.field("action"), binding.field("expression").boolean(false))) {
        keymap.append(sequence);
      }
    }
  }
};

}
