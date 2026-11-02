#pragma once

#include "core/theme_values.hpp"
#include "presentation/history_actions.hpp"
#include "presentation/history_card.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "text/bounded_text.hpp"
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::gui {

struct HistoryFactData {
  std::string_view directory;
  std::string_view provider;
  std::string_view duration;
  std::string_view age;
  std::optional<std::int32_t> exit_code;
  HistoryStatus status = HistoryStatus::completed;
  HistoryKeyStyle key_style = HistoryKeyStyle::pc;
  std::uint16_t more = 0;
  bool truncated = false;
  bool loaded = true;
  bool show_directory = true;
  bool has_time = true;
  bool agent = false;
};

template <typename Sink>
concept HistoryFactSink = requires(Sink &sink, std::string_view text, PaletteRole color) {
  { sink(text, color) } -> std::same_as<void>;
};

struct HistoryFacts {
  static constexpr std::size_t capacity = 6;
  static constexpr std::size_t notice_capacity = 64;
  static constexpr std::size_t outcome_capacity = 24;

  template <HistoryFactSink Sink>
  static void visit(const HistoryFactData &data, Sink &sink) {
    notice(data, sink);
    if (data.show_directory && !data.directory.empty()) {
      sink(data.directory, PaletteRole::subtext0);
    }

    if (data.status == HistoryStatus::running) {
      sink("running", PaletteRole::teal);
    } else if (data.status == HistoryStatus::interrupted) {
      sink("stopped", PaletteRole::yellow);
    } else if (data.exit_code && *data.exit_code != 0) {
      BoundedText<outcome_capacity> text;
      text.append("exit ");
      const auto code = static_cast<std::int64_t>(*data.exit_code);
      if (code < 0) {
        text.append("-");
      }

      text.appendDecimal(static_cast<std::uint64_t>(code < 0 ? -code : code));
      sink(text.view(), PaletteRole::red);
    }

    if (data.status != HistoryStatus::running) {
      sink(data.duration, PaletteRole::subtext0);
    }

    if (data.has_time) {
      sink(data.age, PaletteRole::subtext0);
    }

    if (data.agent) {
      sink(data.provider.empty() ? "agent" : data.provider, PaletteRole::subtext0);
    }
  }

private:
  template <HistoryFactSink Sink>
  static void notice(const HistoryFactData &data, Sink &sink) {
    if (data.truncated) {
      sink("capture cut short, cannot paste", PaletteRole::yellow);
    } else if (!data.loaded) {
      sink("loading the complete command…", PaletteRole::subtext0);
    } else if (data.more != 0) {
      BoundedText<notice_capacity> text;
      text.append("+");
      text.appendDecimal(data.more);
      if (data.more == HistoryCard::more_bound) {
        text.append("+");
      }

      text.append(" more lines  ·  ");
      text.append(HistoryActions::inspectionKey(data.key_style));
      text.append(" shows all");
      sink(text.view(), PaletteRole::accent);
    }
  }
};

}
