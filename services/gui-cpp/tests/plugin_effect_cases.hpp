#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../core/memory.hpp"
#include <cstdint>
#include <algorithm>
#include <array>
#include <cstddef>
#include <span>
#include <stdexcept>
#include <tuple>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <variant>
#include <optional>
#include <string_view>
#include <utility>
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_base/memory/allocator.hpp"
#include <exception>
#include <charconv>
#include <limits.h>
#include <cerrno>
#include "telar_platform/file_descriptor.hpp"
#include <fcntl.h>
#include <sys/stat.h>
#include <bit>

#pragma once


import telar.gui.config.plugin_effects;
import telar.gui.input.copy_pointer;
import telar.plugins;

namespace telar::gui::test {
namespace plugin_effect_detail {

inline void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

template <typename Operation>
void rejects(const Operation &operation) {
  bool rejected = false;
  try {
    operation();
  } catch (const std::exception &) {
    rejected = true;
  }

  require(rejected, "invalid plugin result or authorization must be rejected");
}

struct Bytes {
  std::array<Byte, PluginEffects::maximum_bytes + 1> data{};
  std::size_t length = 0;

  [[nodiscard]] std::span<const Byte> view() const noexcept {
    return std::span{data}.first(length);
  }
};

inline Bytes bytes(std::string_view hex) {
  constexpr std::string_view digits = "0123456789abcdef";
  Bytes result;
  require(hex.size() % 2 == 0 && hex.size() / 2 <= result.data.size(), "hex fixture must fit its bound");
  result.length = hex.size() / 2;
  for (std::size_t index = 0; index < result.length; ++index) {
    const auto high = digits.find(hex[index * 2]);
    const auto low = digits.find(hex[(index * 2) + 1]);
    require(high != std::string_view::npos && low != std::string_view::npos, "hex fixture must be valid");
    result.data[index] = static_cast<Byte>((high * digits.size()) + low);
  }

  return result;
}

inline void decoding() {
  struct Case {
    std::string_view original_hex;
    BindingActionKind kind;
    int parameter;
  };

  constexpr auto cases = std::to_array<Case>({
      {.original_hex = "0103", .kind = BindingActionKind::toggle_sidebar, .parameter = 0},
      {.original_hex = "010d", .kind = BindingActionKind::toggle_pane_fullscreen, .parameter = 0},
      {.original_hex = "010e", .kind = BindingActionKind::toggle_workspace_list, .parameter = 0},
      {.original_hex = "0105", .kind = BindingActionKind::new_tab, .parameter = 0},
      {.original_hex = "0108", .kind = BindingActionKind::rename_tab, .parameter = 0},
      {.original_hex = "0109", .kind = BindingActionKind::close_tab, .parameter = 0},
      {.original_hex = "0104", .kind = BindingActionKind::close_pane, .parameter = 0},
      {.original_hex = "010b", .kind = BindingActionKind::detach, .parameter = 0},
      {.original_hex = "010f", .kind = BindingActionKind::new_workspace, .parameter = 0},
      {.original_hex = "0110", .kind = BindingActionKind::rename_workspace, .parameter = 0},
      {.original_hex = "0114", .kind = BindingActionKind::leave_worktree, .parameter = 0},
      {.original_hex = "010100", .kind = BindingActionKind::split_horizontal, .parameter = 0},
      {.original_hex = "010101", .kind = BindingActionKind::split_vertical, .parameter = 0},
      {.original_hex = "010200", .kind = BindingActionKind::focus_left, .parameter = 0},
      {.original_hex = "010201", .kind = BindingActionKind::focus_right, .parameter = 0},
      {.original_hex = "010202", .kind = BindingActionKind::focus_up, .parameter = 0},
      {.original_hex = "010203", .kind = BindingActionKind::focus_down, .parameter = 0},
      {.original_hex = "010c00", .kind = BindingActionKind::resize_left, .parameter = 0},
      {.original_hex = "010c01", .kind = BindingActionKind::resize_right, .parameter = 0},
      {.original_hex = "010c02", .kind = BindingActionKind::resize_up, .parameter = 0},
      {.original_hex = "010c03", .kind = BindingActionKind::resize_down, .parameter = 0},
      {.original_hex = "011300", .kind = BindingActionKind::resize_sidebar_left, .parameter = 0},
      {.original_hex = "011301", .kind = BindingActionKind::resize_sidebar_right, .parameter = 0},
      {.original_hex = "010a00", .kind = BindingActionKind::move_tab_previous, .parameter = 0},
      {.original_hex = "010a01", .kind = BindingActionKind::move_tab_next, .parameter = 0},
      {.original_hex = "010701", .kind = BindingActionKind::select_tab, .parameter = 1},
      {.original_hex = "011101", .kind = BindingActionKind::select_workspace, .parameter = 1},
      {.original_hex = "010601", .kind = BindingActionKind::select_tab_offset, .parameter = 1},
      {.original_hex = "0106ff", .kind = BindingActionKind::select_tab_offset, .parameter = -1},
  });
  for (const auto &entry : cases) {
    const auto input = bytes(entry.original_hex);
    const auto decoded = PluginEffects::decode(input.view());
    require(decoded.effects().size() == 1, "original worker must decode one effect");
    const auto *action = std::get_if<BindingAction>(&decoded.effects().front());
    require(action != nullptr && action->kind == entry.kind && action->parameter == entry.parameter, "original worker semantics must match");
    for (std::size_t length = 0; length < input.length; ++length) {
      rejects([&] {
        static_cast<void>(PluginEffects::decode(input.view().first(length)));
      });
    }
  }

  require(PluginEffects::decode(bytes("00").view()).effects().empty(), "zero-effect protocol batch is valid");
  const auto limit = PluginEffects::decode(bytes("1003030303030303030303030303030303").view());
  require(limit.effects().size() == BindingEffects::maximum_effects, "original worker clamps at sixteen effects");
  require(std::ranges::all_of(limit.effects(), [](const auto &effect) {
            return std::get<BindingAction>(effect).kind == BindingActionKind::toggle_sidebar;
          }),
          "all clamped effects must retain their identity");
  for (const auto *const invalid : {"11", "0100", "0115", "01ff", "010102", "010204", "010c04", "010a02", "011302", "0000", "010300"}) {
    rejects([&] {
      static_cast<void>(PluginEffects::decode(bytes(invalid).view()));
    });
  }

  const Bytes oversized;
  rejects([&] {
    static_cast<void>(PluginEffects::decode(oversized.data));
  });
}

inline void authorization() {
  namespace plugins = runtime::plugins;
  plugins::Package package;
  package.manifest.id.assign("fixture");
  plugins::TrustStore trust;
  const auto harmless = PluginEffects::decode(bytes("0103").view());
  harmless.authorize(package, trust);
  const auto mixed = PluginEffects::decode(bytes("020305").view());
  rejects([&] {
    mixed.authorize(package, trust);
  });
  package.manifest.capabilities.insert(plugins::Capability::runtime_control);
  rejects([&] {
    mixed.authorize(package, trust);
  });
  trust.upsert(package.manifest, package.digest, package.manifest.capabilities);
  mixed.authorize(package, trust);
  auto changed = package;
  changed.digest.front() ^= 1U;
  rejects([&] {
    mixed.authorize(changed, trust);
  });

  const auto notification = PluginEffects::decode(bytes("011200a00f0000000d00747275653a333a323a323a34320000").view());
  const auto *value = std::get_if<NotificationActionDescription>(&notification.effects().front());
  require(value != nullptr && value->title.view() == "true:3:2:2:42" && value->message.view().empty() && value->duration_ms == default_notification_duration_ms && value->target.kind == NotificationTarget::Kind::none, "original immutable callback context must retain its notification payload");
  rejects([&] {
    notification.authorize(package, trust);
  });
  package.manifest.capabilities.insert(plugins::Capability::notifications);
  rejects([&] {
    notification.authorize(package, trust);
  });
  trust.upsert(package.manifest, package.digest, package.manifest.capabilities);
  notification.authorize(package, trust);
  const auto original = bytes("011200a00f0000000d00747275653a333a323a323a34320000");
  for (std::size_t length = 0; length < original.length; ++length) {
    rejects([&] {
      static_cast<void>(PluginEffects::decode(original.view().first(length)));
    });
  }
}

}

inline void pluginEffectCases() {
  constexpr std::size_t original_worker_limit = 10033;
  static_assert(PluginEffects::maximum_bytes == original_worker_limit);
  plugin_effect_detail::decoding();
  plugin_effect_detail::authorization();
}

}
