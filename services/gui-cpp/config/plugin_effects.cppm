module;
#include <cstdlib>
#include <new>
#include <unistd.h>

#include <cstdint>
#include <cstddef>

#include <lua.h>

#include <limits.h>
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>

#include <cmath>
#include <cstring>
#include <arpa/inet.h>
#include <cinttypes>
#include <cstdio>

export module telar.gui.config.plugin_effects;

import std;

export import telar.gui.input.copy_pointer;
export import telar.gui.input.key_encoder;
export import telar.config;


export import telar.gui.config.plugin_query;

export import telar.plugins;


export import telar.gui.core.json_writer;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.platform.primitives;

// Interface: config/callback.cppm
export {
namespace telar::gui {

using BindingContext = runtime::config::BindingContext;

struct BindingEffects {
  static constexpr std::size_t maximum_effects = 16;
  std::array<BindingAction, maximum_effects> actions{};
  std::size_t length = 0;
  std::size_t dropped = 0;
};

struct InputExpression {
  enum class Kind : std::uint8_t {
    consume,
    forward,
    keys,
    paste,
  };

  static constexpr std::size_t maximum_keys = 16;
  static constexpr std::size_t maximum_paste_bytes = 4096;
  Kind kind = Kind::consume;
  std::array<KeyChord, maximum_keys> keys{};
  std::size_t length = 0;
  runtime::FixedText<maximum_paste_bytes> paste;
};

}
}

// Interface: config/callback_invocation.cppm
export {
namespace telar::gui {

using CallbackInvocation = runtime::config::CallbackInvocation;

}
}

// Interface: config/plugin_effects.cppm
export {
namespace telar::gui {

class PluginEffects {
public:
  static_assert(BindingEffects::maximum_effects == runtime::plugins::ActionProtocol::maximum_effects);
  using Effect = std::variant<BindingAction, NotificationActionDescription>;
  static constexpr std::size_t maximum_bytes = runtime::plugins::ActionProtocol::maximum_bytes;

  [[nodiscard]] inline static PluginEffects decode(std::span<const Byte> input) {
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

  [[nodiscard]] inline std::span<const Effect> effects() const noexcept {
    return std::span{effects_}.first(count_);
  }

  // A caller must finish this whole-batch check before applying the first effect.
  inline void authorize(const runtime::plugins::Package &package, const runtime::plugins::TrustStore &trust) const {
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
  using Tag = runtime::plugins::ActionTag;

  inline static BindingAction indexed(std::span<const BindingActionKind> kinds, std::span<const Byte> &input) {
    const auto index = u8::decode(input);
    if (index >= kinds.size()) {
      throw std::invalid_argument{"InvalidWorkerEffect"};
    }

    return {.kind = kinds[index]};
  }

  inline static NotificationActionDescription notification(std::span<const Byte> &input) {
    NotificationActionDescription value;
    value.level = EnumByte<NotificationLevel, static_cast<Byte>(NotificationLevel::failure)>::decode(input);
    value.duration_ms = BoundedInteger<u32, min_notification_duration_ms, max_notification_duration_ms>::decode(input);
    DecodeStorage storage{};
    value.target = ValueCodec<NotificationTarget>::decode(input, storage);
    value.title.assign(DisplayText16<max_notification_title_bytes, false>::decode(input));
    value.message.assign(DisplayText16<max_notification_message_bytes>::decode(input));

    return value;
  }

  inline static Effect decodeEffect(std::span<const Byte> &input) {
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

  inline static std::optional<runtime::plugins::Capability> capability(BindingActionKind kind) {
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
}

// Interface: config/plugin_invocation.cppm
export {
namespace telar::gui {

struct PluginInvocation {
  runtime::plugins::Package package;
  runtime::FixedText<runtime::plugins::PackageLimits::action_bytes> action;
  BindingContext context;
  std::uint64_t configuration_generation = 0;
  std::size_t package_index = 0;
};

}
}

// Interface: config/runtime_query.cppm
export {
namespace telar::gui {

class RuntimeQuery {
public:
  template <Allocator Memory>
  [[nodiscard]] inline static std::string_view write(const runtime::config::RuntimeValues<Memory> &values, std::span<char> output) {
    JsonWriter writer{output};
    writer.object([&](JsonWriter &object) {
      object.member("graphics_pane_bytes", values.graphics.pane_bytes);
      object.member("graphics_global_bytes", values.graphics.global_bytes);
      object.member("history_path", nullablePath(values.history_path));
      object.member("history_output_capture", values.capture_output);
      object.member("session_path", nullablePath(values.session_path));
      object.member("session_persist", values.persist_session);
      object.member("session_resume_agents", values.resume_agents);
      writeProxy(object, values.proxy);
      object.member("engine_idle_timeout_ms", values.engine.idle_timeout.count());
      object.member("agent_manifest_count", values.manifests.entries().size());
    });

    return writer.view();
  }

private:
  inline static std::optional<std::string_view> nullablePath(std::string_view path) noexcept {
    return path.empty() ? std::nullopt : std::optional{path};
  }

  template <Allocator Memory>
  inline static void writeProxy(JsonWriter &writer, const runtime::ProxyOptions<Memory> &proxy) {
    writer.member("proxy_enabled", proxy.enabled);
    writer.member("proxy_anonymous_tunnels", proxy.anonymous_tunnels);
    writer.member("proxy_ca_dir", nullablePath(proxy.authority_directory));
    writer.member("proxy_intercept_hosts", [&](JsonWriter &value) {
      value.array([&](JsonWriter &array) {
        for (const auto &host : proxy.intercept_hosts.patterns()) {
          array.element(std::string_view{host});
        }
      });
    });
    writer.member("proxy_capture_enabled", proxy.capture.enabled);
    writer.member("proxy_capture_max_part_bytes", proxy.capture.part_bytes);
    writer.member("proxy_capture_max_exchange_bytes", proxy.capture.exchange_bytes);
    writer.member("proxy_capture_max_total_bytes", proxy.capture.total_bytes);
    writer.member("proxy_capture_join_timeout_ms", proxy.capture.join_timeout.count());
  }
};

}
}
