module telar.runtime.agents.screen_inference;

import std;
import telar.tbc;
import telar.config.core;
import telar.base.text;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // UTF-8: a lead byte below 0x80 stands alone, below 0xe0 leads two bytes, below 0xf0 three, else
    // four; each continuation byte carries six bits.
    constexpr Byte single_end = 0x80;
    constexpr Byte pair_end = 0xe0;
    constexpr Byte triple_end = 0xf0;
    constexpr unsigned lead_payload = 0x7f;
    constexpr unsigned continuation_payload = 0x3f;
    constexpr unsigned continuation_bits = 6;

    // The codepoints the screen readers look for.
    constexpr std::uint32_t no_break_space = 0x00a0;
    constexpr std::uint32_t bullet = 0x2022;
    constexpr std::uint32_t codex_prompt = 0x203a;
    constexpr std::uint32_t cursor_prompt = 0x2192;
    constexpr std::uint32_t box_horizontal = 0x2500;
    constexpr std::uint32_t braille_first = 0x2800;
    constexpr std::uint32_t braille_last = 0x28ff;

    unsigned sequenceLength(Byte first) noexcept {
      if (first < single_end) {
        return 1;
      }

      if (first < pair_end) {
        return 2;
      }

      return first < triple_end ? 3 : 4;
    }

    bool blank(std::uint32_t codepoint) noexcept {
      return codepoint == 0 || codepoint == ' ' || codepoint == no_break_space;
    }

    bool braille(std::uint32_t codepoint) noexcept {
      return codepoint >= braille_first && codepoint <= braille_last;
    }

    // The column of the first cell that is not blank, or the row's width.
    std::size_t firstVisible(std::span<const ScreenCell> cells) noexcept {
      std::size_t column = 0;

      while (column < cells.size() && blank(cellCodepoint(cells[column]))) {
        ++column;
      }

      return column;
    }

    // A draft Claude restored shows at full intensity; its placeholder is faint.
    bool restoredDraft(std::span<const ScreenCell> input) noexcept {
      return std::ranges::any_of(input, [](const auto& cell) {
        return !blank(cellCodepoint(cell)) && (cell.style.flags & static_cast<unsigned>(CellAttribute::faint)) == 0;
      });
    }

    bool softwareCursor(std::span<const ScreenCell> input) noexcept {
      return std::ranges::any_of(input, [](const auto& cell) {
        return (cell.style.flags & static_cast<unsigned>(CellAttribute::inverse)) != 0 || cell.style.background.kind != CellColor::Kind::default_color;
      });
    }

    std::string_view resumeOption(AgentProvider provider) noexcept {
      if (provider == AgentProvider::codex) {
        return "resume";
      }

      return provider == AgentProvider::pi || provider == AgentProvider::opencode ? "--session" : "--resume";
    }

    // A row without the blank cells at its end.
    std::span<const ScreenCell> trimmedCells(std::span<const ScreenCell> cells) noexcept {
      while (!cells.empty() && (cells.back().length == 0 || (cells.back().length == 1 && cells.back().text[0] == ' '))) {
        cells = cells.first(cells.size() - 1);
      }

      return cells;
    }

    // The bytes of a cell's first codepoint, or a space for an empty cell.
    std::string_view cellText(const ScreenCell& cell) noexcept {
      if (cell.length == 0) {
        return " ";
      }

      return textView(cell.text.view().first(std::min<std::size_t>(sequenceLength(cell.text[0]), cell.length)));
    }

  }

  bool PromptBudget::spend(std::uint64_t sender, std::uint64_t target, std::chrono::steady_clock::time_point now) noexcept {
    const auto pairs = pairs_.viewMut();
    auto entry = std::ranges::find_if(pairs, [&](const Pair& pair) {
      return pair.sender == sender && pair.target == target;
    });
    if (entry == pairs.end()) {
      entry = std::ranges::min_element(pairs, {}, &Pair::started);
      *entry = Pair{.sender = sender, .target = target, .started = now, .count = 0};
    }

    if (now - entry->started >= window) {
      entry->started = now;
      entry->count = 0;
    }

    if (entry->count == prompts_per_window) {
      return false;
    }

    ++entry->count;
    return true;
  }

  bool hexadecimal(char value) noexcept {
    return (value >= '0' && value <= '9') || (value >= 'a' && value <= 'f') || (value >= 'A' && value <= 'F');
  }

  bool validResumeSession(AgentProvider provider, std::string_view value) noexcept {
    // An opencode session is ses_, twelve hexadecimal digits and fourteen alphanumerics; the others are UUIDs.
    constexpr std::size_t opencode_session_length = 30;
    constexpr std::size_t opencode_hexadecimal_end = 16;
    constexpr std::size_t uuid_length = 36;

    if (provider == AgentProvider::opencode) {
      if (value.size() != opencode_session_length || !value.starts_with("ses_")) {
        return false;
      }

      for (std::size_t index = 4; index < value.size(); ++index) {
        const auto character = value[index];
        const bool valid = index < opencode_hexadecimal_end ? hexadecimal(character) : (character >= '0' && character <= '9') || (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z');
        if (!valid) {
          return false;
        }
      }

      return true;
    }

    if (describeProvider(provider).name.empty() || value.size() != uuid_length) {
      return false;
    }

    for (std::size_t index = 0; index < value.size(); ++index) {
      const bool separator = index == 8 || index == 13 || index == 18 || index == 23;
      if (separator ? value[index] != '-' : !hexadecimal(value[index])) {
        return false;
      }
    }

    return true;
  }

  tbc::val_a<std::span<const std::string_view>> resumeArguments(tbc::ref_a<AgentResume> resume, tbc::mut_a<ds::Array<std::string_view, 4>> arguments) noexcept {
    if (!validResumeSession(resume.provider, resume.session.view())) {
      return {};
    }

    arguments.atMut(0) = resume.provider == AgentProvider::cursor ? "cursor-agent" : describeProvider(resume.provider).name;
    arguments.atMut(1) = resumeOption(resume.provider);
    std::size_t count = 2;

    if (resume.provider == AgentProvider::codex && resume.in_pane) {
      arguments.atMut(count++) = "--no-daemon";
    }

    arguments.atMut(count++) = resume.session.view();

    return std::span{arguments}.first(count);
  }

  std::uint32_t cellCodepoint(const ScreenCell& cell) noexcept {
    if (cell.length == 0) {
      return 0;
    }

    const auto first = cell.text[0];
    if (first < single_end) {
      return first;
    }

    const auto length = sequenceLength(first);
    if (length > cell.length) {
      return 0;
    }

    std::uint32_t value = first & (lead_payload >> length);

    for (unsigned index = 1; index < length; ++index) {
      value = (value << continuation_bits) | (cell.text[index] & continuation_payload);
    }

    return value;
  }

  std::string_view AgentScreenRow::text() const noexcept {
    const std::string_view value{bytes.data(), length};
    const auto start = value.find_first_not_of(' ');
    if (start == std::string_view::npos) {
      return {};
    }

    return textPrefix(textAfter(value, start), value.find_last_not_of(' ') - start + 1);
  }

  AgentScreenView agentScreenView(const Screen& screen) noexcept {
    return AgentScreenView{
        .cells = std::span{screen.cells},
        .row_flags = std::span{screen.row_flags},
        .cols = screen.cols,
        .rows = screen.rows,
        .cursor = screen.cursor,
    };
  }

  AgentScreenReader::AgentScreenReader(const Terminal& terminal, const AgentManifests& manifests)
      : AgentScreenReader(agentScreenView(terminal.screen()), terminal.effects().title(), manifests) {}

  AgentScreenReader::AgentScreenReader(AgentScreenView screen, std::string_view title, const AgentManifests& manifests) noexcept
      : screen_(screen),
        title_(title),
        manifests_(manifests) {}

  AgentScreenObservation AgentScreenReader::observe(AgentProvider provider) const noexcept {
    switch (provider) {
    case AgentProvider::claude:
      return claude();
    case AgentProvider::codex:
      return codex();
    case AgentProvider::cursor:
      return cursor();
    case AgentProvider::unknown:
    case AgentProvider::pi:
    case AgentProvider::opencode:
    case AgentProvider::last_custom:
      return {};
    }

    // A custom provider, whose screen no reader knows.
    return {};
  }

  ds::Option<AgentSignal> AgentScreenReader::signal(AgentProvider provider) const noexcept {
    constexpr Byte claude_confidence = 96;
    constexpr Byte screen_confidence = 94;
    const auto observation = observe(provider);
    if (!observation.status || (provider == AgentProvider::claude && observation.status == AgentStatus::working)) {
      return ds::none;
    }

    return AgentSignal{.provider = provider, .status = *observation.status, .confidence = provider == AgentProvider::claude ? claude_confidence : screen_confidence, .identity_confirmed = observation.identity_confirmed, .ready_confirmed = observation.status == AgentStatus::ready};
  }

  std::span<const ScreenCell> AgentScreenReader::rowCells(std::size_t row) const noexcept {
    return screen_.cells.subspan(row * screen_.cols, screen_.cols);
  }

  AgentScreenRow AgentScreenReader::row(std::size_t index) const noexcept {
    AgentScreenRow result;
    const auto cells = rowCells(index);

    for (std::size_t column = 0; column < cells.size(); ++column) {
      const auto codepoint = cellCodepoint(cells[column]);
      if (result.first == 0 && codepoint != 0 && codepoint != ' ') {
        result.first = codepoint;
        result.column = column;
      }

      if (result.length == result.bytes.size()) {
        break;
      }

      result.bytes.atMut(result.length++) = codepoint > 0 && codepoint < single_end ? static_cast<char>(codepoint) : ' ';
    }

    return result;
  }

  AgentScreenObservation AgentScreenReader::claude() const noexcept {
    constexpr unsigned prompt_rows = 12;

    if (title_.starts_with("◐") || title_.starts_with("◑")) {
      return {.status = AgentStatus::working};
    }

    AgentScreenObservation result;
    bool observed_lowest_prompt = false;
    const auto first = screen_.rows - std::min<unsigned>(screen_.rows, prompt_rows);

    for (std::size_t screen_row = screen_.rows; screen_row-- > first;) {
      const auto cells = rowCells(screen_row);
      const auto prompt = firstVisible(cells);
      if (prompt == cells.size() || cellCodepoint(cells[prompt]) != claude_prompt) {
        continue;
      }

      const auto input = cells.subspan(prompt + 1);

      if (!observed_lowest_prompt && title_.starts_with("✳")) {
        result.restored_draft = restoredDraft(input);
      }

      observed_lowest_prompt = true;
      if (!screen_.cursor.visible && softwareCursor(input)) {
        result.status = AgentStatus::ready;
      }

      if (screen_.cursor.visible || result.status) {
        break;
      }
    }

    if (cursorAtClaudePrompt()) {
      result.status = AgentStatus::ready;
    }

    return result;
  }

  bool AgentScreenReader::cursorAtClaudePrompt() const noexcept {
    // How many cells left of the cursor the prompt may sit.
    constexpr unsigned prompt_reach = 8;

    if (!screen_.cursor.visible || screen_.cursor.y >= screen_.rows) {
      return false;
    }

    const auto cells = rowCells(screen_.cursor.y);
    std::size_t column = std::min<std::size_t>(static_cast<std::size_t>(screen_.cursor.x) + 1, cells.size());

    for (unsigned distance = 0; column != 0 && distance < prompt_reach; ++distance) {
      const auto codepoint = cellCodepoint(cells[--column]);
      if (!blank(codepoint)) {
        return codepoint == claude_prompt;
      }
    }

    return false;
  }

  bool AgentScreenReader::codexStatus(const AgentScreenRow& row) noexcept {
    const auto line = row.text();
    const auto open = line.find('(');
    if (open == std::string_view::npos) {
      return false;
    }

    const auto prefix = textPrefix(line, open);
    const auto heading = textPrefix(prefix, prefix.find_last_not_of(' ') + 1);
    const bool spinner = row.first == bullet || braille(row.first);
    if (!spinner && heading != "Working" && heading != "Thinking" && heading != "Reconnecting" && heading != "Compacting") {
      return false;
    }

    const auto clock = textAfter(line, open + 1);
    const auto digits = clock.find_first_not_of("0123456789");

    return digits != 0 && digits != std::string_view::npos && (clock[digits] == 's' || clock[digits] == 'm' || clock[digits] == 'h');
  }

  AgentScreenObservation AgentScreenReader::codex() const noexcept {
    constexpr unsigned composer_rows = 32;
    const auto* manifest = manifests_.find(AgentProvider::codex);
    if (manifest == nullptr) {
      return {};
    }

    const auto first = screen_.rows - std::min<unsigned>(screen_.rows, composer_rows);

    for (std::size_t screen_row = screen_.rows; screen_row-- > first;) {
      const auto composer = row(screen_row);
      if (composer.first != codex_prompt || composer.column > 1) {
        continue;
      }

      const bool identified = manifest->ready_prompt.matches(composer.text());

      for (std::size_t above = screen_row; above-- > first;) {
        const auto line = row(above);
        if (line.first == box_horizontal) {
          break;
        }

        if (codexStatus(line)) {
          return {.status = AgentStatus::working, .restored_draft = false, .identity_confirmed = identified};
        }
      }

      if (!screen_.cursor.visible || screen_.cursor.y < screen_row || screen_.cursor.x < composer.column + 2) {
        return {};
      }

      for (std::size_t continuation = screen_row + 1; continuation <= screen_.cursor.y; ++continuation) {
        const auto line = row(continuation);
        if (line.first != 0 && line.column < composer.column + 2) {
          return {};
        }
      }

      return {.status = AgentStatus::ready, .restored_draft = false, .identity_confirmed = identified};
    }

    return {};
  }

  AgentScreenObservation AgentScreenReader::cursor() const noexcept {
    constexpr unsigned composer_rows = 32;
    const auto first = screen_.rows - std::min<unsigned>(screen_.rows, composer_rows);

    for (std::size_t screen_row = screen_.rows; screen_row-- > first;) {
      const auto composer = row(screen_row);
      if (composer.first != cursor_prompt || composer.column > 3) {
        continue;
      }

      const bool identified = composer.text().starts_with("Add a follow-up") || composer.text().starts_with("Plan, search, build anything");

      if (composer.text().contains("ctrl+c to stop")) {
        return {.status = AgentStatus::working, .restored_draft = false, .identity_confirmed = identified};
      }

      const auto top = std::max<std::size_t>(first, screen_row > 6 ? screen_row - 6 : 0);

      for (std::size_t above = screen_row; above-- > top;) {
        const auto line = row(above);
        const auto label = line.text();
        if (braille(line.first) && !label.empty() && ((label.front() >= 'A' && label.front() <= 'Z') || (label.front() >= 'a' && label.front() <= 'z'))) {
          return {.status = AgentStatus::working, .restored_draft = false, .identity_confirmed = identified};
        }
      }

      return {.status = AgentStatus::ready, .restored_draft = false, .identity_confirmed = identified};
    }

    return {};
  }

  bool hasIdleScreen(AgentProvider provider) noexcept {
    return provider == AgentProvider::claude || provider == AgentProvider::codex || provider == AgentProvider::cursor;
  }

  std::string_view AgentScreenSample::capture(AgentScreenView screen) noexcept {
    start_ = bytes_.size();
    for (std::size_t row = screen.rows; row-- != 0;) {
      if (start_ != bytes_.size() && (screen.row_flags[row] & static_cast<Byte>(RowFlag::wrap)) == 0 && !prepend(" ")) {
        break;
      }

      const auto cells = trimmedCells(screen.cells.subspan(row * screen.cols, screen.cols));

      for (std::size_t column = cells.size(); column-- != 0;) {
        if (!prepend(cellText(cells[column]))) {
          return text();
        }
      }
    }

    return text();
  }

  bool AgentScreenSample::prepend(std::string_view bytes) noexcept {
    if (bytes.size() > start_) {
      return false;
    }

    start_ -= bytes.size();
    std::ranges::copy(bytes, bytes_.viewMut().subspan(start_).begin());
    return true;
  }

  std::string_view AgentScreenSample::text() const noexcept {
    return textAfter({bytes_.data(), bytes_.size()}, start_);
  }

  ds::Option<AgentSignal> AgentScreenInference::observe(Terminal& terminal, const AgentManifests& manifests, AgentProvider provider, ObservationTime now) {
    if (!terminal.outputSettled()) {
      return ds::none;
    }

    terminal.refresh();

    const auto screen = agentScreenView(terminal.screen());

    return infer(AgentScreenReader{screen, terminal.effects().title(), manifests}, screen, manifests, provider, now);
  }

  ds::Option<AgentSignal> AgentScreenInference::infer(const AgentScreenReader& reader, AgentScreenView screen, const AgentManifests& manifests, AgentProvider provider, ObservationTime now) {
    const auto signal = screenSignal(reader, screen, manifests, provider);
    if (composerLost(signal)) {
      return ds::none;
    }

    if (!signal) {
      last_signal_.reset();
      return ds::none;
    }

    if (signal == last_signal_ && (signal->provider != AgentProvider::codex || !signal->ready_confirmed) && now.milliseconds - last_signal_time_ < signal_refresh.count()) {
      return ds::none;
    }

    last_signal_ = signal;
    last_signal_time_ = now.milliseconds;
    return last_signal_;
  }

  ds::Option<AgentSignal> AgentScreenInference::screenSignal(const AgentScreenReader& reader, AgentScreenView screen, const AgentManifests& manifests, AgentProvider provider) {
    const auto phrases = provider == AgentProvider::codex ? ds::none : manifests.detect(sample_.capture(screen));
    const auto codex = provider == AgentProvider::unknown || provider == AgentProvider::codex ? reader.signal(AgentProvider::codex) : ds::none;

    auto signal = phrases;

    if (provider == AgentProvider::codex || (provider == AgentProvider::unknown && codex && codex->identity_confirmed)) {
      signal = codex;
    } else if (provider == AgentProvider::unknown && phrases && phrases->provider == AgentProvider::codex) {
      signal.reset();
    } else if (provider == AgentProvider::cursor) {
      if (!phrases || phrases->status != AgentStatus::blocked) {
        signal = reader.signal(AgentProvider::cursor);
      }
    } else {
      const auto* manifest = phrases ? manifests.find(phrases->provider) : nullptr;
      if (!phrases || (phrases->status != AgentStatus::blocked && (manifest == nullptr || manifest->ready_prompt.entries().empty()))) {
        if (auto prompt = reader.signal(AgentProvider::claude)) {
          prompt.getMut().identity_confirmed = phrases && phrases->provider == prompt->provider && phrases->identity_confirmed;
          signal = prompt;
        }
      }
    }

    return signal;
  }

  bool AgentScreenInference::composerLost(const ds::Option<AgentSignal>& signal) noexcept {
    if (!signal || (signal->provider != AgentProvider::codex && signal->provider != AgentProvider::cursor)) {
      return false;
    }

    if (signal->status == AgentStatus::working) {
      composer_lost_ = false;
    }

    return composer_lost_;
  }

  void AgentScreenInference::reset() noexcept {
    last_signal_.reset();
    last_signal_time_ = 0;
    composer_lost_ = true;
  }

}
