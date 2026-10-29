#pragma once

#include "core/calendar_sample.hpp"
#include "core/theme_values.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "text/bounded_text.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <string_view>

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

  [[nodiscard]] static Text duration(std::int64_t nanoseconds) {
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

  [[nodiscard]] static Text age(std::int64_t milliseconds) {
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

  [[nodiscard]] static Text ageAt(std::int64_t started_ms, CalendarSample sampled) {
    if (sampled.now_ms < started_ms) {
      return age(0);
    }

    const auto elapsed = static_cast<std::uint64_t>(sampled.now_ms) - static_cast<std::uint64_t>(started_ms);

    return age(static_cast<std::int64_t>(std::min(elapsed, static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()))));
  }

  [[nodiscard]] static std::int64_t localDay(std::int64_t milliseconds, std::int16_t utc_offset_min) noexcept {
    return floorDivide(localSeconds(milliseconds, utc_offset_min), seconds_per_day);
  }

  [[nodiscard]] static Text clock(std::int64_t milliseconds, std::int16_t utc_offset_min) {
    const auto seconds = positiveRemainder(localSeconds(milliseconds, utc_offset_min), seconds_per_day);
    Text result;
    appendClockPart(result, static_cast<std::uint64_t>(seconds / seconds_per_hour));
    result.append(":");
    appendClockPart(result, static_cast<std::uint64_t>((seconds % seconds_per_hour) / seconds_per_minute));

    return result;
  }

  [[nodiscard]] static Text dayLabel(std::int64_t day, std::int64_t today) {
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

  [[nodiscard]] static Text dateLabel(std::int64_t milliseconds, CalendarSample sampled) {
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
  [[nodiscard]] static std::int64_t floorDivide(std::int64_t value, std::int64_t divisor) noexcept {
    return (value / divisor) - static_cast<std::int64_t>(value % divisor < 0);
  }

  [[nodiscard]] static std::int64_t positiveRemainder(std::int64_t value, std::int64_t divisor) noexcept {
    const auto remainder = value % divisor;

    return remainder < 0 ? remainder + divisor : remainder;
  }

  [[nodiscard]] static std::int64_t localSeconds(std::int64_t milliseconds, std::int16_t utc_offset_min) noexcept {
    return floorDivide(milliseconds, milliseconds_per_second) + (static_cast<std::int64_t>(utc_offset_min) * seconds_per_minute);
  }

  [[nodiscard]] static std::size_t weekday(std::int64_t day) noexcept {
    return static_cast<std::size_t>((positiveRemainder(day, days_per_week) + epoch_weekday) % days_per_week);
  }

  [[nodiscard]] static std::optional<std::chrono::year_month_day> calendar(std::int64_t day) noexcept {
    if (day < 0 || day > last_calendar_day) {
      return std::nullopt;
    }

    return std::chrono::year_month_day{std::chrono::sys_days{std::chrono::days{day}}};
  }

  static void appendClockPart(Text &text, std::uint64_t value) {
    constexpr unsigned decimal_base = 10;
    if (value < decimal_base) {
      text.append("0");
    }

    text.appendDecimal(value);
  }
};

}
