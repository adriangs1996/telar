module telar.gui.foundation.keys;

import std;

import telar.gui.foundation.actions;

namespace telar::gui::inline foundation::inline keys {

  void InputConfiguration::setPrefix(KeyChord key) noexcept {
    prefix = key;
    for (auto& binding : configured.viewMut().first(length)) {
      if (binding.prefixed) {
        binding.keys.atMut(0) = key;
      }
    }
  }

  BindingMap<BindingAction> InputConfiguration::compile() const {
    auto resolved = configured;
    auto count = length;
    const auto explicit_bindings = std::span{configured}.first(length);

    for (const auto& original : default_bindings) {
      const Binding binding{.keys = {prefix, original.suffix}, .length = 2, .action = original.action, .prefixed = true};
      const bool overridden = std::ranges::any_of(explicit_bindings, [&](const auto& existing) {
        return existing.conflictsWith(binding);
      });
      if (!overridden && count < resolved.size()) {
        resolved.atMut(count++) = binding;
      }
    }

    return BindingMap<BindingAction>{std::span{resolved}.first(count)};
  }

}
