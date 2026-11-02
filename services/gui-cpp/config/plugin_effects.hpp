#pragma once

#include "action_descriptions.hpp"
#include "callback.hpp"
#include "input/action.hpp"
#include "plugins/capabilities.hpp"
#include "plugins/package.hpp"
#include "plugins/trust_store.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <stdexcept>
#include <utility>
#include <variant>

namespace telar::gui {

class PluginEffects {
public:
  using Effect = std::variant<BindingAction, NotificationActionDescription>;
  static constexpr std::size_t maximum_bytes = sizeof(Byte) + (BindingEffects::maximum_effects * (sizeof(Byte) + sizeof(NotificationLevel) + sizeof(std::uint32_t) + sizeof(NotificationTarget::Kind) + sizeof(std::uint64_t) + (sizeof(std::uint16_t) * 2) + max_notification_title_bytes + max_notification_message_bytes));

  [[nodiscard]] static PluginEffects decode(std::span<const Byte> input) {
    if (input.size() > maximum_bytes) {
      throw std::length_error{"Plugin worker result exceeds its limit"};
    }

    PluginEffects result;
    const auto count = u8::decode(input);
    if (count > result.effects_.size()) {
      throw std::invalid_argument{"TooManyWorkerEffects"};
    }

    for (std::size_t index = 0; index < count; ++index) {
      result.effects_[index] = decodeEffect(input);
    }

    if (!input.empty()) {
      throw std::invalid_argument{"TrailingWorkerResult"};
    }

    result.count_ = count;

    return result;
  }

  [[nodiscard]] std::span<const Effect> effects() const noexcept {
    return std::span{effects_}.first(count_);
  }

  // A caller must finish this whole-batch check before applying the first effect.
  void authorize(const runtime::plugins::Package &package, const runtime::plugins::TrustStore &trust) const {
    const auto grants = trust.granted(package.manifest.id.view(), package.digest);
    for (const auto &effect : effects()) {
      const auto *action = std::get_if<BindingAction>(&effect);
      const auto required = action == nullptr ? runtime::plugins::Capability::notifications : capability(action->kind);
      if (!required) {
        continue;
      }

      if (!package.manifest.capabilities.contains(*required)) {
        throw std::invalid_argument{"CapabilityNotDeclared"};
      }

      if (!grants.contains(*required)) {
        throw std::invalid_argument{"CapabilityNotGranted"};
      }
    }
  }

private:
  enum class Tag : Byte {
    split = 1,
    focus = 2,
    sidebar = 3,
    close_pane = 4,
    new_tab = 5,
    tab_offset = 6,
    select_tab = 7,
    rename_tab = 8,
    close_tab = 9,
    move_tab = 10,
    detach = 11,
    resize = 12,
    fullscreen = 13,
    workspace_list = 14,
    new_workspace = 15,
    rename_workspace = 16,
    select_workspace = 17,
    notification = 18,
    resize_sidebar = 19,
    leave_worktree = 20,
  };

  static BindingAction indexed(std::span<const BindingActionKind> kinds, std::span<const Byte> &input) {
    const auto index = u8::decode(input);
    if (index >= kinds.size()) {
      throw std::invalid_argument{"InvalidWorkerEffect"};
    }

    return {.kind = kinds[index]};
  }

  static NotificationActionDescription notification(std::span<const Byte> &input) {
    NotificationActionDescription value;
    value.level = EnumByte<NotificationLevel, static_cast<Byte>(NotificationLevel::failure)>::decode(input);
    value.duration_ms = BoundedInteger<u32, min_notification_duration_ms, max_notification_duration_ms>::decode(input);
    DecodeStorage storage{};
    value.target = ValueCodec<NotificationTarget>::decode(input, storage);
    value.title.assign(DisplayText16<max_notification_title_bytes, false>::decode(input));
    value.message.assign(DisplayText16<max_notification_message_bytes>::decode(input));

    return value;
  }

  static Effect decodeEffect(std::span<const Byte> &input) {
    using Kind = BindingActionKind;
    constexpr auto simple = std::to_array<std::pair<Tag, Kind>>({
        {Tag::sidebar, Kind::toggle_sidebar},
        {Tag::close_pane, Kind::close_pane},
        {Tag::new_tab, Kind::new_tab},
        {Tag::rename_tab, Kind::rename_tab},
        {Tag::close_tab, Kind::close_tab},
        {Tag::detach, Kind::detach},
        {Tag::fullscreen, Kind::toggle_pane_fullscreen},
        {Tag::workspace_list, Kind::toggle_workspace_list},
        {Tag::new_workspace, Kind::new_workspace},
        {Tag::rename_workspace, Kind::rename_workspace},
        {Tag::leave_worktree, Kind::leave_worktree},
    });
    const auto tag = static_cast<Tag>(u8::decode(input));
    const auto *found = std::ranges::find(simple, tag, &decltype(simple)::value_type::first);
    if (found != simple.end()) {
      return BindingAction{.kind = found->second};
    }

    constexpr std::array split{Kind::split_horizontal, Kind::split_vertical};
    constexpr std::array focus{Kind::focus_left, Kind::focus_right, Kind::focus_up, Kind::focus_down};
    constexpr std::array resize{Kind::resize_left, Kind::resize_right, Kind::resize_up, Kind::resize_down};
    constexpr std::array move{Kind::move_tab_previous, Kind::move_tab_next};
    constexpr std::array sidebar{Kind::resize_sidebar_left, Kind::resize_sidebar_right};
    switch (tag) {
    case Tag::split:
      return indexed(split, input);
    case Tag::focus:
      return indexed(focus, input);
    case Tag::resize:
      return indexed(resize, input);
    case Tag::move_tab:
      return indexed(move, input);
    case Tag::resize_sidebar:
      return indexed(sidebar, input);
    case Tag::tab_offset:
      return BindingAction{.kind = Kind::select_tab_offset, .parameter = std::bit_cast<std::int8_t>(u8::decode(input))};
    case Tag::select_tab:
      return BindingAction{.kind = Kind::select_tab, .parameter = u8::decode(input)};
    case Tag::select_workspace:
      return BindingAction{.kind = Kind::select_workspace, .parameter = u8::decode(input)};
    case Tag::notification:
      return notification(input);
    default:
      throw std::invalid_argument{"UnknownWorkerEffect"};
    }
  }

  static std::optional<runtime::plugins::Capability> capability(BindingActionKind kind) {
    using Kind = BindingActionKind;
    switch (kind) {
    case Kind::split_horizontal:
    case Kind::split_vertical:
    case Kind::close_pane:
    case Kind::new_workspace:
    case Kind::rename_workspace:
    case Kind::new_tab:
    case Kind::rename_tab:
    case Kind::close_tab:
    case Kind::move_tab_previous:
    case Kind::move_tab_next:
    case Kind::detach:
      return runtime::plugins::Capability::runtime_control;
    case Kind::focus_left:
    case Kind::focus_right:
    case Kind::focus_up:
    case Kind::focus_down:
    case Kind::resize_left:
    case Kind::resize_right:
    case Kind::resize_up:
    case Kind::resize_down:
    case Kind::toggle_pane_fullscreen:
    case Kind::toggle_sidebar:
    case Kind::resize_sidebar_left:
    case Kind::resize_sidebar_right:
    case Kind::toggle_workspace_list:
    case Kind::select_workspace:
    case Kind::leave_worktree:
    case Kind::select_tab_offset:
    case Kind::select_tab:
      return std::nullopt;
    default:
      throw std::invalid_argument{"InvalidPluginEffect"};
    }
  }

  std::array<Effect, BindingEffects::maximum_effects> effects_{};
  std::size_t count_ = 0;
};

}
