module telar.gui.features.plugins;

import std;

import telar.plugins;
import telar.tbc;
import telar.wire.vocabulary;
import telar.gui.foundation.actions;
import telar.gui.foundation.core;
import telar.base.ds;

namespace telar::gui::features::plugins {

  PluginEffects PluginEffects::decode(std::span<const Byte> input) {
    if (input.size() > maximum_bytes) {
      throw std::length_error{"Plugin worker result exceeds its limit"};
    }

    PluginEffects result;
    const auto count = u8::decode(input);
    if (count > result.effects_.size()) {
      throw std::invalid_argument{"TooManyWorkerEffects"};
    }

    for (std::size_t index = 0; index < count; ++index) {
      result.effects_.atMut(index) = decodeEffect(input);
    }

    if (!input.empty()) {
      throw std::invalid_argument{"TrailingWorkerResult"};
    }

    result.count_ = count;

    return result;
  }

  std::span<const PluginEffects::Effect> PluginEffects::effects() const noexcept {
    return std::span{effects_}.first(count_);
  }

  void PluginEffects::authorize(const runtime::plugins::Package& package, const runtime::plugins::TrustStore& trust) const {
    const auto grants = trust.granted(package.manifest.id.view(), package.digest);

    for (const auto& effect : effects()) {
      const auto* action = std::get_if<BindingAction>(&effect);
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

  BindingAction PluginEffects::indexed(std::span<const BindingActionKind> kinds, std::span<const Byte>& input) {
    const auto index = u8::decode(input);
    if (index >= kinds.size()) {
      throw std::invalid_argument{"InvalidWorkerEffect"};
    }

    return {.kind = kinds[index]};
  }

  NotificationActionDescription PluginEffects::notification(std::span<const Byte>& input) {
    NotificationActionDescription value;

    value.level = EnumByte<NotificationLevel, static_cast<Byte>(NotificationLevel::failure)>::decode(input);
    value.duration_ms = BoundedInteger<u32, min_notification_duration_ms, max_notification_duration_ms>::decode(input);
    DecodeStorage storage{};

    value.target = ValueCodec<NotificationTarget>::decode(input, storage);
    value.title.assign(DisplayText16<max_notification_title_bytes, false>::decode(input));
    value.message.assign(DisplayText16<max_notification_message_bytes>::decode(input));

    return value;
  }

  PluginEffects::Effect PluginEffects::decodeEffect(std::span<const Byte>& input) {
    using Kind = BindingActionKind;
    using SimpleEffect = std::pair<Tag, Kind>;
    constexpr auto simple = ds::Array<SimpleEffect, 11>{
        SimpleEffect{Tag::sidebar, Kind::toggle_sidebar},
        SimpleEffect{Tag::close_pane, Kind::close_pane},
        SimpleEffect{Tag::new_tab, Kind::new_tab},
        SimpleEffect{Tag::rename_tab, Kind::rename_tab},
        SimpleEffect{Tag::close_tab, Kind::close_tab},
        SimpleEffect{Tag::detach, Kind::detach},
        SimpleEffect{Tag::fullscreen, Kind::toggle_pane_fullscreen},
        SimpleEffect{Tag::workspace_list, Kind::toggle_workspace_list},
        SimpleEffect{Tag::new_workspace, Kind::new_workspace},
        SimpleEffect{Tag::rename_workspace, Kind::rename_workspace},
        SimpleEffect{Tag::leave_worktree, Kind::leave_worktree},
    };

    const auto tag = static_cast<Tag>(u8::decode(input));
    const auto* found = std::ranges::find(simple, tag, &decltype(simple)::value_type::first);
    if (found != simple.end()) {
      return BindingAction{.kind = found->second};
    }

    constexpr ds::Array split{Kind::split_horizontal, Kind::split_vertical};
    constexpr ds::Array focus{Kind::focus_left, Kind::focus_right, Kind::focus_up, Kind::focus_down};
    constexpr ds::Array resize{Kind::resize_left, Kind::resize_right, Kind::resize_up, Kind::resize_down};
    constexpr ds::Array move{Kind::move_tab_previous, Kind::move_tab_next};
    constexpr ds::Array sidebar{Kind::resize_sidebar_left, Kind::resize_sidebar_right};

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
    case Tag::sidebar:
    case Tag::close_pane:
    case Tag::new_tab:
    case Tag::rename_tab:
    case Tag::close_tab:
    case Tag::detach:
    case Tag::fullscreen:
    case Tag::workspace_list:
    case Tag::new_workspace:
    case Tag::rename_workspace:
    case Tag::leave_worktree:
      break;
    }

    // A tag outside the enum, as a malformed effect decodes to; the simple tags returned above.
    throw std::invalid_argument{"UnknownWorkerEffect"};
  }

  ds::Option<runtime::plugins::Capability> PluginEffects::capability(BindingActionKind kind) {
    using Kind = BindingActionKind;

    switch (kind) {
    case Kind::split_horizontal:
    case Kind::split_vertical:
    case Kind::close_pane:
    case Kind::new_workspace:
    case Kind::rename_workspace:
    case Kind::new_tab:
    case Kind::new_editor:
    case Kind::new_editor_tab:
    case Kind::editor_files:
    case Kind::editor_grep:
    case Kind::editor_buffers:
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
      return ds::none;
    case Kind::none:
    case Kind::scroll_pane_up:
    case Kind::scroll_pane_down:
    case Kind::navigate_left:
    case Kind::navigate_right:
    case Kind::navigate_up:
    case Kind::navigate_down:
    case Kind::forget_gone_worktrees:
    case Kind::next_tab:
    case Kind::previous_tab:
    case Kind::copy_mode:
    case Kind::goto_picker:
    case Kind::history_palette:
    case Kind::path_picker:
    case Kind::suggest_command:
    case Kind::close_panel:
    case Kind::refresh_panel:
    case Kind::next_machine:
    case Kind::previous_machine:
    case Kind::machine_picker:
    case Kind::add_machine:
    case Kind::monitor:
    case Kind::process_picker:
    case Kind::process_terminate:
    case Kind::process_kill:
    case Kind::process_stop:
    case Kind::process_continue:
    case Kind::process_lower_priority:
    case Kind::process_copy_command:
    case Kind::process_focus_pane:
    case Kind::process_review_stack:
    case Kind::process_review_files:
    case Kind::process_review_logs:
    case Kind::palette:
    case Kind::callback:
    case Kind::expression:
    case Kind::extended:
    case Kind::command_tab:
      break;
    }

    // An action no plugin may take, or a kind outside the enum.
    throw std::invalid_argument{"InvalidPluginEffect"};
  }

}
