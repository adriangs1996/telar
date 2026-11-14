module telar.gui.input.copy_pointer;

import std;
import telar.base.text;

namespace telar::gui {

  std::optional<BindingAction> builtinBindingAction(std::string_view name) noexcept {
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

      return index == 0 ? std::nullopt : std::optional{BindingAction{.kind = kind, .parameter = static_cast<std::int32_t>(index) - 1}};
    }

    return {};
  }

  CopyGranularity ClickTracker::press(CopyPoint position, std::uint64_t now_ns) noexcept {
    const auto distance = std::max(position.x, last_.x) - std::min(position.x, last_.x);
    const auto nearby = position.y == last_.y && distance <= 1;
    const auto elapsed = now_ns - std::min(now_ns, last_ns_);
    const auto repeated = count_ != 0 && elapsed <= interval_ns;

    count_ = nearby && repeated ? std::min(count_ + 1, maximum_clicks) : 1;
    last_ = position;
    last_ns_ = now_ns;

    return static_cast<CopyGranularity>(count_ - 1);
  }

  CopyPointerDecision routeCopyPointer(const CopyPointerInput& input, const CopyPointerAuthority& authority) noexcept {
    using Kind = CopyPointerAuthority::Kind;
    using Outcome = CopyPointerDecision::Outcome;

    switch (authority.kind) {
    case Kind::unowned:
      return {};
    case Kind::missing:
      return {.outcome = Outcome::exited, .leave = true};
    case Kind::selection:
      if (authority.dragging && input.kind == CopyPointerKind::press && input.left_button) {
        return {.cancel = true};
      }

      if (!authority.dragging) {
        return {.cancel = input.kind == CopyPointerKind::press || input.kind == CopyPointerKind::wheel};
      }

      if (!input.left_button || (input.kind != CopyPointerKind::drag && input.kind != CopyPointerKind::release)) {
        return {.outcome = Outcome::consumed};
      }

      if (!authority.position) {
        return {.outcome = Outcome::consumed, .cancel = input.kind == CopyPointerKind::release};
      }

      return {.outcome = Outcome::moved, .motion = authority.position};
    case Kind::keyboard:
      if (input.kind == CopyPointerKind::wheel && authority.inside) {
        return {.outcome = Outcome::moved, .vertical = input.rows};
      }

      return {.outcome = Outcome::consumed};
    }

    return {};
  }

}
