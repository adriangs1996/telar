#pragma once

#include "history/entry.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "text/bounded_text.hpp"
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace telar::gui {

struct HistoryEmptyOptions {
  HistoryPhase phase = HistoryPhase::idle;
  HistoryScope scope = HistoryScope::global;
  HistoryAuthorFilter author = HistoryAuthorFilter::human;
  std::string_view workspace;
  std::uint32_t page_offset = 0;
  bool has_page = false;
  bool has_query = false;
  bool failed_only = false;
};

struct HistoryEmpty {
  static constexpr std::size_t title_capacity = 96;

  enum class Action : std::uint8_t {
    none,
    import,
    everywhere,
  };

  BoundedText<title_capacity> title;
  std::string_view subtitle;
  Action action = Action::none;
  bool emphasized = false;

  [[nodiscard]] static HistoryEmpty derive(const HistoryEmptyOptions &options) {
    HistoryEmpty result;
    if (options.phase == HistoryPhase::loading && !options.has_page) {
      result.title.append("Searching your command history…");

      return result;
    }

    if (options.phase == HistoryPhase::failed) {
      result.title.append("Could not load the command history");

      return result;
    }

    result.emphasized = true;
    const auto nothing_recorded = !options.has_query && options.scope == HistoryScope::global && options.author == HistoryAuthorFilter::all && !options.failed_only && options.page_offset == 0;
    if (nothing_recorded) {
      result.title.append("No commands yet");
      result.subtitle = "Commands you run in telar appear here as you work. Bring your shell history:";
      result.action = Action::import;

      return result;
    }

    result.subtitle = "Widen the search or check the filters.";
    result.action = options.scope == HistoryScope::global ? Action::none : Action::everywhere;
    switch (options.scope) {
    case HistoryScope::global:
      result.title.append("No matching commands");
      break;
    case HistoryScope::workspace: {
      constexpr std::string_view prefix = "No matches in workspace ";
      if (options.workspace.size() <= title_capacity - prefix.size()) {
        result.title.append(prefix);
        result.title.append(options.workspace);
      } else {
        result.title.append("No matches in this workspace");
      }

      break;
    }
    case HistoryScope::cwd:
      result.title.append("No matches in this directory");

      break;
    case HistoryScope::pane:
      result.title.append("No matches in this pane");

      break;
    }

    return result;
  }
};

}
