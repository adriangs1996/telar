#pragma once

#include "input/action.hpp"
#include "input/binding.hpp"
#include <array>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>
#include <utility>

namespace telar::gui {

enum class StatusMode : std::uint8_t {
  normal,
  prefix,
  copy,
};

struct ModeHint {
  KeyChord key;
  std::string_view label;
};

template <typename Router>
concept PrefixHintRouter = requires(const Router &router, const BindingAction &action) {
  { router.prefixedKeyForAction(action) } -> std::same_as<std::optional<KeyChord>>;
};

class ModeHints {
public:
  static constexpr auto actions = std::to_array<std::pair<BindingActionKind, std::string_view>>({
      {BindingActionKind::split_horizontal, "split right"},
      {BindingActionKind::split_vertical, "split down"},
      {BindingActionKind::new_tab, "new tab"},
      {BindingActionKind::new_workspace, "new workspace"},
      {BindingActionKind::rename_tab, "rename tab"},
      {BindingActionKind::rename_workspace, "rename workspace"},
      {BindingActionKind::close_pane, "close pane"},
      {BindingActionKind::copy_mode, "copy mode"},
  });
  static constexpr std::size_t capacity = actions.size();

  template <PrefixHintRouter Router>
  [[nodiscard]] static ModeHints resolve(const Router &router) noexcept {
    ModeHints result;
    for (const auto &[action, label] : actions) {
      if (const auto key = router.prefixedKeyForAction({.kind = action})) {
        result.append({.key = *key, .label = label});
      }
    }

    return result;
  }

  void append(ModeHint hint) noexcept {
    if (count_ < hints_.size()) {
      hints_[count_++] = hint;
    }
  }

  [[nodiscard]] std::span<const ModeHint> items() const noexcept {
    return std::span{hints_}.first(count_);
  }

private:
  std::array<ModeHint, capacity> hints_{};
  std::size_t count_ = 0;
};

}
