module telar.gui.foundation.actions;

import std;

import telar.base.text;
import telar.base.ds;

namespace telar::gui::inline foundation::inline actions {

  ds::Option<BindingAction> builtinBindingAction(std::string_view name) noexcept {
    for (const auto& [known, kind] : builtin_binding_actions) {
      if (name == known) {
        return BindingAction{.kind = kind};
      }
    }

    for (const auto& [prefix, kind] : {std::pair{std::string_view{"select-tab-"}, BindingActionKind::select_tab}, std::pair{std::string_view{"select-workspace-"}, BindingActionKind::select_workspace}}) {
      if (!name.starts_with(prefix)) {
        continue;
      }

      auto digits = name;

      digits.remove_prefix(prefix.size());
      constexpr unsigned maximum_index = 255;
      const auto index = runtime::unsignedNumber<unsigned>(digits, maximum_index).value_or(0);

      return index == 0 ? ds::none : ds::Option{BindingAction{.kind = kind, .parameter = static_cast<std::int32_t>(index) - 1}};
    }

    return {};
  }

}
