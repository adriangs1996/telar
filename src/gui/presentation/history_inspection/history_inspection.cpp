module telar.gui.presentation.history_inspection;

import std;
import telar.tbc;
import telar.base.text.utf8;

namespace telar::gui {

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

  std::optional<std::chrono::year_month_day> HistoryLabels::calendar(std::int64_t day) noexcept {
    if (day < 0 || day > last_calendar_day) {
      return std::nullopt;
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

  std::string_view TabCaption::directoryName(std::string_view path) noexcept {
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
    if (inspectUtf8(path) != Utf8Validation::valid || std::ranges::any_of(path, [](char byte) {
          return static_cast<unsigned char>(byte) < ' ' || static_cast<unsigned char>(byte) == delete_control;
        })) {
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

  tbc::view<std::string_view, tbc::lt::a> TabCaption::resolve(tbc::view<Content, tbc::lt::a> content, tbc::view<Buffer&, tbc::lt::a> storage) noexcept {
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

  tbc::view<HistoryInspectionFacts, tbc::lt::a> HistoryInspectionFacts::derive(tbc::view<HistoryInspectionEntry, tbc::lt::a> entry, CalendarSample sampled) {
    HistoryInspectionFacts result;

    result.directory = entry.directory;
    result.took = HistoryLabels::duration(entry.duration_ns);
    result.describeWhen(entry, sampled);
    result.describeExit(entry);
    result.describePane(entry);
    result.describeAuthor(entry);

    return result;
  }

  auto HistoryInspectionFacts::lines() const noexcept -> std::array<HistoryInspectionLine, count> {
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
      constexpr std::array origins{std::string_view{"pane"}, std::string_view{"hook"}, std::string_view{"plugin"}};

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

  std::optional<HistoryInspectionLine> HistoryInspectionLines::next() noexcept {
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

  void ModeHints::append(tbc::view<ModeHint, tbc::lt::a> hint) noexcept {
    if (count_ < hints_.size()) {
      hints_[count_++] = hint;
    }
  }

  tbc::view<std::span<const ModeHint>, tbc::lt::a> ModeHints::items() const noexcept {
    return std::span{hints_}.first(count_);
  }

  auto ModeKeyLabel::format(KeyChord key) -> Text {
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

  std::string_view ModeKeyLabel::name(KeyChord::Key key) noexcept {
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

  ModeBarLabels ModeBarLabels::resolve(StatusMode mode, const ModeHints& hints) {
    ModeBarLabels result;

    switch (mode) {
    case StatusMode::normal:
      return result;
    case StatusMode::copy:
      result.title_ = "COPY";
      for (const auto& [key, word] : copy_hints) {
        result.append(key, word);
      }

      return result;
    case StatusMode::prefix:
      result.title_ = "PREFIX";
      result.append(cancel_key, cancel_word);
      for (const auto& item : hints.items()) {
        result.append(ModeKeyLabel::format(item.key).view(), item.label);
      }

      return result;
    }

    return result;
  }

  std::string_view ModeBarLabels::title() const noexcept {
    return title_;
  }

  std::span<const ModeBarHint> ModeBarLabels::hints() const noexcept {
    return std::span{hints_}.first(count_);
  }

  void ModeBarLabels::append(std::string_view key, std::string_view word) {
    auto& hint = hints_[count_++];

    hint.key.append(key);
    hint.word.append(word);
  }

  WorkspaceMark WorkspaceMark::resolve(std::string_view name) {
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
    } catch (const std::invalid_argument&) {
      return mark;
    }

    return mark;
  }

  std::uint32_t WorkspaceMark::hash(std::string_view name) noexcept {
    constexpr std::uint32_t offset_basis = 2166136261U;
    constexpr std::uint32_t prime = 16777619U;
    auto value = offset_basis;

    for (const auto byte : name) {
      value = (value ^ static_cast<unsigned char>(byte)) * prime;
    }

    return value;
  }

}
