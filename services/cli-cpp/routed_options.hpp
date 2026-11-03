#pragma once

#include "arguments.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_plugins/identity.hpp"
#include <algorithm>
#include <array>
#include <limits>
#include <optional>
#include <string>
#include <string_view>

namespace telar::runtime::cli {

// Each `ClientAction` as Zig's `@tagName` prints it, in the enum's order.
inline constexpr std::array<std::string_view, 34> client_action_names{
    "workspace_select", "tab_create", "tab_select", "tab_next", "tab_previous", "pane_create", "pane_split",
    "pane_close", "pane_focus", "pane_resize", "pane_fullscreen", "pane_scroll", "sidebar_get", "sidebar_show",
    "sidebar_hide", "sidebar_resize", "workspace_list_expand", "workspace_list_collapse", "client_open_goto",
    "client_open_history", "client_copy_mode", "notification_dismiss", "client_open_link", "client_clipboard_copy",
    "pane_copy", "layout_get", "layout_apply", "config_reload", "config_show", "plugin_list", "plugin_get",
    "plugin_enable", "plugin_disable", "plugin_run"};

inline constexpr std::array<std::string_view, 4> pane_directions{"left", "right", "up", "down"};

inline std::string_view clientActionName(ClientAction action) {
  return client_action_names.at(static_cast<std::size_t>(action));
}

// `CopySelection.fromText`: "ROW,COLUMN:ROW,COLUMN".
inline void copyRange(std::string_view text) {
  const auto colon = text.find(':');
  if (colon == std::string_view::npos) {
    usage("InvalidCopyRange");
  }

  for (const auto point : {text.substr(0, colon), text.substr(colon + 1)}) {
    const auto comma = point.find(',');
    if (comma == std::string_view::npos) {
      usage("InvalidCopyRange");
    }

    number<std::uint16_t>(point.substr(0, comma), "InvalidCopyRange");
    number<std::uint32_t>(point.substr(comma + 1), "InvalidCopyRange");
  }
}

// A command a window performs, as Zig's `arguments/RoutedOptions.zig`: the
// family and verb name a `ClientAction` ("pane copy" is `pane_copy`), and the
// runtime forwards it to the client `--client` names.
struct RoutedOptions {
  ClientAction action{};
  std::uint64_t client_id = 0;
  std::uint64_t target_id = 0;
  std::int64_t value = 0;
  std::string_view text{};
  bool json = false;
  const char *socket = nullptr;

  // `words` starts at the family. Not a routed command: nullopt, so the
  // family's own parser reads it.
  static std::optional<RoutedOptions> parse(Arguments words) {
    if (words.size() < 2) {
      return std::nullopt;
    }

    const std::string_view group = words[0];
    const std::string_view verb = words[1];
    const bool nested = group == "client" && (verb == "open" || verb == "clipboard");
    const std::size_t consumed = nested ? 3 : 2;
    if (words.size() < consumed) {
      usage("MissingClientAction");
    }

    const auto action = parseAction(group, verb, nested ? std::string_view{words[2]} : std::string_view{});
    if (!action || excluded(*action, words.subspan(2))) {
      return std::nullopt;
    }

    RoutedOptions self{.action = *action};
    Cursor cursor{words.subspan(consumed)};
    self.positionals(cursor);
    self.options(cursor);
    if (self.client_id == 0) {
      usage("MissingClientId");
    }

    return self;
  }

private:
  static std::optional<ClientAction> parseAction(std::string_view group, std::string_view verb, std::string_view nested) {
    constexpr std::size_t name_limit = 64;
    std::string name{group};
    name += '_';
    name += verb;
    if (!nested.empty()) {
      name += '_';
      name += nested;
    }

    if (name.size() > name_limit) {
      return std::nullopt;
    }

    std::ranges::replace(name, '-', '_');
    const auto found = std::ranges::find(client_action_names, name);
    if (found == client_action_names.end()) {
      return std::nullopt;
    }

    return static_cast<ClientAction>(found - client_action_names.begin());
  }

  // A tab created in the background never reaches a UI: the runtime opens it.
  // Focusing the current pane or a neighbor is the runtime's, too.
  static bool excluded(ClientAction action, Arguments rest) {
    const auto contains = [&](std::string_view word) { return std::ranges::any_of(rest, [&](const char *argument) { return word == argument; }); };
    if (action == ClientAction::tab_create) {
      return contains("--background");
    }

    if (action == ClientAction::pane_focus) {
      return contains("--current") || contains("--direction");
    }

    return false;
  }

  void positionals(Cursor &cursor) {
    using enum ClientAction;
    switch (action) {
    case plugin_run:
      text = cursor.take("MissingPlugin");
      target_id = plugins::stableId(cursor.take("MissingPluginAction"));
      break;
    case plugin_disable:
    case plugin_enable:
    case plugin_get:
      text = cursor.take("MissingPlugin");
      break;
    case layout_apply:
      text = cursor.take("MissingLayoutToken");
      break;
    case pane_copy:
      target_id = positive(cursor.take("MissingTarget"), "InvalidTarget");
      text = cursor.take("MissingCopyRange");
      copyRange(text);
      break;
    case client_clipboard_copy:
    case client_open_link:
      text = cursor.take("MissingText");
      break;
    case sidebar_resize: {
      const auto width = positive(cursor.take("MissingWidth"), "InvalidTarget");
      if (width > std::numeric_limits<std::uint16_t>::max()) {
        usage("InvalidWidth");
      }

      value = static_cast<std::int64_t>(width);
      break;
    }
    case pane_scroll:
      target_id = positive(cursor.take("MissingTarget"), "InvalidTarget");
      value = signedNumber<std::int32_t>(cursor.take("MissingScrollDelta"), "InvalidScrollDelta");
      break;
    case pane_resize:
      target_id = positive(cursor.take("MissingTarget"), "InvalidTarget");
      text = cursor.take("MissingPaneDirection");
      choice<PaneDirection>(text, "InvalidPaneDirection", pane_directions);
      break;
    case pane_split:
      target_id = positive(cursor.take("MissingTarget"), "InvalidTarget");
      text = cursor.take("MissingSplitAxis");
      if (text != "horizontal" && text != "vertical") {
        usage("InvalidSplitAxis");
      }
      break;
    case notification_dismiss:
    case pane_fullscreen:
    case pane_focus:
    case pane_close:
    case tab_select:
    case workspace_select:
      target_id = positive(cursor.take("MissingTarget"), "InvalidTarget");
      break;
    default:
      break;
    }
  }

  void options(Cursor &cursor) {
    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--client" && client_id == 0) {
        client_id = positive(cursor.take("MissingClientId"), "InvalidTarget");
      } else if (arg == "--label" && action == ClientAction::tab_create && text.empty()) {
        text = cursor.take("MissingLabel");
      } else if (arg == "--section" && action == ClientAction::config_show && text.empty()) {
        text = cursor.take("MissingSection");
      } else if (arg == "--index" && action == ClientAction::config_show) {
        value = number<std::uint16_t>(cursor.take("MissingIndex"), "InvalidIndex");
      } else if (arg == "--json" && !json) {
        json = true;
      } else if (arg == "--socket" && socket == nullptr) {
        socket = cursor.take("MissingSocketPath").data();
      } else {
        usage("UnknownClientCommandOption");
      }
    }
  }
};

}
