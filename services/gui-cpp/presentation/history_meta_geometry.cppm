module;
#include <stdlib.h>
#include <cstdio>

#include <cmath>
#include <cstdint>
#include <cstddef>

#include <ghostty/vt/unicode.h>

#include <cstring>
#include "tbc/view.hpp"


export module telar.gui.presentation.history_meta_geometry;

import std;

export import telar.gui.core.metrics;


export import telar.gui.text.bounded_editor;


export import telar.gui.presentation.history_filter_geometry;

export import telar.gui.text.json_unsigned_integer;
import telar.base.diagnostics;
import telar.base.memory;
import telar.client.protocol;
import telar.gui.core.primitives;

// Interface: presentation/history_row_geometry.cppm
export {
namespace telar::gui {

struct HistoryRowMeasurements {
  float command = 0;
  float cwd = 0;
  float time = 0;
  bool agent = false;
  bool show_cwd = true;
  bool has_cwd = false;
  bool has_time = false;
  bool expanded = false;
};

struct HistoryRowGeometry {
  static constexpr float horizontal_inset = 8;
  static constexpr float vertical_inset = 1;
  static constexpr float status_inset = 10;
  static constexpr float status_width = 20;
  static constexpr float command_inset = 40;
  static constexpr float right_inset = 12;
  static constexpr float fact_gap = 14;
  static constexpr float provider_side = 16;
  static constexpr float minimum_command = 160;
  static constexpr float corner_radius = 8;
  static constexpr float heading_inset = 18;
  static constexpr float provider_radius = 3;
  static constexpr float selection_tint_alpha = 0.08F;
  static constexpr float selection_ring_alpha = 0.28F;
  static constexpr float hover_alpha = 0.6F;
  static constexpr float cwd_alpha = 0.8F;

  Rect frame;
  Rect status;
  Rect command;
  Rect provider;
  Rect cwd;
  Rect time;

  [[nodiscard]] inline static HistoryRowGeometry derive(Rect bounds, ChromeMetrics chrome, float row_height, HistoryRowMeasurements measurements) noexcept {
    HistoryRowGeometry result;
    result.frame = bounds.inset(chrome.px(horizontal_inset), chrome.px(vertical_inset));
    const auto line_x = result.frame.x + chrome.px(command_inset);
    const Rect line{.x = line_x, .y = result.frame.y, .width = std::max(0.0F, result.frame.right() - chrome.px(right_inset) - line_x), .height = std::max(0.0F, row_height - chrome.px(2 * vertical_inset))};
    result.status = {.x = result.frame.x + chrome.px(status_inset), .y = line.y, .width = chrome.px(status_width), .height = line.height};
    const auto gap = chrome.px(fact_gap);
    Facts facts;
    if (measurements.agent) {
      facts.append(Kind::provider, std::round(chrome.px(provider_side)), gap);
    }

    if (!measurements.expanded && measurements.show_cwd && measurements.has_cwd) {
      facts.append(Kind::cwd, measurements.cwd, gap);
    }

    if (measurements.has_time) {
      facts.append(Kind::time, measurements.time, gap);
    }

    if (!measurements.expanded && measurements.command + facts.width > line.width) {
      facts.removeCwd(gap);
    }

    while (facts.count > 0 && facts.width - gap > line.width - chrome.px(minimum_command)) {
      facts.remove(facts.count - 1, gap);
    }

    facts.width = std::max(0.0F, facts.width - gap);
    result.command = line;
    const auto reserved = facts.count == 0 ? 0 : facts.width + gap;
    result.command.width = std::max(0.0F, line.width - reserved);
    auto x = line.right() - facts.width;
    for (std::size_t index = 0; index < facts.count; ++index) {
      const auto token = facts.tokens[index];
      const Rect area{.x = x, .y = line.y, .width = token.width, .height = line.height};
      switch (token.kind) {
      case Kind::provider:
        result.provider = {.x = x, .y = line.y + std::floor((line.height - token.width) / 2), .width = token.width, .height = token.width};
        break;
      case Kind::cwd:
        result.cwd = area;
        break;
      case Kind::time:
        result.time = area;
        break;
      }

      x += token.width + gap;
    }

    return result;
  }

  bool operator==(const HistoryRowGeometry &) const = default;

private:
  enum class Kind : std::uint8_t {
    provider,
    cwd,
    time,
  };

  struct Token {
    Kind kind = Kind::provider;
    float width = 0;
  };

  struct Facts {
    static constexpr std::size_t capacity = 3;
    std::array<Token, capacity> tokens{};
    std::size_t count = 0;
    float width = 0;

    inline void append(Kind kind, float advance, float gap) noexcept {
      tokens[count++] = {.kind = kind, .width = advance};
      width += advance + gap;
    }

    inline void remove(std::size_t index, float gap) noexcept {
      width -= tokens[index].width + gap;
      for (auto next = index + 1; next < count; ++next) {
        tokens[next - 1] = tokens[next];
      }

      --count;
    }

    inline void removeCwd(float gap) noexcept {
      for (std::size_t index = 0; index < count; ++index) {
        if (tokens[index].kind == Kind::cwd) {
          remove(index, gap);

          return;
        }
      }
    }
  };
};

}
}

// Interface: presentation/history_card.cppm
export {
namespace telar::gui {

struct HistoryCardMetrics {
  float cell_width = 1;
  float cell_height = 1;
  float row_height = 0;
  float viewport_height = 0;
};

// A shown line of a command, as where it lies in the command the card was measured over.
struct HistoryCardLine {
  std::uint32_t offset = 0;
  std::uint32_t length = 0;
};

struct HistoryCard {
  static constexpr std::size_t maximum_lines = 10;
  static constexpr std::uint16_t more_bound = 64;
  static constexpr float viewport_share = 0.45F;
  static constexpr float viewport_reservation = 32;
  static constexpr float viewport_clearance = 4;
  static constexpr float meta_gap = 4;
  static constexpr float bottom_inset = 8;
  static constexpr float minimum_meta_height = 22;
  static constexpr float meta_padding = 6;

  std::array<HistoryCardLine, maximum_lines> lines{};
  std::uint16_t shown = 0;
  std::uint16_t more = 0;
  std::uint16_t line_limit = maximum_lines;
  float text_y = 0;
  float intrinsic_height = 0;
  float height = 0;
  Rect meta;

  // The text of a shown line of the command the card was measured over.
  [[nodiscard]] inline static tbc::view<std::string_view, tbc::lt::a> line(tbc::view<std::string_view, tbc::lt::a> command, HistoryCardLine line) noexcept {
    return command.substr(std::min<std::size_t>(line.offset, command.size()), line.length);
  }

  // The card keeps where its lines lie in the command, so it views nothing the caller may replace.
  [[nodiscard]] inline static HistoryCard measure(const HistoryRowGeometry &row, ChromeMetrics chrome, HistoryCardMetrics metrics, std::string_view command) noexcept {
    HistoryCard result;
    result.line_limit = lineLimit(chrome, metrics);
    const auto columns = std::floor(row.command.width / std::max(1.0F, metrics.cell_width));
    const auto bounded_columns = static_cast<std::uint16_t>(std::clamp(columns, 0.0F, static_cast<float>(std::numeric_limits<std::uint16_t>::max())));
    WrappedLines wrapped{command, bounded_columns, true};
    std::uint16_t total = 0;
    while (total < result.line_limit + more_bound) {
      const auto line = wrapped.next();
      if (!line) {
        break;
      }

      if (total < result.line_limit) {
        result.lines[total] = {.offset = static_cast<std::uint32_t>(line->data() - command.data()), .length = static_cast<std::uint32_t>(line->size())};
      }

      ++total;
    }

    result.shown = std::min(total, result.line_limit);
    result.more = total - result.shown;
    const auto top_inset = std::max(0.0F, std::floor((row.command.height - metrics.cell_height) / 2));
    const auto command_height = static_cast<float>(result.shown) * metrics.cell_height;
    const auto meta_height = std::max(chrome.px(minimum_meta_height), ChromeMetrics::lineHeight(chrome.small) + chrome.px(meta_padding));
    result.text_y = row.command.y + top_inset;
    result.meta = {.x = row.command.x, .y = result.text_y + command_height + chrome.px(meta_gap), .width = std::max(0.0F, row.frame.right() - chrome.px(bottom_inset) - row.command.x), .height = meta_height};
    result.intrinsic_height = chrome.px(2 * HistoryRowGeometry::vertical_inset) + top_inset + command_height + chrome.px(meta_gap) + meta_height + chrome.px(bottom_inset);
    const auto opened_height = std::round(metrics.row_height + std::max(0.0F, result.intrinsic_height - metrics.row_height));
    const auto tallest = std::max(metrics.row_height, metrics.viewport_height - chrome.px(viewport_clearance));
    result.height = metrics.viewport_height > 0 ? std::min(tallest, opened_height) : opened_height;

    return result;
  }

private:
  [[nodiscard]] inline static std::uint16_t lineLimit(ChromeMetrics chrome, HistoryCardMetrics metrics) noexcept {
    if (metrics.viewport_height <= 0) {
      return maximum_lines;
    }

    const auto budget = (metrics.viewport_height * viewport_share) - metrics.row_height - chrome.px(viewport_reservation);
    const auto count = std::floor(budget / std::max(1.0F, metrics.cell_height)) + 1;

    return static_cast<std::uint16_t>(std::clamp(count, 1.0F, static_cast<float>(maximum_lines)));
  }
};

}
}

// Interface: presentation/history_facts.cppm
export {
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
  inline static void visit(const HistoryFactData &data, Sink &sink) {
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
  inline static void notice(const HistoryFactData &data, Sink &sink) {
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
}

// Interface: presentation/history_footer.cppm
export {
namespace telar::gui {

enum class HistoryFooterAction : std::uint8_t {
  none,
  submit,
  alternate,
  inspect,
  visit,
};

struct HistoryFooterHint {
  std::string_view key;
  std::string_view word;
  HistoryFooterAction action = HistoryFooterAction::none;
};

struct HistoryFooterOptions {
  HistoryKeyStyle key_style = HistoryKeyStyle::pc;
  std::uint32_t offset = 0;
  std::uint16_t count = 0;
  bool inspecting = false;
  bool enter_runs = false;
  bool has_more = false;
  bool fuzzy = false;
  bool has_query = false;
};

struct HistoryFooter {
  static constexpr std::size_t browse_count = 3;
  static constexpr std::size_t inspect_count = 4;
  static constexpr std::size_t capacity = inspect_count;
  static constexpr std::size_t range_capacity = 64;
  using Range = BoundedText<range_capacity>;

  std::array<HistoryFooterHint, capacity> hints{};
  std::size_t count = 0;

  [[nodiscard]] static constexpr HistoryFooter resolve(HistoryFooterOptions options) noexcept {
    const bool mac = options.key_style == HistoryKeyStyle::mac;
    HistoryFooter result;
    result.hints.front() = {.key = mac ? "↩" : "Enter", .word = options.enter_runs ? "run" : "paste", .action = HistoryFooterAction::submit};
    if (options.inspecting) {
      result.hints[1] = {.key = HistoryActions::inspectionKey(options.key_style), .word = "back", .action = HistoryFooterAction::inspect};
      result.hints[2] = {.key = mac ? "⇞⇟" : "PgUp PgDn", .word = "scroll"};
      result.hints[3] = {.key = mac ? "⌥↩" : "Alt+Enter", .word = "go to pane", .action = HistoryFooterAction::visit};
      result.count = inspect_count;
    } else {
      result.hints[1] = {.key = mac ? "⇧↩" : "Shift+Enter", .word = options.enter_runs ? "paste" : "run", .action = HistoryFooterAction::alternate};
      result.hints[2] = {.key = HistoryActions::inspectionKey(options.key_style), .word = "details", .action = HistoryFooterAction::inspect};
      result.count = browse_count;
    }

    return result;
  }

  [[nodiscard]] inline static Range range(HistoryFooterOptions options) {
    Range result;
    result.appendDecimal(static_cast<std::uint64_t>(options.offset) + 1);
    result.append("–");
    result.appendDecimal(static_cast<std::uint64_t>(options.offset) + options.count);
    if (options.has_more) {
      result.append(options.key_style == HistoryKeyStyle::mac ? "  ·  ⇞ older" : "  ·  PgUp older");
    }

    if (options.fuzzy && options.has_query) {
      result.append("  ·  fuzzy");
    }

    return result;
  }
};

}
}

// Interface: presentation/history_hint_geometry.cppm
export {
namespace telar::gui {

struct HistoryHintMeasurements {
  float key = 0;
  float word = 0;
};

struct HistoryHintGeometry {
  static constexpr float padding = 6;
  static constexpr float word_gap = 6;
  static constexpr float minimum_key_width = 22;
  static constexpr float key_padding = 10;
  static constexpr float minimum_key_height = 20;
  static constexpr float key_vertical_padding = 4;
  static constexpr float corner_radius = 4;
  static constexpr float key_ring_alpha = 0.2F;
  static constexpr float key_text_alpha = 0.7F;
  static constexpr float ring_width = 1;

  Rect bounds;
  Rect keycap;
  Rect key_text;
  Rect word;

  [[nodiscard]] inline static float width(ChromeMetrics chrome, HistoryHintMeasurements measured) noexcept {
    return keyWidth(chrome, measured.key) + chrome.px(word_gap) + measured.word + chrome.px(padding * 2);
  }

  [[nodiscard]] inline static HistoryHintGeometry derive(Rect bounds, ChromeMetrics chrome, HistoryHintMeasurements measured) noexcept {
    HistoryHintGeometry result;
    result.bounds = bounds;
    const auto x = bounds.x + chrome.px(padding);
    const auto key_width = std::min(keyWidth(chrome, measured.key), std::max(0.0F, bounds.right() - x));
    const auto height = std::min(bounds.height, std::max(chrome.px(minimum_key_height), ChromeMetrics::lineHeight(chrome.small) + chrome.px(key_vertical_padding)));
    result.keycap = {.x = x, .y = bounds.y + ((bounds.height - height) / 2), .width = key_width, .height = height};
    const auto text_width = std::min(measured.key, key_width);
    result.key_text = {.x = x + ((key_width - text_width) / 2), .y = result.keycap.y, .width = text_width, .height = height};
    const auto word_x = x + key_width + chrome.px(word_gap);
    result.word = {.x = word_x, .y = bounds.y, .width = std::max(0.0F, bounds.right() - word_x), .height = bounds.height};

    return result;
  }

private:
  [[nodiscard]] inline static float keyWidth(ChromeMetrics chrome, float measured) noexcept {
    return std::max(chrome.px(minimum_key_width), measured + chrome.px(key_padding));
  }
};

}
}

// Interface: presentation/history_footer_geometry.cppm
export {
namespace telar::gui {

struct HistoryFooterMeasurements {
  std::array<HistoryHintMeasurements, HistoryFooter::capacity> hints{};
  std::size_t count = 0;
  float range = 0;
  bool empty = true;
  bool error = false;
};

struct HistoryFooterGeometry {
  static constexpr float horizontal_inset = 16;
  static constexpr float vertical_inset = 5;
  static constexpr float hint_gap = 4;
  static constexpr float range_gap = 12;
  static constexpr float separator_height = 1;

  std::array<HistoryHintGeometry, HistoryFooter::capacity> hints{};
  std::size_t count = 0;
  Rect separator;
  Rect range;
  Rect error;
  bool range_visible = false;
  bool error_visible = false;

  [[nodiscard]] inline static HistoryFooterGeometry derive(Rect area, ChromeMetrics chrome, const HistoryFooterMeasurements &measured) noexcept {
    HistoryFooterGeometry result;
    if (area.empty()) {
      return result;
    }

    result.separator = {.x = area.x, .y = area.y, .width = area.width, .height = separator_height};
    const auto left = area.x + chrome.px(horizontal_inset);
    const auto limit = area.right() - chrome.px(horizontal_inset);
    if (measured.error) {
      result.error = {.x = left, .y = area.y, .width = std::max(0.0F, limit - left), .height = area.height};
      result.error_visible = true;

      return result;
    }

    auto x = left - chrome.px(HistoryHintGeometry::padding);
    const auto available = std::min(measured.count, measured.hints.size());
    for (std::size_t index = 0; index < available; ++index) {
      const auto width = HistoryHintGeometry::width(chrome, measured.hints[index]);
      if (x + width > limit) {
        break;
      }

      const Rect bounds{.x = x, .y = area.y + chrome.px(vertical_inset), .width = width, .height = std::max(0.0F, area.height - chrome.px(vertical_inset * 2))};
      result.hints[index] = HistoryHintGeometry::derive(bounds, chrome, measured.hints[index]);
      ++result.count;
      x += width + chrome.px(hint_gap);
    }

    if (!measured.empty && x + chrome.px(range_gap) + measured.range <= limit) {
      result.range = {.x = limit - measured.range, .y = area.y, .width = measured.range, .height = area.height};
      result.range_visible = true;
    }

    return result;
  }
};

}
}

// Interface: presentation/history_meta_geometry.cppm
export {
namespace telar::gui {

struct HistoryMetaMeasurements {
  std::array<float, HistoryFacts::capacity> facts{};
  std::array<HistoryHintMeasurements, HistoryActions::count> actions{};
  std::size_t fact_count = 0;
  bool selected = true;
  bool pane_open = false;
};

struct HistoryMetaGeometry {
  static constexpr float action_gap = 2;
  static constexpr float facts_right_inset = 10;

  std::array<Rect, HistoryFacts::capacity> facts{};
  std::array<HistoryHintGeometry, HistoryActions::count> actions{};
  std::size_t fact_count = 0;
  std::size_t action_count = 0;
  Rect facts_area;

  [[nodiscard]] inline static HistoryMetaGeometry derive(Rect bounds, ChromeMetrics chrome, const HistoryMetaMeasurements &measured) noexcept {
    HistoryMetaGeometry result;
    if (bounds.empty()) {
      return result;
    }

    float total = 0;
    const auto available_actions = measured.selected ? HistoryActions::count - static_cast<std::size_t>(!measured.pane_open) : 0;
    for (std::size_t index = 0; index < available_actions; ++index) {
      const auto width = HistoryHintGeometry::width(chrome, measured.actions[index]);
      if (bounds.width - total - width < chrome.px(HistoryRowGeometry::minimum_command)) {
        break;
      }

      total += width + chrome.px(action_gap);
      ++result.action_count;
    }

    auto x = bounds.right() - total;
    for (std::size_t index = 0; index < result.action_count; ++index) {
      const auto width = HistoryHintGeometry::width(chrome, measured.actions[index]);
      result.actions[index] = HistoryHintGeometry::derive({.x = x, .y = bounds.y, .width = width, .height = bounds.height}, chrome, measured.actions[index]);
      x += width + chrome.px(action_gap);
    }

    const auto right = bounds.right() - total;
    result.facts_area = {.x = bounds.x, .y = bounds.y, .width = std::max(0.0F, right - chrome.px(facts_right_inset) - bounds.x), .height = bounds.height};
    x = result.facts_area.x;
    const auto count = std::min(measured.fact_count, measured.facts.size());
    for (std::size_t index = 0; index < count; ++index) {
      const auto width = measured.facts[index];
      if (x + width > result.facts_area.right()) {
        break;
      }

      result.facts[index] = {.x = x, .y = bounds.y, .width = width, .height = bounds.height};
      ++result.fact_count;
      x += width + chrome.px(HistoryRowGeometry::fact_gap);
    }

    return result;
  }
};

}
}

// Interface: presentation/notification_text.cppm
export {
namespace telar::gui {

class NotificationText {
public:
  static constexpr std::size_t maximum_lines = 3;

  [[nodiscard]] inline std::size_t count() const noexcept {
    return count_;
  }

  [[nodiscard]] inline std::string_view line(std::size_t index) const {
    if (index >= count_) {
      throw std::out_of_range{"InvalidNotificationLine"};
    }

    return owned_tail_ && index + 1 == count_ ? tail_.view() : lines_[index];
  }

  template <LabelMeasure Measure>
  inline void wrap(std::string_view text, float width, Measure &measure) {
    *this = {};
    auto remaining = trimStart(text);
    const auto last = remaining.find_last_not_of(whitespace);
    remaining = last == std::string_view::npos ? std::string_view{} : remaining.substr(0, last + 1);
    while (!remaining.empty() && count_ < maximum_lines) {
      const auto newline = remaining.find_first_of("\r\n");
      const auto paragraph = remaining.substr(0, newline);
      if (count_ + 1 == maximum_lines) {
        fitTail(paragraph, newline != std::string_view::npos, width, measure);
        break;
      }

      const auto end = measure(paragraph) > width ? wrapEnd(paragraph, width, measure) : paragraph.size();
      if (end == 0) {
        break;
      }

      const auto prefix = paragraph.substr(0, end);
      const auto last_word = prefix.find_last_not_of(" \t");
      lines_[count_++] = last_word == std::string_view::npos ? std::string_view{} : prefix.substr(0, last_word + 1);
      remaining = trimStart(remaining.substr(end));
    }
  }

private:
  static constexpr std::string_view whitespace = " \t\r\n";

  [[nodiscard]] inline static std::string_view trimStart(std::string_view text) noexcept {
    const auto first = text.find_first_not_of(whitespace);
    text.remove_prefix(first == std::string_view::npos ? text.size() : first);

    return text;
  }

  template <LabelMeasure Measure>
  [[nodiscard]] inline static std::size_t wrapEnd(std::string_view paragraph, float width, Measure &measure) {
    GraphemeCursor cursor{paragraph};
    std::size_t end = 0;
    std::size_t word_end = 0;
    while (const auto cluster = cursor.next()) {
      const auto candidate = end + cluster->size();
      if (measure(paragraph.substr(0, candidate)) > width) {
        break;
      }

      if (*cluster == " " || *cluster == "\t") {
        word_end = end;
      }

      end = candidate;
    }

    return word_end > 0 ? word_end : end;
  }

  template <LabelMeasure Measure>
  inline void fitTail(std::string_view paragraph, bool following_paragraph, float width, Measure &measure) {
    BoundedText<TextFit::maximum_bytes> continuation;
    auto label = paragraph;
    if (following_paragraph) {
      continuation.append(runtime::utf8Prefix(paragraph, TextFit::maximum_bytes - TextFit::ellipsis.size()));
      continuation.append(TextFit::ellipsis);
      label = continuation.view();
    }

    TextFit::Buffer fitted_buffer;
    const auto fitted = TextFit::fit(label, width, measure, fitted_buffer);
    owned_tail_ = following_paragraph || fitted.data() == fitted_buffer.data();
    if (owned_tail_) {
      tail_.assign(fitted);
    } else {
      // Unless the fit shortens the label into its buffer, it keeps the whole paragraph or nothing.
      lines_[count_] = fitted.empty() ? std::string_view{} : paragraph;
    }

    ++count_;
  }

  std::array<std::string_view, maximum_lines> lines_{};
  runtime::FixedText<TextFit::maximum_bytes> tail_;
  std::size_t count_ = 0;
  bool owned_tail_ = false;
};

}
}
