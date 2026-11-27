module telar.gui.features.history;

import std;

import telar.gui.foundation.core;
import telar.wire.history;
import telar.wire.vocabulary;
import telar.base.ds;
import telar.tbc;

namespace telar::gui::features::history {

  namespace {

    constexpr std::int64_t milliseconds_per_minute = 60'000;
    constexpr std::int64_t milliseconds_per_hour = 60 * milliseconds_per_minute;
    constexpr std::int64_t milliseconds_per_day = 24 * milliseconds_per_hour;
    constexpr std::int64_t nanoseconds_per_millisecond = 1'000'000;
    constexpr std::int64_t days_per_week = 7;
    // A hundred years back is as far as a filter reaches.
    constexpr std::int64_t farthest = std::int64_t{100} * 366 * milliseconds_per_day;

    // A decimal count no larger than `limit`; none for an empty, signed or larger one.
    ds::Option<std::int64_t> count(std::string_view digits, std::int64_t limit) noexcept {
      constexpr std::int64_t base = 10;
      std::int64_t value = 0;

      if (digits.empty()) {
        return {};
      }

      for (const auto digit : digits) {
        const std::int64_t units = digit - '0';

        // A digit past the limit is checked apart: the quotient of a negative would round to 0.
        if (digit < '0' || digit > '9' || units > limit || value > (limit - units) / base) {
          return {};
        }

        value = (value * base) + units;
      }

      return value;
    }

    // The local midnight that starts `day`, a count of local days since the epoch.
    std::int64_t midnight(std::int64_t day, std::int16_t utc_offset_min) noexcept {
      return (day * milliseconds_per_day) - (std::int64_t{utc_offset_min} * milliseconds_per_minute);
    }

    std::int64_t localDay(std::int64_t milliseconds, std::int16_t utc_offset_min) noexcept {
      const auto local = milliseconds + (std::int64_t{utc_offset_min} * milliseconds_per_minute);

      return local >= 0 ? local / milliseconds_per_day : ((local + 1) / milliseconds_per_day) - 1;
    }

    bool oneOf(std::string_view value, std::initializer_list<std::string_view> words) noexcept {
      return std::ranges::find(words, value) != words.end();
    }

    // The mode a typed word names, in the words the CLI's --mode and the configuration's fts read
    // too.
    ds::Option<HistoryMatch> modeNamed(std::string_view word) noexcept {
      if (oneOf(word, {"sub", "fts"})) {
        return HistoryMatch::substring;
      }

      if (word == "re") {
        return HistoryMatch::regex;
      }

      return HistoryModes::named(word);
    }

  }

  std::string_view HistoryFilterKeys::name(HistoryFilterKey key) noexcept {
    const auto index = static_cast<std::size_t>(key);

    return index < names.size() ? names[index] : std::string_view{};
  }

  ds::Option<HistoryFilterKey> HistoryFilterKeys::named(std::string_view name) noexcept {
    for (std::size_t index = 0; index < names.size(); ++index) {
      if (names[index] == name) {
        return static_cast<HistoryFilterKey>(index);
      }
    }

    return {};
  }

  ds::Option<HistoryFilterKey> HistoryFilterKeys::completing(std::string_view word) noexcept {
    if (word.empty() || word.contains(':')) {
      return {};
    }

    std::size_t begun = 0;
    std::size_t last = 0;

    for (std::size_t index = 0; index < names.size(); ++index) {
      if (names[index].starts_with(word)) {
        ++begun;
        last = index;
      }
    }

    if (begun != 1) {
      return {};
    }

    return static_cast<HistoryFilterKey>(last);
  }

  bool HistoryFilterKeys::applied(const HistoryChip& chip) {
    if (chip.key != HistoryFilterKey::took) {
      return true;
    }

    const auto duration = HistoryDurationFilter::parse(chip.value.view());

    return duration && duration->longer;
  }

  ds::Option<HistoryDurationFilter> HistoryDurationFilter::parse(std::string_view value) {
    HistoryDurationFilter result;

    if (value.starts_with('>') || value.starts_with('<')) {
      result.longer = value.front() == '>';
      value.remove_prefix(1);
    }

    struct Unit {
      std::string_view suffix;
      std::int64_t nanoseconds;
    };

    // The longest suffix first: `ms` before `s`.
    constexpr ds::Array units{
        Unit{.suffix = "ms", .nanoseconds = nanoseconds_per_millisecond},
        Unit{.suffix = "s", .nanoseconds = 1000 * nanoseconds_per_millisecond},
        Unit{.suffix = "m", .nanoseconds = milliseconds_per_minute * nanoseconds_per_millisecond},
        Unit{.suffix = "h", .nanoseconds = milliseconds_per_hour * nanoseconds_per_millisecond},
    };

    for (const auto& unit : units) {
      if (!value.ends_with(unit.suffix)) {
        continue;
      }

      const auto amount = count(value.substr(0, value.size() - unit.suffix.size()), std::numeric_limits<std::int64_t>::max() / unit.nanoseconds);
      if (!amount) {
        return {};
      }

      result.nanoseconds = *amount * unit.nanoseconds;
      return result;
    }

    return {};
  }

  ds::Option<std::int64_t> HistorySince::resolve(std::string_view value, CalendarSample sampled) {
    const auto today = localDay(sampled.now_ms, sampled.utc_offset_min);

    if (value == "today") {
      return midnight(today, sampled.utc_offset_min);
    }

    if (value == "yesterday") {
      return midnight(today - 1, sampled.utc_offset_min);
    }

    if (value.starts_with('-') && value.size() > 2) {
      struct Unit {
        char suffix;
        std::int64_t milliseconds;
      };

      constexpr ds::Array units{
          Unit{.suffix = 'm', .milliseconds = milliseconds_per_minute},
          Unit{.suffix = 'h', .milliseconds = milliseconds_per_hour},
          Unit{.suffix = 'd', .milliseconds = milliseconds_per_day},
          Unit{.suffix = 'w', .milliseconds = days_per_week * milliseconds_per_day},
      };

      for (const auto& unit : units) {
        if (value.back() != unit.suffix) {
          continue;
        }

        const auto amount = count(value.substr(1, value.size() - 2), farthest / unit.milliseconds);

        return amount ? ds::Option{sampled.now_ms - (*amount * unit.milliseconds)} : ds::none;
      }

      return {};
    }

    // A date, as ISO 8601 writes it: its month and its day follow a dash each.
    constexpr std::string_view sample = "2026-11-01";
    constexpr auto month_dash = sample.find('-');
    constexpr auto day_dash = sample.rfind('-');

    if (value.size() != sample.size() || value[month_dash] != '-' || value[day_dash] != '-') {
      return {};
    }

    constexpr std::int64_t last_year = 9999;
    constexpr std::int64_t last_month = 12;
    constexpr std::int64_t last_day = 31;
    const auto year = count(value.substr(0, month_dash), last_year);
    const auto month = count(value.substr(month_dash + 1, day_dash - month_dash - 1), last_month);
    const auto day = count(value.substr(day_dash + 1), last_day);
    if (!year || !month || !day) {
      return {};
    }

    const std::chrono::year_month_day date{std::chrono::year{static_cast<int>(*year)}, std::chrono::month{static_cast<unsigned>(*month)}, std::chrono::day{static_cast<unsigned>(*day)}};
    if (!date.ok()) {
      return {};
    }

    return midnight(std::chrono::sys_days{date}.time_since_epoch().count(), sampled.utc_offset_min);
  }

  bool HistoryTyping::apply(HistoryFilters& filters, HistoryFilterKey key, std::string_view value) {
    // Exit codes run from 0 to 255.
    constexpr std::int64_t last_exit_code = 255;

    switch (key) {
    case HistoryFilterKey::exit:
      if (oneOf(value, {"fail", "failed", "error"})) {
        filters.failed_only = true;
        return true;
      }

      if (oneOf(value, {"ok", "success"})) {
        return filters.chips.set(key, "0");
      }

      return count(value, last_exit_code) && filters.chips.set(key, value);
    case HistoryFilterKey::by:
      if (oneOf(value, {"you", "me", "human"})) {
        filters.author = HistoryAuthorFilter::human;
      } else if (oneOf(value, {"agent", "agents", "ai"})) {
        filters.author = HistoryAuthorFilter::agent;
      } else if (oneOf(value, {"all", "any", "both"})) {
        filters.author = HistoryAuthorFilter::all;
      } else {
        return false;
      }

      return true;
    case HistoryFilterKey::since:
    case HistoryFilterKey::until:
      return HistorySince::resolve(value, {}).hasValue() && filters.chips.set(key, value);
    case HistoryFilterKey::took:
      return HistoryDurationFilter::parse(value).hasValue() && filters.chips.set(key, value);
    case HistoryFilterKey::sort:
      return oneOf(value, {"rank", "time"}) && filters.chips.set(key, value);
    case HistoryFilterKey::output:
      return oneOf(value, {"output", "out"}) && filters.chips.set(key, "output");
    case HistoryFilterKey::mode: {
      const auto mode = modeNamed(value);

      return mode && filters.chips.set(key, HistoryModes::name(*mode));
    }
    case HistoryFilterKey::raw: {
      const auto neighbours = count(value, QueryHistory::maximum_neighbours);

      return neighbours && *neighbours != 0 && filters.chips.set(key, value);
    }
    case HistoryFilterKey::cwd:
    case HistoryFilterKey::workspace:
    case HistoryFilterKey::host:
    case HistoryFilterKey::branch:
    case HistoryFilterKey::shell:
      return filters.chips.set(key, value);
    }

    return false;
  }

  bool HistoryTyping::absorb(std::string_view text, HistoryFilters& filters, Query& query) {
    bool applied = false;

    query.truncate(0);
    while (!text.empty()) {
      const auto end = text.find(' ');
      // Only a word a blank ends is complete: the last one may still be typed.
      const auto word = text.substr(0, end);
      const auto colon = word.find(':');
      const auto key = end == std::string_view::npos || colon == std::string_view::npos ? ds::none : HistoryFilterKeys::named(word.substr(0, colon));

      if (key && apply(filters, *key, word.substr(colon + 1))) {
        applied = true;
      } else {
        query.append(text.substr(0, end == std::string_view::npos ? text.size() : end + 1));
      }

      text.remove_prefix(end == std::string_view::npos ? text.size() : end + 1);
    }

    return applied;
  }

  void HistoryTyping::narrow(tbc::mut_a<QueryHistory> request, tbc::ref_a<HistoryChips> chips, CalendarSample sampled) {
    // Typing checked each chip's value, so each reads.
    if (const auto exit = chips.value(HistoryFilterKey::exit)) {
      request.exit_code = static_cast<std::int32_t>(count(*exit, std::numeric_limits<std::int32_t>::max()).valueOr(0));
    }

    if (const auto since = chips.value(HistoryFilterKey::since)) {
      request.since_ms = HistorySince::resolve(*since, sampled).valueOr(0);
    }

    if (const auto until = chips.value(HistoryFilterKey::until)) {
      request.until_ms = HistorySince::resolve(*until, sampled).valueOr(0);
    }

    // The runtime reads a least duration only: `took:<5s` filters nothing.
    if (const auto took = chips.value(HistoryFilterKey::took)) {
      if (const auto duration = HistoryDurationFilter::parse(*took); duration && duration->longer) {
        request.min_duration_ms = static_cast<std::uint64_t>(duration->nanoseconds / nanoseconds_per_millisecond);
      }
    }

    request.host = chips.value(HistoryFilterKey::host).valueOr(std::string_view{});
    request.branch = chips.value(HistoryFilterKey::branch).valueOr(std::string_view{});
    request.shell = chips.value(HistoryFilterKey::shell).valueOr(std::string_view{});
    if (const auto sort = chips.value(HistoryFilterKey::sort)) {
      request.sort = *sort == "time" ? HistorySort::time : HistorySort::rank;
    }

    if (const auto mode = chips.value(HistoryFilterKey::mode)) {
      request.match = HistoryModes::named(*mode).valueOr(request.match);
    }

    // What each run printed: every run is listed, not each command once.
    if (chips.value(HistoryFilterKey::output)) {
      request.output = true;
      request.distinct = false;
    }

    // The runs around each match, in the order they ran, each run listed.
    if (const auto raw = chips.value(HistoryFilterKey::raw)) {
      request.neighbours = static_cast<std::uint8_t>(count(*raw, QueryHistory::maximum_neighbours).valueOr(0));
      request.distinct = false;
      request.sort = HistorySort::time;
    }
  }

  ds::Option<HistoryTyping::Query> HistoryTyping::complete(std::string_view text) {
    const auto start = text.rfind(' ') == std::string_view::npos ? 0 : text.rfind(' ') + 1;
    const auto key = HistoryFilterKeys::completing(text.substr(start));
    if (!key) {
      return {};
    }

    const auto name = HistoryFilterKeys::name(*key);
    Query result;

    if (start + name.size() + 1 > HistoryLimits::maximum_query_bytes) {
      return {};
    }

    result.append(text.substr(0, start));
    result.append(name);
    result.append(":");

    return result;
  }

}
