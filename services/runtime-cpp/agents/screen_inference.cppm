module;
#include <unistd.h>
#include <new>
#include <cerrno>
#include <ghostty/vt.h>
#include <stdlib.h>
#include <zlib.h>


#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>

#include <cstdint>

#include <cstring>
#include <cstddef>
#include "telar_base/diagnostics/config.hpp"
#include <sys/mman.h>
#include "cell_layout.hpp"
#include <cassert>

export module telar.runtime.agents.screen_inference;

import std;

export import telar.runtime.agents.session_host;

export import telar.config;


export import telar.runtime.terminal.text_reader;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;

// Interface: agents/prompt_budget.cppm
export {
namespace telar::runtime {

class PromptBudget {
public:
  inline bool spend(std::uint64_t sender, std::uint64_t target, std::chrono::steady_clock::time_point now) noexcept {
    auto entry = std::ranges::find_if(pairs_, [&](const Pair &pair) { return pair.sender == sender && pair.target == target; });
    if (entry == pairs_.end()) {
      entry = std::ranges::min_element(pairs_, {}, &Pair::started);
      *entry = Pair{sender, target, now, 0};
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

private:
  struct Pair {
    std::uint64_t sender = 0;
    std::uint64_t target = 0;
    std::chrono::steady_clock::time_point started{};
    unsigned count = 0;
  };

  static constexpr std::chrono::seconds window{60};
  static constexpr unsigned prompts_per_window = 8;
  std::array<Pair, 32> pairs_{};
};

}
}

// Interface: agents/resume.cppm
export {
namespace telar::runtime {

struct AgentResume {
  AgentProvider provider = AgentProvider::unknown;
  FixedText<64> session{};
  FixedText<96> title{};
  AgentTitleSource title_source = AgentTitleSource::telar;
  bool in_pane = false;
};

inline bool hexadecimal(char value) noexcept {
  return (value >= '0' && value <= '9') || (value >= 'a' && value <= 'f') || (value >= 'A' && value <= 'F');
}

inline bool validResumeSession(AgentProvider provider, std::string_view value) noexcept {
  if (provider == AgentProvider::opencode) {
    if (value.size() != 30 || !value.starts_with("ses_")) {
      return false;
    }

    for (std::size_t index = 4; index < value.size(); ++index) {
      const auto character = value[index];
      const bool valid = index < 16 ? hexadecimal(character) : (character >= '0' && character <= '9') || (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z');
      if (!valid) {
        return false;
      }
    }

    return true;
  }

  if (describeProvider(provider).name.empty() || value.size() != 36) {
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

inline std::span<const std::string_view> resumeArguments(const AgentResume &resume, std::array<std::string_view, 4> &arguments) noexcept {
  if (!validResumeSession(resume.provider, resume.session.view())) {
    return {};
  }

  arguments[0] = resume.provider == AgentProvider::cursor ? "cursor-agent" : describeProvider(resume.provider).name;
  arguments[1] = resume.provider == AgentProvider::codex ? "resume" : resume.provider == AgentProvider::pi || resume.provider == AgentProvider::opencode ? "--session"
                                                                                                                                                         : "--resume";
  std::size_t count = 2;
  if (resume.provider == AgentProvider::codex && resume.in_pane) {
    arguments[count++] = "--no-daemon";
  }
  arguments[count++] = resume.session.view();

  return std::span{arguments}.first(count);
}

}
}

// Interface: agents/screen_observation.cppm
export {
namespace telar::runtime {

struct AgentScreenObservation {
  std::optional<AgentStatus> status;
  bool restored_draft = false;
  bool identity_confirmed = false;
};

inline std::uint32_t cellCodepoint(const ScreenCell &cell) noexcept {
  if (cell.length == 0) {
    return 0;
  }
  const auto first = cell.text[0];
  if (first < 0x80) {
    return first;
  }
  const unsigned length = first < 0xe0 ? 2 : first < 0xf0 ? 3
                                                          : 4;
  if (length > cell.length) {
    return 0;
  }
  std::uint32_t value = first & (0x7f >> length);
  for (unsigned index = 1; index < length; ++index) {
    value = (value << 6) | (cell.text[index] & 0x3f);
  }
  return value;
}

struct AgentScreenRow {
  std::array<char, 1024> bytes{};
  std::size_t length = 0;
  std::uint32_t first = 0;
  std::size_t column = 0;

  inline std::string_view text() const noexcept {
    const std::string_view value{bytes.data(), length};
    const auto start = value.find_first_not_of(' ');
    return start == std::string_view::npos ? std::string_view{} : value.substr(start, value.find_last_not_of(' ') - start + 1);
  }
};

template <Allocator Memory>
class AgentScreenReader {
public:
  inline explicit AgentScreenReader(const Terminal<Memory> &terminal, const AgentManifests &manifests = builtin_manifests)
      : screen_(terminal.screen),
        title_(terminal.effects.title()),
        manifests_(manifests) {}

  inline AgentScreenObservation observe(AgentProvider provider) const noexcept {
    switch (provider) {
    case AgentProvider::claude:
      return claude();
    case AgentProvider::codex:
      return codex();
    case AgentProvider::cursor:
      return cursor();
    default:
      return {};
    }
  }

  inline std::optional<AgentSignal> signal(AgentProvider provider) const noexcept {
    const auto observation = observe(provider);
    if (!observation.status || (provider == AgentProvider::claude && observation.status == AgentStatus::working)) {
      return std::nullopt;
    }

    return AgentSignal{provider, *observation.status, static_cast<Byte>(provider == AgentProvider::claude ? 96 : 94), observation.identity_confirmed, observation.status == AgentStatus::ready};
  }

private:
  inline std::span<const ScreenCell> rowCells(std::size_t row) const noexcept {
    return std::span{screen_.cells}.subspan(row * screen_.cols, screen_.cols);
  }

  inline AgentScreenRow row(std::size_t y) const noexcept {
    AgentScreenRow result;
    const auto cells = rowCells(y);
    for (std::size_t column = 0; column < cells.size(); ++column) {
      const auto codepoint = cellCodepoint(cells[column]);
      if (result.first == 0 && codepoint != 0 && codepoint != ' ') {
        result.first = codepoint;
        result.column = column;
      }

      if (result.length == result.bytes.size()) {
        break;
      }

      result.bytes[result.length++] = codepoint > 0 && codepoint < 128 ? static_cast<char>(codepoint) : ' ';
    }
    return result;
  }

  inline static bool blank(std::uint32_t codepoint) noexcept {
    return codepoint == 0 || codepoint == ' ' || codepoint == 0x00a0;
  }

  inline AgentScreenObservation claude() const noexcept {
    if (title_.starts_with("◐") || title_.starts_with("◑")) {
      return {AgentStatus::working};
    }
    AgentScreenObservation result;
    bool observed_lowest_prompt = false;
    const auto first = screen_.rows - std::min<unsigned>(screen_.rows, 12);
    for (std::size_t y = screen_.rows; y-- > first;) {
      const auto cells = rowCells(y);
      std::size_t prompt = 0;
      while (prompt < cells.size() && blank(cellCodepoint(cells[prompt]))) {
        ++prompt;
      }
      if (prompt == cells.size() || cellCodepoint(cells[prompt]) != claude_prompt) {
        continue;
      }
      if (!observed_lowest_prompt && title_.starts_with("✳")) {
        result.restored_draft = std::ranges::any_of(cells.subspan(prompt + 1), [](const auto &cell) {
          return !blank(cellCodepoint(cell)) && (cell.style.flags & static_cast<unsigned>(CellAttribute::faint)) == 0;
        });
      }
      observed_lowest_prompt = true;

      if (!screen_.cursor.visible) {
        const bool software_cursor = std::ranges::any_of(cells.subspan(prompt + 1), [](const auto &cell) {
          return (cell.style.flags & static_cast<unsigned>(CellAttribute::inverse)) != 0 || cell.style.background.kind != CellColor::Kind::default_color;
        });
        if (software_cursor) {
          result.status = AgentStatus::ready;
        }
      }
      if (screen_.cursor.visible || result.status) {
        break;
      }
    }
    if (screen_.cursor.visible && screen_.cursor.y < screen_.rows) {
      const auto cells = rowCells(screen_.cursor.y);
      std::size_t column = std::min<std::size_t>(static_cast<std::size_t>(screen_.cursor.x) + 1, cells.size());
      for (unsigned distance = 0; column != 0 && distance < 8; ++distance) {
        const auto codepoint = cellCodepoint(cells[--column]);
        if (blank(codepoint)) {
          continue;
        }
        if (codepoint == claude_prompt) {
          result.status = AgentStatus::ready;
        }
        break;
      }
    }
    return result;
  }

  inline static bool codexStatus(const AgentScreenRow &row) noexcept {
    const auto line = row.text();
    const auto open = line.find('(');
    if (open == std::string_view::npos) {
      return false;
    }
    const auto prefix = line.substr(0, open);
    const auto heading = prefix.substr(0, prefix.find_last_not_of(' ') + 1);
    const bool spinner = row.first == 0x2022 || (row.first >= 0x2800 && row.first <= 0x28ff);
    if (!spinner && heading != "Working" && heading != "Thinking" && heading != "Reconnecting" && heading != "Compacting") {
      return false;
    }
    const auto clock = line.substr(open + 1);
    const auto digits = clock.find_first_not_of("0123456789");
    return digits != 0 && digits != std::string_view::npos && (clock[digits] == 's' || clock[digits] == 'm' || clock[digits] == 'h');
  }

  inline AgentScreenObservation codex() const noexcept {
    const auto *manifest = manifests_.find(AgentProvider::codex);
    if (manifest == nullptr) {
      return {};
    }

    const auto first = screen_.rows - std::min<unsigned>(screen_.rows, 32);
    for (std::size_t y = screen_.rows; y-- > first;) {
      const auto composer = row(y);
      if (composer.first != 0x203a || composer.column > 1) {
        continue;
      }
      const bool identified = manifest->ready_prompt.matches(composer.text());
      for (std::size_t above = y; above-- > first;) {
        const auto line = row(above);
        if (line.first == 0x2500) {
          break;
        }
        if (codexStatus(line)) {
          return {AgentStatus::working, false, identified};
        }
      }
      if (!screen_.cursor.visible || screen_.cursor.y < y || screen_.cursor.x < composer.column + 2) {
        return {};
      }
      for (std::size_t continuation = y + 1; continuation <= screen_.cursor.y; ++continuation) {
        const auto line = row(continuation);
        if (line.first != 0 && line.column < composer.column + 2) {
          return {};
        }
      }
      return {AgentStatus::ready, false, identified};
    }
    return {};
  }

  inline AgentScreenObservation cursor() const noexcept {
    const auto first = screen_.rows - std::min<unsigned>(screen_.rows, 32);
    for (std::size_t y = screen_.rows; y-- > first;) {
      const auto composer = row(y);
      if (composer.first != 0x2192 || composer.column > 3) {
        continue;
      }
      const bool identified = composer.text().starts_with("Add a follow-up") || composer.text().starts_with("Plan, search, build anything");
      if (composer.text().find("ctrl+c to stop") != std::string_view::npos) {
        return {AgentStatus::working, false, identified};
      }
      const auto top = std::max<std::size_t>(first, y > 6 ? y - 6 : 0);
      for (std::size_t above = y; above-- > top;) {
        const auto line = row(above);
        const auto label = line.text();
        if (line.first >= 0x2800 && line.first <= 0x28ff && !label.empty() && ((label.front() >= 'A' && label.front() <= 'Z') || (label.front() >= 'a' && label.front() <= 'z'))) {
          return {AgentStatus::working, false, identified};
        }
      }
      return {AgentStatus::ready, false, identified};
    }
    return {};
  }

  static constexpr std::uint32_t claude_prompt = 0x276f;
  const Screen<Memory> &screen_;
  std::string_view title_;
  const AgentManifests &manifests_;
};

template <Allocator Memory>
AgentScreenReader(const Terminal<Memory> &terminal, const AgentManifests &manifests = builtin_manifests) -> AgentScreenReader<Memory>;

inline bool hasIdleScreen(AgentProvider provider) noexcept {
  return provider == AgentProvider::claude || provider == AgentProvider::codex || provider == AgentProvider::cursor;
}

}
}

// Interface: agents/screen_inference.cppm
export {
namespace telar::runtime {

class AgentScreenSample {
public:
  template <Allocator Memory>
  inline std::string_view capture(const Screen<Memory> &screen) noexcept {
    start_ = bytes_.size();
    for (std::size_t row = screen.rows; row-- != 0;) {
      if (start_ != bytes_.size() && (screen.row_flags[row] & static_cast<Byte>(RowFlag::wrap)) == 0 && !prepend(" ")) {
        break;
      }

      auto cells = std::span{screen.cells}.subspan(row * screen.cols, screen.cols);
      while (!cells.empty() && (cells.back().length == 0 || (cells.back().length == 1 && cells.back().text[0] == ' '))) {
        cells = cells.first(cells.size() - 1);
      }

      for (std::size_t column = cells.size(); column-- != 0;) {
        const auto &cell = cells[column];
        const auto first = cell.text[0];
        const auto length = first < 0x80 ? 1U : first < 0xe0 ? 2U
                                            : first < 0xf0   ? 3U
                                                             : 4U;
        if (!prepend(cell.length == 0 ? std::string_view{" "} : std::string_view{reinterpret_cast<const char *>(cell.text.data()), std::min<std::size_t>(length, cell.length)})) {
          return text();
        }
      }
    }

    return text();
  }

private:
  inline bool prepend(std::string_view bytes) noexcept {
    if (bytes.size() > start_) {
      return false;
    }

    start_ -= bytes.size();
    std::memcpy(bytes_.data() + start_, bytes.data(), bytes.size());
    return true;
  }

  inline std::string_view text() const noexcept {
    return {bytes_.data() + start_, bytes_.size() - start_};
  }

  std::array<char, 16 * 1024> bytes_{};
  std::size_t start_ = bytes_.size();
};

class AgentScreenInference {
public:
  template <Allocator Memory>
  inline std::optional<AgentSignal> observe(Terminal<Memory> &terminal, const AgentManifests &manifests, AgentProvider provider, ObservationTime now) {
    if (!terminal.outputSettled()) {
      return std::nullopt;
    }

    terminal.refresh();
    const AgentScreenReader reader{terminal, manifests};
    const auto phrases = provider == AgentProvider::codex ? std::nullopt : manifests.detect(sample_.capture(terminal.screen));
    const auto codex = provider == AgentProvider::unknown || provider == AgentProvider::codex ? reader.signal(AgentProvider::codex) : std::nullopt;
    auto signal = phrases;
    if (provider == AgentProvider::codex || (provider == AgentProvider::unknown && codex && codex->identity_confirmed)) {
      signal = codex;
    } else if (provider == AgentProvider::unknown && phrases && phrases->provider == AgentProvider::codex) {
      signal.reset();
    } else if (provider == AgentProvider::cursor) {
      signal = phrases && phrases->status == AgentStatus::blocked ? phrases : reader.signal(AgentProvider::cursor);
    } else {
      const auto *manifest = phrases ? manifests.find(phrases->provider) : nullptr;
      if (!phrases || (phrases->status != AgentStatus::blocked && (manifest == nullptr || manifest->ready_prompt.entries().empty()))) {
        if (auto prompt = reader.signal(AgentProvider::claude)) {
          prompt->identity_confirmed = phrases && phrases->provider == prompt->provider && phrases->identity_confirmed;
          signal = prompt;
        }
      }
    }

    if (signal && (signal->provider == AgentProvider::codex || signal->provider == AgentProvider::cursor)) {
      if (signal->status == AgentStatus::working) {
        composer_lost_ = false;
      } else if (composer_lost_) {
        return std::nullopt;
      }
    }

    if (!signal) {
      last_signal_.reset();
      return std::nullopt;
    }

    if (signal == last_signal_ && !(signal->provider == AgentProvider::codex && signal->ready_confirmed) && now.milliseconds - last_signal_time_ < signal_refresh.count()) {
      return std::nullopt;
    }

    last_signal_ = signal;
    last_signal_time_ = now.milliseconds;
    return signal;
  }

  inline void reset() noexcept {
    last_signal_.reset();
    last_signal_time_ = 0;
    composer_lost_ = true;
  }

private:
  static constexpr std::chrono::milliseconds signal_refresh{15'000};
  AgentScreenSample sample_;
  std::optional<AgentSignal> last_signal_;
  std::int64_t last_signal_time_ = 0;
  bool composer_lost_ = false;
};

}
}
