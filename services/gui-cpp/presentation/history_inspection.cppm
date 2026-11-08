module;
#include <cstdio>
#include <cstdlib>
#include <new>

#include <cstdint>
#include <cstddef>
#include <cstring>


#include <ghostty/vt/unicode.h>


#include <cmath>
#include "tbc/view.hpp"

export module telar.gui.presentation.history_inspection;

import std;

export import telar.gui.core.unicode_scalar;
export import telar.gui.core.metrics;
export import telar.gui.text.json_unsigned_integer;


export import telar.gui.history.browser;


export import telar.gui.text.bounded_editor;


export import telar.gui.input.copy_pointer;
export import telar.gui.input.key_encoder;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.gui.core.primitives;

// Interface: presentation/history_labels.cppm
export {
namespace telar::gui {

struct HistoryLabels {
  static constexpr std::size_t text_capacity = 32;
  static constexpr std::int64_t nanoseconds_per_millisecond = 1'000'000;
  static constexpr std::int64_t milliseconds_per_second = 1000;
  static constexpr std::int64_t milliseconds_per_tenth = 100;
  static constexpr std::int64_t seconds_per_minute = 60;
  static constexpr std::int64_t minutes_per_hour = 60;
  static constexpr std::int64_t hours_per_day = 24;
  static constexpr std::int64_t seconds_per_hour = seconds_per_minute * minutes_per_hour;
  static constexpr std::int64_t seconds_per_day = seconds_per_hour * hours_per_day;
  static constexpr std::int64_t days_per_week = 7;
  static constexpr std::int64_t epoch_weekday = 4;
  static constexpr int last_calendar_year = 9999;
  static constexpr std::int64_t last_calendar_day = std::chrono::sys_days{std::chrono::year{last_calendar_year} / std::chrono::December / 31}.time_since_epoch().count();
  static constexpr std::array<std::string_view, 12> month_names{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
  static constexpr std::array<std::string_view, 7> weekday_names{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"};
  static constexpr std::array<std::string_view, 7> short_weekday_names{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
  using Text = BoundedText<text_capacity>;

  struct Status {
    std::string_view glyph;
    PaletteRole color = PaletteRole::text;
  };

  [[nodiscard]] inline static Text duration(std::int64_t nanoseconds) {
    const auto milliseconds = std::max(nanoseconds, std::int64_t{0}) / nanoseconds_per_millisecond;
    Text result;
    if (milliseconds < milliseconds_per_second) {
      result.appendDecimal(static_cast<std::uint64_t>(milliseconds));
      result.append("ms");
    } else if (milliseconds < seconds_per_minute * milliseconds_per_second) {
      result.appendDecimal(static_cast<std::uint64_t>(milliseconds / milliseconds_per_second));
      result.append(".");
      result.appendDecimal(static_cast<std::uint64_t>((milliseconds % milliseconds_per_second) / milliseconds_per_tenth));
      result.append("s");
    } else if (milliseconds < seconds_per_hour * milliseconds_per_second) {
      result.appendDecimal(static_cast<std::uint64_t>(milliseconds / (seconds_per_minute * milliseconds_per_second)));
      result.append("m");
    } else {
      result.appendDecimal(static_cast<std::uint64_t>(milliseconds / (seconds_per_hour * milliseconds_per_second)));
      result.append("h");
    }

    return result;
  }

  [[nodiscard]] inline static Text age(std::int64_t milliseconds) {
    const auto seconds = std::max(milliseconds, std::int64_t{0}) / milliseconds_per_second;
    Text result;
    if (seconds < seconds_per_minute) {
      result.append("now");
    } else if (seconds < seconds_per_hour) {
      result.appendDecimal(static_cast<std::uint64_t>(seconds / seconds_per_minute));
      result.append("m ago");
    } else if (seconds < seconds_per_day) {
      result.appendDecimal(static_cast<std::uint64_t>(seconds / seconds_per_hour));
      result.append("h ago");
    } else {
      result.appendDecimal(static_cast<std::uint64_t>(seconds / seconds_per_day));
      result.append("d ago");
    }

    return result;
  }

  [[nodiscard]] inline static Text ageAt(std::int64_t started_ms, CalendarSample sampled) {
    if (sampled.now_ms < started_ms) {
      return age(0);
    }

    const auto elapsed = static_cast<std::uint64_t>(sampled.now_ms) - static_cast<std::uint64_t>(started_ms);

    return age(static_cast<std::int64_t>(std::min(elapsed, static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()))));
  }

  [[nodiscard]] inline static std::int64_t localDay(std::int64_t milliseconds, std::int16_t utc_offset_min) noexcept {
    return floorDivide(localSeconds(milliseconds, utc_offset_min), seconds_per_day);
  }

  [[nodiscard]] inline static Text clock(std::int64_t milliseconds, std::int16_t utc_offset_min) {
    const auto seconds = positiveRemainder(localSeconds(milliseconds, utc_offset_min), seconds_per_day);
    Text result;
    appendClockPart(result, static_cast<std::uint64_t>(seconds / seconds_per_hour));
    result.append(":");
    appendClockPart(result, static_cast<std::uint64_t>((seconds % seconds_per_hour) / seconds_per_minute));

    return result;
  }

  [[nodiscard]] inline static Text dayLabel(std::int64_t day, std::int64_t today) {
    Text result;
    if (day == today) {
      result.append("Today");
      return result;
    }

    if (day < today) {
      const auto distance = static_cast<std::uint64_t>(today) - static_cast<std::uint64_t>(day);
      if (distance == 1) {
        result.append("Yesterday");
        return result;
      }

      if (distance < static_cast<std::uint64_t>(days_per_week)) {
        result.append(weekday_names[weekday(day)]);
        return result;
      }
    }

    const auto date = calendar(day);
    if (!date) {
      result.append("Earlier");
      return result;
    }

    result.append(month_names[static_cast<unsigned>(date->month()) - 1]);
    result.append(" ");
    const auto now = calendar(today);
    result.appendDecimal(now && now->year() == date->year() ? static_cast<unsigned>(date->day()) : static_cast<unsigned>(static_cast<int>(date->year())));

    return result;
  }

  [[nodiscard]] inline static Text dateLabel(std::int64_t milliseconds, CalendarSample sampled) {
    const auto day = localDay(milliseconds, sampled.utc_offset_min);
    const auto today = localDay(sampled.now_ms, sampled.utc_offset_min);
    if (day == today) {
      return clock(milliseconds, sampled.utc_offset_min);
    }

    Text result;
    if (day < today) {
      const auto distance = static_cast<std::uint64_t>(today) - static_cast<std::uint64_t>(day);
      if (distance == 1) {
        result.append("Yesterday");
        return result;
      }

      if (distance < static_cast<std::uint64_t>(days_per_week)) {
        result.append(short_weekday_names[weekday(day)]);
        return result;
      }
    }

    const auto date = calendar(day);
    if (!date) {
      result.append("Earlier");
      return result;
    }

    const auto now = calendar(today);
    if (now && now->year() == date->year()) {
      result.append(month_names[static_cast<unsigned>(date->month()) - 1]);
      result.append(" ");
      result.appendDecimal(static_cast<unsigned>(date->day()));
    } else {
      result.appendDecimal(static_cast<unsigned>(static_cast<int>(date->year())));
    }

    return result;
  }

  [[nodiscard]] static constexpr Status status(HistoryStatus status, std::optional<std::int32_t> exit_code) noexcept {
    switch (status) {
    case HistoryStatus::running:
      return {.glyph = "◌", .color = PaletteRole::teal};
    case HistoryStatus::interrupted:
      return {.glyph = "■", .color = PaletteRole::yellow};
    case HistoryStatus::completed:
      if (!exit_code) {
        return {.glyph = "·", .color = PaletteRole::subtext0};
      }

      return *exit_code == 0 ? Status{.glyph = "·", .color = PaletteRole::overlay0} : Status{.glyph = "✕", .color = PaletteRole::red};
    }

    return {.glyph = "·", .color = PaletteRole::subtext0};
  }

private:
  [[nodiscard]] inline static std::int64_t floorDivide(std::int64_t value, std::int64_t divisor) noexcept {
    return (value / divisor) - static_cast<std::int64_t>(value % divisor < 0);
  }

  [[nodiscard]] inline static std::int64_t positiveRemainder(std::int64_t value, std::int64_t divisor) noexcept {
    const auto remainder = value % divisor;

    return remainder < 0 ? remainder + divisor : remainder;
  }

  [[nodiscard]] inline static std::int64_t localSeconds(std::int64_t milliseconds, std::int16_t utc_offset_min) noexcept {
    return floorDivide(milliseconds, milliseconds_per_second) + (static_cast<std::int64_t>(utc_offset_min) * seconds_per_minute);
  }

  [[nodiscard]] inline static std::size_t weekday(std::int64_t day) noexcept {
    return static_cast<std::size_t>((positiveRemainder(day, days_per_week) + epoch_weekday) % days_per_week);
  }

  [[nodiscard]] inline static std::optional<std::chrono::year_month_day> calendar(std::int64_t day) noexcept {
    if (day < 0 || day > last_calendar_day) {
      return std::nullopt;
    }

    return std::chrono::year_month_day{std::chrono::sys_days{std::chrono::days{day}}};
  }

  inline static void appendClockPart(Text &text, std::uint64_t value) {
    constexpr unsigned decimal_base = 10;
    if (value < decimal_base) {
      text.append("0");
    }

    text.appendDecimal(value);
  }
};

}
}

// Interface: presentation/tab_caption.cppm
export {
namespace telar::gui {

struct TabCaption {
  static constexpr std::size_t capacity = 128;
  static constexpr std::size_t directory_capacity = 48;
  static constexpr std::string_view separator = " · ";
  static constexpr std::string_view fallback_application = "shell";
  static constexpr std::string_view fullscreen_suffix = " ⛶";
  static constexpr std::string_view path_separators = "/\\";
  using Buffer = std::array<char, capacity>;

  struct Content {
    std::string_view manual;
    std::string_view application;
    std::string_view directory;
    std::string_view session_title;
  };

  [[nodiscard]] inline static std::string_view directoryName(std::string_view path) noexcept {
    if (path.empty()) {
      return {};
    }

    while (path.size() > 1 && path_separators.contains(path.back())) {
      path.remove_suffix(1);
    }

    if (path.size() != 1 || !path_separators.contains(path.front())) {
      const auto separator = path.find_last_of(path_separators);
      if (separator != std::string_view::npos && separator + 1 < path.size()) {
        path.remove_prefix(separator + 1);
      }
    }

    constexpr unsigned delete_control = 0x7f;
    if (inspectUtf8(path) != Utf8Validation::valid || std::ranges::any_of(path, [](char byte) { return static_cast<unsigned char>(byte) < ' ' || static_cast<unsigned char>(byte) == delete_control; })) {
      return {};
    }

    auto length = std::min(path.size(), directory_capacity);
    constexpr unsigned continuation_mask = static_cast<unsigned char>(~Utf8Scalar::continuation_mask);
    while (length != 0 && length < path.size() && (static_cast<unsigned char>(path[length]) & continuation_mask) == Utf8Scalar::continuation_prefix) {
      --length;
    }

    path.remove_suffix(path.size() - length);

    return path;
  }

  // The caption is one of the content's texts or is written into the storage, region `a`.
  [[nodiscard]] inline static tbc::view<std::string_view, tbc::lt::a> resolve(tbc::view<Content, tbc::lt::a> content, tbc::view<Buffer &, tbc::lt::a> storage) noexcept {
    if (!content.manual.empty()) {
      return content.manual;
    }

    if (!content.session_title.empty()) {
      return content.session_title;
    }

    const auto application = content.application.empty() ? fallback_application : content.application;
    const auto directory = directoryName(content.directory);
    const auto length = directory.size() + separator.size() + application.size();
    if (directory.empty() || length > storage.size()) {
      return application;
    }

    std::memcpy(storage.data(), directory.data(), directory.size());
    std::memcpy(storage.data() + directory.size(), separator.data(), separator.size());
    std::memcpy(storage.data() + directory.size() + separator.size(), application.data(), application.size());

    return {storage.data(), length};
  }
};

}
}

// Interface: presentation/history_inspection.cppm
export {
namespace telar::gui {

struct HistoryInspectionLine {
  enum class Kind : std::uint8_t {
    command,
    blank,
    fact,
    heading,
    output,
  };

  Kind kind = Kind::blank;
  std::string_view text;
  std::string_view label;
  PaletteRole color = PaletteRole::text;
  bool mono = false;
};

struct HistoryInspectionEntry {
  std::string_view directory;
  std::string_view provider;
  std::string_view tab;
  std::uint64_t id = 0;
  std::uint64_t pane_id = 0;
  std::int64_t started_at_ms = 0;
  std::int64_t duration_ns = 0;
  std::optional<std::int32_t> exit_code;
  HistoryStatus status = HistoryStatus::completed;
  HistoryAuthor author = HistoryAuthor::human;
  HistoryOrigin origin = HistoryOrigin::pane;
  bool pane_open = false;
};

struct HistoryInspectionFacts {
  static constexpr std::size_t count = 6;
  static constexpr std::size_t text_capacity = 128;
  static constexpr std::size_t pane_capacity = std::numeric_limits<std::uint64_t>::digits10 + 1 + std::string_view{"  ·  tab "}.size() + TabCaption::capacity;
  static constexpr std::int64_t last_timestamp_ms = 253'402'300'799'999;

  BoundedText<text_capacity> when;
  HistoryLabels::Text took;
  HistoryLabels::Text exit;
  BoundedText<pane_capacity> pane;
  BoundedText<text_capacity> by;
  std::string_view directory;
  PaletteRole exit_color = PaletteRole::text;

  [[nodiscard]] inline static HistoryInspectionFacts derive(const HistoryInspectionEntry &entry, CalendarSample sampled) {
    HistoryInspectionFacts result;
    result.directory = entry.directory;
    result.took = HistoryLabels::duration(entry.duration_ns);
    result.describeWhen(entry, sampled);
    result.describeExit(entry);
    result.describePane(entry);
    result.describeAuthor(entry);

    return result;
  }

  [[nodiscard]] inline std::array<HistoryInspectionLine, count> lines() const noexcept {
    using Kind = HistoryInspectionLine::Kind;

    return {
        {
            {.kind = Kind::fact, .text = when.view(), .label = "When"},
            {.kind = Kind::fact, .text = took.view(), .label = "Took"},
            {.kind = Kind::fact, .text = exit.view(), .label = "Exit", .color = exit_color},
            {.kind = Kind::fact, .text = directory, .label = "Where", .mono = true},
            {.kind = Kind::fact, .text = pane.view(), .label = "Pane"},
            {.kind = Kind::fact, .text = by.view(), .label = "By"},
        },
    };
  }

  [[nodiscard]] inline static BoundedText<text_capacity> outputHeading(HistoryPhase phase, bool truncated, std::size_t bytes) {
    BoundedText<text_capacity> result;
    switch (phase) {
    case HistoryPhase::idle:
      result.append("No captured output");
      break;
    case HistoryPhase::loading:
      result.append("Loading captured output...");
      break;
    case HistoryPhase::failed:
      result.append("Could not read captured output");
      break;
    case HistoryPhase::ready:
      if (bytes == 0) {
        result.append("No captured output");
      } else {
        result.append(truncated ? "Captured output (truncated)" : "Captured output");
      }

      break;
    }

    if (phase == HistoryPhase::ready && bytes != 0) {
      constexpr std::size_t kibibyte = 1024;
      constexpr std::size_t decimal_base = 10;
      result.append("  ·  ");
      result.appendDecimal(bytes < kibibyte ? bytes : bytes / kibibyte);
      if (bytes >= kibibyte) {
        result.append(".");
        result.appendDecimal((bytes % kibibyte) * decimal_base / kibibyte);
      }

      result.append(bytes < kibibyte ? " B" : " KiB");
    }

    return result;
  }

private:
  inline void describeWhen(const HistoryInspectionEntry &entry, CalendarSample sampled) {
    if (entry.started_at_ms < 0 || entry.started_at_ms > last_timestamp_ms) {
      when.append("Timestamp unavailable");
    } else {
      when.append(HistoryLabels::dayLabel(HistoryLabels::localDay(entry.started_at_ms, sampled.utc_offset_min), HistoryLabels::localDay(sampled.now_ms, sampled.utc_offset_min)).view());
      when.append(" ");
      when.append(HistoryLabels::clock(entry.started_at_ms, sampled.utc_offset_min).view());
      when.append("  ·  ");
      when.append(HistoryLabels::ageAt(entry.started_at_ms, sampled).view());
    }
  }

  inline void describeExit(const HistoryInspectionEntry &entry) {
    if (entry.status == HistoryStatus::running) {
      exit.append("running");
      exit_color = PaletteRole::teal;
    } else if (entry.status == HistoryStatus::interrupted) {
      exit.append("interrupted");
      exit_color = PaletteRole::yellow;
    } else if (entry.exit_code) {
      const auto code = static_cast<std::int64_t>(*entry.exit_code);
      if (code < 0) {
        exit.append("-");
      }

      exit.appendDecimal(static_cast<std::uint64_t>(code < 0 ? -code : code));
      exit_color = code == 0 ? PaletteRole::green : PaletteRole::red;
    } else {
      exit.append("unknown");
      exit_color = PaletteRole::subtext0;
    }
  }

  inline void describePane(const HistoryInspectionEntry &entry) {
    pane.appendDecimal(entry.pane_id);
    pane.append(entry.pane_open ? "  ·  tab " : "  ·  closed");
    if (entry.pane_open) {
      pane.append(entry.tab);
    }
  }

  inline void describeAuthor(const HistoryInspectionEntry &entry) {
    if (entry.author == HistoryAuthor::human) {
      by.append("You");
    } else {
      by.append(entry.provider.empty() ? "agent" : entry.provider);
    }

    if (entry.author == HistoryAuthor::agent) {
      constexpr std::array origins{std::string_view{"pane"}, std::string_view{"hook"}, std::string_view{"plugin"}};
      by.append("  ·  ");
      by.append(origins.at(static_cast<std::size_t>(entry.origin)));
    }

    by.append("  ·  #");
    by.appendDecimal(entry.id);
  }
};

struct HistoryInspectionDocument {
  std::string_view command;
  std::span<const HistoryInspectionLine> facts;
  std::string_view heading;
  std::string_view output;
};

class HistoryInspectionLines {
public:
  inline HistoryInspectionLines(HistoryInspectionDocument document, std::uint16_t columns) noexcept
      : facts_(document.facts),
        heading_(document.heading),
        output_(document.output),
        wrapped_(document.command, columns, true),
        columns_(columns) {}

  [[nodiscard]] inline std::optional<HistoryInspectionLine> next() noexcept {
    using Kind = HistoryInspectionLine::Kind;
    while (true) {
      switch (phase_) {
      case Phase::command:
        if (const auto text = wrapped_.next()) {
          return HistoryInspectionLine{.kind = Kind::command, .text = *text, .label = {}, .mono = true};
        }

        phase_ = Phase::after_command;
        break;
      case Phase::after_command:
        phase_ = Phase::facts;
        return HistoryInspectionLine{};
      case Phase::facts:
        if (fact_ < facts_.size()) {
          return facts_[fact_++];
        }

        phase_ = Phase::after_facts;
        break;
      case Phase::after_facts:
        phase_ = Phase::heading;
        return HistoryInspectionLine{};
      case Phase::heading:
        phase_ = Phase::output;
        wrapped_ = WrappedLines{output_, columns_};
        return HistoryInspectionLine{.kind = Kind::heading, .text = heading_, .label = {}, .color = PaletteRole::subtext0};
      case Phase::output:
        if (const auto text = wrapped_.next()) {
          return HistoryInspectionLine{.kind = Kind::output, .text = *text, .label = {}, .color = PaletteRole::subtext0, .mono = true};
        }

        phase_ = Phase::done;
        break;
      case Phase::done:
        return std::nullopt;
      }
    }
  }

  [[nodiscard]] inline std::uint32_t count() const noexcept {
    auto remaining = *this;
    std::uint32_t total = 0;
    while (remaining.next()) {
      ++total;
    }

    return total;
  }

private:
  enum class Phase : std::uint8_t {
    command,
    after_command,
    facts,
    after_facts,
    heading,
    output,
    done,
  };

  std::span<const HistoryInspectionLine> facts_;
  std::string_view heading_;
  std::string_view output_;
  WrappedLines wrapped_;
  std::uint16_t columns_;
  std::size_t fact_ = 0;
  Phase phase_ = Phase::command;
};

}
}

// Interface: presentation/history_path.cppm
export {
namespace telar::gui {

struct HistoryPath {
  static constexpr std::size_t byte_capacity = 61;
  static constexpr std::size_t plain_codepoints = 30;
  static constexpr std::size_t tail_codepoints = 28;
  static constexpr std::string_view prefix = "…/";
  using Text = BoundedText<byte_capacity>;

  [[nodiscard]] inline static Text compact(std::string_view path) {
    if (path.size() <= byte_capacity && tailStart(path, {.bytes = byte_capacity, .codepoints = plain_codepoints}) == 0) {
      return copy(path);
    }

    const auto last = path.find_last_not_of('/');
    if (last == std::string_view::npos) {
      return copy("/");
    }

    const auto end = last + 1;
    const auto leaf_separator = path.substr(0, end).find_last_of('/');
    const auto leaf = leaf_separator == std::string_view::npos ? 0 : leaf_separator + 1;
    const auto parent_separator = path.substr(0, leaf == 0 ? 0 : leaf - 1).find_last_of('/');
    const auto parent = parent_separator == std::string_view::npos ? 0 : parent_separator + 1;
    const auto candidate = path.substr(parent, end - parent);
    auto start = tailStart(candidate, {.bytes = byte_capacity - prefix.size(), .codepoints = tail_codepoints});
    if (start != 0) {
      const auto separator = candidate.find('/', start);
      if (separator != std::string_view::npos) {
        start = separator + 1;
      }
    }

    Text result;
    result.append(prefix);
    append(result, candidate.substr(start));

    return result;
  }

private:
  struct Limits {
    std::size_t bytes;
    std::size_t codepoints;
  };

  [[nodiscard]] inline static std::size_t codepoints(std::string_view cluster) noexcept {
    std::size_t count = 0;
    for (const auto byte : cluster) {
      const auto value = static_cast<unsigned char>(byte);
      if ((value & utf8_prefix_mask) != Utf8Scalar::continuation_prefix) {
        ++count;
      }
    }

    return count;
  }

  [[nodiscard]] inline static std::size_t tailStart(std::string_view text, Limits limits) noexcept {
    GraphemeCursor right{text};
    auto left = right;
    std::size_t bytes = 0;
    std::size_t scalars = 0;
    while (const auto cluster = right.nextReplacingInvalid()) {
      bytes += cluster->size();
      scalars += codepoints(*cluster);
      while (bytes > limits.bytes || scalars > limits.codepoints) {
        const auto first = left.nextReplacingInvalid();
        if (!first) {
          return text.size();
        }

        bytes -= first->size();
        scalars -= codepoints(*first);
      }
    }

    return left.position();
  }

  inline static void append(Text &destination, std::string_view path) {
    GraphemeCursor cursor{path};
    while (const auto cluster = cursor.nextReplacingInvalid()) {
      destination.append(*cluster);
    }
  }

  [[nodiscard]] inline static Text copy(std::string_view path) {
    Text result;
    append(result, path);

    return result;
  }

  static constexpr unsigned utf8_prefix_mask = 0xc0;
};

}
}

// Interface: presentation/mode_hints.cppm
export {
namespace telar::gui {

enum class StatusMode : std::uint8_t {
  normal,
  prefix,
  copy,
};

struct ModeHint {
  KeyChord key;
  tbc::view<std::string_view, tbc::lt::static_storage> label;
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
  [[nodiscard]] inline static ModeHints resolve(const Router &router) noexcept {
    ModeHints result;
    for (const auto &[action, label] : actions) {
      if (const auto key = router.prefixedKeyForAction({.kind = action})) {
        result.append({.key = *key, .label = label});
      }
    }

    return result;
  }

  inline void append(ModeHint hint) noexcept {
    if (count_ < hints_.size()) {
      hints_[count_++] = hint;
    }
  }

  [[nodiscard]] inline std::span<const ModeHint> items() const noexcept {
    return std::span{hints_}.first(count_);
  }

private:
  std::array<ModeHint, capacity> hints_{};
  std::size_t count_ = 0;
};

}
}

// Interface: presentation/mode_key_label.cppm
export {
namespace telar::gui {

struct ModeKeyLabel {
  static constexpr std::size_t capacity = 48;
  using Text = BoundedText<capacity>;

  [[nodiscard]] inline static Text format(KeyChord key) {
    Text result;
    if (key.has(KeyChord::Modifier::control)) {
      result.append("Ctrl+");
    }

    if (key.has(KeyChord::Modifier::alt)) {
      result.append("Alt+");
    }

    if (key.has(KeyChord::Modifier::shift)) {
      result.append("Shift+");
    }

    if (key.key == KeyChord::Key::character) {
      const auto text = KeyCharacter::text(key.character);
      static_cast<void>(Utf8Scalar::decode(text.view()));
      result.append(text.view());
    } else {
      result.append(name(key.key));
    }

    return result;
  }

private:
  [[nodiscard]] inline static std::string_view name(KeyChord::Key key) noexcept {
    switch (key) {
    case KeyChord::Key::up:
      return "Up";
    case KeyChord::Key::down:
      return "Down";
    case KeyChord::Key::left:
      return "Left";
    case KeyChord::Key::right:
      return "Right";
    case KeyChord::Key::home:
      return "Home";
    case KeyChord::Key::end:
      return "End";
    case KeyChord::Key::erase:
      return "Del";
    case KeyChord::Key::page_up:
      return "PgUp";
    case KeyChord::Key::page_down:
      return "PgDn";
    case KeyChord::Key::enter:
      return "Enter";
    case KeyChord::Key::escape:
      return "Esc";
    case KeyChord::Key::backspace:
      return "Backspace";
    case KeyChord::Key::tab:
      return "Tab";
    case KeyChord::Key::back_tab:
      return "BackTab";
    case KeyChord::Key::character:
      return {};
    }

    return {};
  }
};

}
}

// Interface: presentation/mode_bar_layout.cppm
export {
namespace telar::gui {

struct ModeBarLabel {
  static constexpr std::size_t text_capacity = 128;
  BoundedText<text_capacity> text;
  Rect bounds;
  PaletteRole ink = PaletteRole::subtext0;
  bool bold = false;
};

struct ModeBarRequest {
  StatusMode mode = StatusMode::normal;
  ModeHints hints{};
  Rect bounds;
  float ratio = 1;
  float cell_width = 1;
};

class ModeBarLayout {
public:
  static constexpr float chip_height = 18;
  static constexpr float chip_radius = 4;
  static constexpr float chip_gap = 8;
  static constexpr float hint_gap = 12;
  static constexpr float key_gap = 4;
  static constexpr std::size_t maximum_labels = 2 + (2 * ModeHints::capacity);
  static constexpr std::string_view copy_help = " h/j/k/l move  v select  V lines  / search  y copy  o open  q exit ";
  static constexpr std::string_view cancel_help = "Esc cancel";

  [[nodiscard]] inline static ModeBarLayout measure(const ModeBarRequest &request) {
    if (!std::isfinite(request.ratio) || request.ratio <= 0 || !std::isfinite(request.cell_width) || request.cell_width <= 0) {
      throw std::invalid_argument{"InvalidModeBarMetrics"};
    }

    ModeBarLayout result;
    if (request.mode == StatusMode::normal || request.bounds.empty()) {
      return result;
    }

    const auto title = request.mode == StatusMode::copy ? std::string_view{" COPY "} : std::string_view{" PREFIX "};
    const auto height = std::min(request.bounds.height, chip_height * request.ratio);
    const auto title_width = std::min(width(title, request.cell_width), request.bounds.width);
    result.chip_ = {.x = request.bounds.x, .y = request.bounds.y + std::floor((request.bounds.height - height) / 2), .width = title_width, .height = height};
    result.append(title, {.x = request.bounds.x, .y = request.bounds.y, .width = title_width, .height = request.bounds.height}, PaletteRole::surface_dim, true);
    auto x = request.bounds.x + title_width + (chip_gap * request.ratio);
    if (request.mode == StatusMode::copy) {
      static_cast<void>(result.hint(copy_help, x, request));

      return result;
    }

    static_cast<void>(result.hint(cancel_help, x, request));
    x += hint_gap * request.ratio;
    for (const auto &item : request.hints.items()) {
      const auto key = ModeKeyLabel::format(item.key);
      if (!result.hint(key.view(), x, request, true)) {
        break;
      }

      x += key_gap * request.ratio;
      if (!result.hint(item.label, x, request)) {
        break;
      }

      x += hint_gap * request.ratio;
    }

    return result;
  }

  [[nodiscard]] inline Rect chip() const noexcept {
    return chip_;
  }

  [[nodiscard]] inline std::span<const ModeBarLabel> labels() const noexcept {
    return std::span{labels_}.first(count_);
  }

private:
  [[nodiscard]] inline static float width(std::string_view text, float cell_width) {
    return static_cast<float>(cellTextColumns(text)) * cell_width;
  }

  inline bool hint(std::string_view text, float &x, const ModeBarRequest &request, bool key = false) {
    const auto advance = width(text, request.cell_width);
    if (x + advance > request.bounds.right()) {
      return false;
    }

    append(text, {.x = x, .y = request.bounds.y, .width = advance, .height = request.bounds.height}, key ? PaletteRole::accent : PaletteRole::subtext0, key);
    x += advance;

    return true;
  }

  inline void append(std::string_view text, Rect bounds, PaletteRole ink, bool bold) {
    auto &label = labels_[count_++];
    label.text.append(text);
    label.bounds = bounds;
    label.ink = ink;
    label.bold = bold;
  }

  Rect chip_;
  std::array<ModeBarLabel, maximum_labels> labels_{};
  std::size_t count_ = 0;
};

}
}

// Interface: presentation/workspace_mark.cppm
export {
namespace telar::gui {

struct WorkspaceMark {
  static constexpr auto hues = std::to_array<PaletteRole>({PaletteRole::red, PaletteRole::peach, PaletteRole::yellow, PaletteRole::green, PaletteRole::teal, PaletteRole::blue, PaletteRole::mauve});

  Utf8Scalar initial;
  PaletteRole hue = hues.front();

  [[nodiscard]] inline static WorkspaceMark resolve(std::string_view name) {
    WorkspaceMark mark;
    mark.hue = hues[hash(name) % hues.size()];
    if (name.empty()) {
      return mark;
    }

    const auto leading = std::countl_one(static_cast<std::uint8_t>(name.front()));
    const auto length = leading == 0 ? std::size_t{1} : static_cast<std::size_t>(leading);
    if (leading == 1 || length > mark.initial.bytes.size() || length > name.size()) {
      return mark;
    }

    try {
      const auto scalar = Utf8Scalar::decode(name.substr(0, length));
      const auto upper = scalar >= 'a' && scalar <= 'z' ? scalar - ('a' - 'A') : scalar;
      mark.initial = Utf8Scalar::encode(upper);
    } catch (const std::invalid_argument &) {
      return mark;
    }

    return mark;
  }

private:
  [[nodiscard]] inline static std::uint32_t hash(std::string_view name) noexcept {
    constexpr std::uint32_t offset_basis = 2166136261U;
    constexpr std::uint32_t prime = 16777619U;
    auto value = offset_basis;
    for (const auto byte : name) {
      value = (value ^ static_cast<unsigned char>(byte)) * prime;
    }

    return value;
  }
};

}
}
