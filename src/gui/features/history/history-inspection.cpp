module telar.gui.features.history;

import std;

import telar.tbc;
import telar.gui.foundation.core;
import telar.gui.foundation.text;
import telar.base.ds;

namespace telar::gui::features::history {

  auto HistoryLabels::duration(std::int64_t nanoseconds) -> Text {
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

  auto HistoryLabels::age(std::int64_t milliseconds) -> Text {
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

  auto HistoryLabels::ageAt(std::int64_t started_ms, CalendarSample sampled) -> Text {
    if (sampled.now_ms < started_ms) {
      return age(0);
    }

    const auto elapsed = static_cast<std::uint64_t>(sampled.now_ms) - static_cast<std::uint64_t>(started_ms);

    return age(static_cast<std::int64_t>(std::min(elapsed, static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()))));
  }

  std::int64_t HistoryLabels::localDay(std::int64_t milliseconds, std::int16_t utc_offset_min) noexcept {
    return floorDivide(localSeconds(milliseconds, utc_offset_min), seconds_per_day);
  }

  std::int64_t HistoryLabels::dayEnd(CalendarSample sampled) noexcept {
    const auto midnight = ((localDay(sampled.now_ms, sampled.utc_offset_min) + 1) * seconds_per_day) - (std::int64_t{sampled.utc_offset_min} * seconds_per_minute);

    return midnight * milliseconds_per_second;
  }

  auto HistoryLabels::clock(std::int64_t milliseconds, std::int16_t utc_offset_min) -> Text {
    const auto seconds = positiveRemainder(localSeconds(milliseconds, utc_offset_min), seconds_per_day);
    Text result;

    appendClockPart(result, static_cast<std::uint64_t>(seconds / seconds_per_hour));
    result.append(":");
    appendClockPart(result, static_cast<std::uint64_t>((seconds % seconds_per_hour) / seconds_per_minute));

    return result;
  }

  auto HistoryLabels::dayLabel(std::int64_t day, std::int64_t today) -> Text {
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

  auto HistoryLabels::dateLabel(std::int64_t milliseconds, CalendarSample sampled) -> Text {
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

  std::int64_t HistoryLabels::floorDivide(std::int64_t value, std::int64_t divisor) noexcept {
    return (value / divisor) - static_cast<std::int64_t>(value % divisor < 0);
  }

  std::int64_t HistoryLabels::positiveRemainder(std::int64_t value, std::int64_t divisor) noexcept {
    const auto remainder = value % divisor;

    return remainder < 0 ? remainder + divisor : remainder;
  }

  std::int64_t HistoryLabels::localSeconds(std::int64_t milliseconds, std::int16_t utc_offset_min) noexcept {
    return floorDivide(milliseconds, milliseconds_per_second) + (static_cast<std::int64_t>(utc_offset_min) * seconds_per_minute);
  }

  std::size_t HistoryLabels::weekday(std::int64_t day) noexcept {
    return static_cast<std::size_t>((positiveRemainder(day, days_per_week) + epoch_weekday) % days_per_week);
  }

  ds::Option<std::chrono::year_month_day> HistoryLabels::calendar(std::int64_t day) noexcept {
    if (day < 0 || day > last_calendar_day) {
      return ds::none;
    }

    return std::chrono::year_month_day{std::chrono::sys_days{std::chrono::days{day}}};
  }

  void HistoryLabels::appendClockPart(Text& text, std::uint64_t value) {
    constexpr unsigned decimal_base = 10;
    if (value < decimal_base) {
      text.append("0");
    }

    text.appendDecimal(value);
  }

  tbc::val_a<HistoryInspectionFacts> HistoryInspectionFacts::derive(tbc::val_a<HistoryInspectionEntry> entry, CalendarSample sampled) {
    HistoryInspectionFacts result;

    result.directory = entry.directory;
    result.took = HistoryLabels::duration(entry.duration_ns);
    result.describeWhen(entry, sampled);
    result.describeExit(entry);
    result.describePane(entry);
    result.describeAuthor(entry);

    return result;
  }

  auto HistoryInspectionFacts::lines() const noexcept -> ds::Array<HistoryInspectionLine, count> {
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

  HistoryRunFacts HistoryRunFacts::derive(const HistoryRunStats& stats, CalendarSample sampled) {
    constexpr std::uint64_t percent = 100;
    HistoryRunFacts result;

    if (stats.runs == 0) {
      return result;
    }

    result.runs.appendDecimal(stats.runs);
    result.runs.append(stats.runs == 1 ? " run" : " runs");
    if (stats.measured != 0) {
      const auto most = static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max() / HistoryLabels::nanoseconds_per_millisecond);

      result.mean = HistoryLabels::duration(static_cast<std::int64_t>(std::min(stats.mean_duration_ms, most)) * HistoryLabels::nanoseconds_per_millisecond);
    }

    if (stats.ended != 0) {
      const auto rate = (std::min(stats.succeeded, stats.ended) * percent) / stats.ended;

      result.success.appendDecimal(rate);
      result.success.append("% of ");
      result.success.appendDecimal(stats.ended);
      result.success_color = stats.succeeded == stats.ended ? PaletteRole::green : PaletteRole::text;
    }

    // When the newest run started, and a tick when it succeeded or its status when it failed.
    result.last.append(HistoryLabels::ageAt(stats.last_started_ms, sampled).view());
    if (stats.last_exit) {
      result.last.append("  ");
      if (*stats.last_exit == 0) {
        result.last.append("✓");
        result.last_color = PaletteRole::green;
      } else {
        result.last.append("exit ");
        result.last.appendDecimal(static_cast<std::uint64_t>(static_cast<std::uint32_t>(*stats.last_exit)));
        result.last_color = PaletteRole::red;
      }
    }

    // Each day's bar rises with its runs against the busiest day's.
    const auto busiest = std::ranges::max(stats.per_day);

    for (const auto runs : stats.per_day) {
      result.per_day.append(runs == 0 ? "·" : bars[((std::uint64_t{runs} * bars.size()) - 1) / busiest]);
    }

    result.per_day.append("  ");
    result.per_day.appendDecimal(stats.per_day.view().back());
    result.per_day.append(" today");

    return result;
  }

  auto HistoryRunFacts::lines() const noexcept -> ds::Array<HistoryInspectionLine, count> {
    using Kind = HistoryInspectionLine::Kind;

    return {
        {
            {.kind = Kind::fact, .text = runs.view(), .label = "Runs"},
            {.kind = Kind::fact, .text = mean.view(), .label = "Mean"},
            {.kind = Kind::fact, .text = success.view(), .label = "Success", .color = success_color},
            {.kind = Kind::fact, .text = last.view(), .label = "Last", .color = last_color},
            {.kind = Kind::fact, .text = per_day.view(), .label = "Per day", .mono = true},
        },
    };
  }

  auto HistoryInspectionFacts::outputHeading(HistoryPhase phase, bool truncated, std::size_t bytes) -> BoundedText<text_capacity> {
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

  void HistoryInspectionFacts::describeWhen(const HistoryInspectionEntry& entry, CalendarSample sampled) {
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

  void HistoryInspectionFacts::describeExit(const HistoryInspectionEntry& entry) {
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

  void HistoryInspectionFacts::describePane(const HistoryInspectionEntry& entry) {
    pane.appendDecimal(entry.pane_id);
    pane.append(entry.pane_open ? "  ·  tab " : "  ·  closed");
    if (entry.pane_open) {
      pane.append(entry.tab);
    }
  }

  void HistoryInspectionFacts::describeAuthor(const HistoryInspectionEntry& entry) {
    if (entry.author == HistoryAuthor::human) {
      by.append("You");
    } else {
      by.append(entry.provider.empty() ? "agent" : entry.provider);
    }

    if (entry.author == HistoryAuthor::agent) {
      constexpr ds::Array origins{std::string_view{"pane"}, std::string_view{"hook"}, std::string_view{"plugin"}};

      by.append("  ·  ");
      by.append(origins.at(static_cast<std::size_t>(entry.origin)));
    }

    by.append("  ·  #");
    by.appendDecimal(entry.id);
  }

  HistoryInspectionLines::HistoryInspectionLines(HistoryInspectionDocument document, std::uint16_t columns) noexcept
      : facts_(document.facts),
        heading_(document.heading),
        output_(document.output),
        wrapped_(document.command, columns, true),
        columns_(columns) {}

  ds::Option<HistoryInspectionLine> HistoryInspectionLines::next() noexcept {
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
        return ds::none;
      }
    }
  }

  std::uint32_t HistoryInspectionLines::count() const noexcept {
    auto remaining = *this;
    std::uint32_t total = 0;

    while (remaining.next()) {
      ++total;
    }

    return total;
  }

  auto HistoryPath::compact(std::string_view path) -> Text {
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

  std::size_t HistoryPath::codepoints(std::string_view cluster) noexcept {
    std::size_t count = 0;

    for (const auto byte : cluster) {
      const auto value = static_cast<unsigned char>(byte);
      if ((value & utf8_prefix_mask) != Utf8Scalar::continuation_prefix) {
        ++count;
      }
    }

    return count;
  }

  std::size_t HistoryPath::tailStart(std::string_view text, Limits limits) noexcept {
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

  void HistoryPath::append(Text& destination, std::string_view path) {
    GraphemeCursor cursor{path};

    while (const auto cluster = cursor.nextReplacingInvalid()) {
      destination.append(*cluster);
    }
  }

  auto HistoryPath::copy(std::string_view path) -> Text {
    Text result;

    append(result, path);

    return result;
  }

  HistoryModalGeometry HistoryModalGeometry::measure(const HistoryModalMetrics& metrics, bool inspecting) noexcept {
    const auto& chrome = metrics.chrome;
    const auto viewport = metrics.viewport;
    const auto inset = std::min(chrome.px(margin), std::min(viewport.width, viewport.height) / margin_divisor);
    const auto width = std::max(0.0F, std::min(chrome.px(maximum_width), viewport.width - (inset * 2)));
    const auto line_height = std::max(ChromeMetrics::lineHeight(chrome.body), metrics.cell_height);
    const auto row_height = std::max(chrome.px(row_minimum), line_height + chrome.px(row_padding));
    const auto group_height = std::max(chrome.px(group_minimum), ChromeMetrics::lineHeight(chrome.small) + chrome.px(group_padding));
    const auto header_height = std::max(chrome.px(header_minimum), ChromeMetrics::lineHeight(chrome.small) + chrome.px(header_padding));
    const auto search_height = std::max(chrome.px(search_minimum), line_height + chrome.px(search_padding));
    const auto footer_height = std::max(chrome.px(footer_minimum), ChromeMetrics::lineHeight(chrome.small) + chrome.px(footer_padding));
    const auto available = viewport.height - chrome.status_bar - (inset * 2);
    const auto height = std::max(0.0F, std::min(available, std::max(chrome.px(minimum_height), viewport.height * height_share)));
    const Rect bounds{
        .x = std::floor((viewport.width - width) / 2),
        .y = std::floor(std::max(0.0F, std::min(viewport.height - height, viewport.height - chrome.status_bar - inset - height))),
        .width = width,
        .height = height,
    };

    const auto compact = width < chrome.px(compact_width) || height < chrome.px(compact_height);
    auto content = bounds;
    const auto footer = takeBottom(content, footer_height);
    const auto search = takeBottom(content, search_height);
    const auto header = takeTop(content, compact ? 0 : header_height);
    auto list = content;
    Rect inspection{.x = content.x, .y = content.y};

    if (inspecting) {
      inspection = content;
      if (width >= chrome.px(split_width)) {
        list.width = std::floor(content.width * list_share);
        inspection.x = list.x + list.width;
        inspection.width = std::max(0.0F, content.width - list.width);
      } else {
        list.width = 0;
      }
    }

    return {.viewport = viewport, .bounds = bounds, .header = header, .results = list, .inspection = inspection, .search = search, .footer = footer, .row_height = row_height, .group_height = group_height, .compact = compact};
  }

  void HistoryModalGeometry::offsetY(float offset) noexcept {
    for (auto* area : {&bounds, &header, &results, &inspection, &search, &footer}) {
      area->y += offset;
    }
  }

  Rect HistoryModalGeometry::inspectionContent(const ChromeMetrics& chrome) const noexcept {
    const auto inset = inspectionInset(chrome);
    const auto actions = inspectionActions(chrome);

    return {.x = inspection.x + inset, .y = inspection.y + inset, .width = std::max(0.0F, inspection.width - (inset * 2)), .height = std::max(0.0F, actions.y - inspection.y - (inset * 2))};
  }

  Rect HistoryModalGeometry::inspectionActions(const ChromeMetrics& chrome) const noexcept {
    const auto inset = inspectionInset(chrome);
    const auto height = std::min(std::max(chrome.px(action_minimum), ChromeMetrics::lineHeight(chrome.body) + chrome.px(action_padding)), std::max(0.0F, inspection.height - (inset * 2)));

    return {.x = inspection.x + inset, .y = inspection.y + inspection.height - inset - height, .width = std::max(0.0F, inspection.width - (inset * 2)), .height = height};
  }

  float HistoryModalGeometry::inspectionInset(const ChromeMetrics& chrome) const noexcept {
    return std::min(chrome.px(inspection_inset), std::min(inspection.width, inspection.height) / inspection_inset_divisor);
  }

  Rect HistoryModalGeometry::takeBottom(Rect& remaining, float height) noexcept {
    const auto taken = std::min(remaining.height, height);

    remaining.height -= taken;

    return {.x = remaining.x, .y = remaining.y + remaining.height, .width = remaining.width, .height = taken};
  }

  Rect HistoryModalGeometry::takeTop(Rect& remaining, float height) noexcept {
    const auto taken = std::min(remaining.height, height);
    const Rect top{.x = remaining.x, .y = remaining.y, .width = remaining.width, .height = taken};

    remaining.y += taken;
    remaining.height -= taken;

    return top;
  }

  HistoryInspectionGeometry HistoryInspectionGeometry::derive(Rect area, ChromeMetrics chrome, Point cell) noexcept {
    HistoryModalGeometry modal{};

    modal.inspection = area;
    const auto content = modal.inspectionContent(chrome);
    const auto bounded = [](float value) {
      return static_cast<std::uint16_t>(std::clamp(std::floor(value), 0.0F, static_cast<float>(std::numeric_limits<std::uint16_t>::max())));
    };

    return {.content = content, .actions = modal.inspectionActions(chrome), .columns = bounded(content.width / std::max(1.0F, cell.x)), .rows = cell.y > 0 ? bounded(content.height / cell.y) : std::uint16_t{0}, .row_height = cell.y, .label_width = std::min(chrome.px(fact_label_width), content.width / fact_label_divisor), .command_inset = chrome.px(command_padding)};
  }

  Rect HistoryInspectionGeometry::row(std::size_t index) const noexcept {
    return {.x = content.x, .y = content.y + (static_cast<float>(index) * row_height), .width = content.width, .height = row_height};
  }

  Rect HistoryInspectionGeometry::text(Rect row, HistoryInspectionLine::Kind kind) const noexcept {
    if (kind == HistoryInspectionLine::Kind::command) {
      return {.x = row.x + command_inset, .y = row.y, .width = std::max(0.0F, row.width - (command_inset * 2)), .height = row.height};
    }

    if (kind == HistoryInspectionLine::Kind::fact) {
      return {.x = row.x + label_width, .y = row.y, .width = std::max(0.0F, row.width - label_width), .height = row.height};
    }

    return row;
  }

  auto HistoryInspectionGeometry::buttons(std::span<const float> advances, ChromeMetrics chrome) const noexcept -> ds::Array<Rect, maximum_actions> {
    ds::Array<Rect, maximum_actions> result{};
    auto x = actions.x;

    for (std::size_t index = 0; index < std::min(advances.size(), result.size()); ++index) {
      const auto width = advances[index] + chrome.px(button_padding);
      if (x + width > actions.right()) {
        break;
      }

      result.atMut(index) = {.x = x, .y = actions.y, .width = width, .height = actions.height};
      x += width + chrome.px(button_gap);
    }

    return result;
  }

}
