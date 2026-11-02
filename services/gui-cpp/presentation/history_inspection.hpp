#pragma once

#include "core/calendar_sample.hpp"
#include "core/theme_values.hpp"
#include "history/entry.hpp"
#include "presentation/history_labels.hpp"
#include "presentation/tab_caption.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "text/bounded_text.hpp"
#include "text/wrapped_lines.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <string_view>

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

  [[nodiscard]] static HistoryInspectionFacts derive(const HistoryInspectionEntry &entry, CalendarSample sampled) {
    HistoryInspectionFacts result;
    result.directory = entry.directory;
    result.took = HistoryLabels::duration(entry.duration_ns);
    result.describeWhen(entry, sampled);
    result.describeExit(entry);
    result.describePane(entry);
    result.describeAuthor(entry);

    return result;
  }

  [[nodiscard]] std::array<HistoryInspectionLine, count> lines() const noexcept {
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

  [[nodiscard]] static BoundedText<text_capacity> outputHeading(HistoryPhase phase, bool truncated, std::size_t bytes) {
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
  void describeWhen(const HistoryInspectionEntry &entry, CalendarSample sampled) {
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

  void describeExit(const HistoryInspectionEntry &entry) {
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

  void describePane(const HistoryInspectionEntry &entry) {
    pane.appendDecimal(entry.pane_id);
    pane.append(entry.pane_open ? "  ·  tab " : "  ·  closed");
    if (entry.pane_open) {
      pane.append(entry.tab);
    }
  }

  void describeAuthor(const HistoryInspectionEntry &entry) {
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
  HistoryInspectionLines(HistoryInspectionDocument document, std::uint16_t columns) noexcept
      : facts_(document.facts),
        heading_(document.heading),
        output_(document.output),
        wrapped_(document.command, columns, true),
        columns_(columns) {}

  [[nodiscard]] std::optional<HistoryInspectionLine> next() noexcept {
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

  [[nodiscard]] std::uint32_t count() const noexcept {
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
