#pragma once

#include "../terminal/terminal.hpp"
#include "builtin_manifests.hpp"
#include <optional>

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

  std::string_view text() const noexcept {
    const std::string_view value{bytes.data(), length};
    const auto start = value.find_first_not_of(' ');
    return start == std::string_view::npos ? std::string_view{} : value.substr(start, value.find_last_not_of(' ') - start + 1);
  }
};

template <Allocator Memory>
class AgentScreenReader {
public:
  explicit AgentScreenReader(const Terminal<Memory> &terminal, const AgentManifests &manifests = builtin_manifests)
      : screen_(terminal.screen),
        title_(terminal.effects.title()),
        manifests_(manifests) {}

  AgentScreenObservation observe(AgentProvider provider) const noexcept {
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

  std::optional<AgentSignal> signal(AgentProvider provider) const noexcept {
    const auto observation = observe(provider);
    if (!observation.status || (provider == AgentProvider::claude && observation.status == AgentStatus::working)) {
      return std::nullopt;
    }

    return AgentSignal{provider, *observation.status, static_cast<Byte>(provider == AgentProvider::claude ? 96 : 94), observation.identity_confirmed, observation.status == AgentStatus::ready};
  }

private:
  std::span<const ScreenCell> rowCells(std::size_t row) const noexcept {
    return std::span{screen_.cells}.subspan(row * screen_.cols, screen_.cols);
  }

  AgentScreenRow row(std::size_t y) const noexcept {
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

  static bool blank(std::uint32_t codepoint) noexcept {
    return codepoint == 0 || codepoint == ' ' || codepoint == 0x00a0;
  }

  AgentScreenObservation claude() const noexcept {
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

  static bool codexStatus(const AgentScreenRow &row) noexcept {
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

  AgentScreenObservation codex() const noexcept {
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

  AgentScreenObservation cursor() const noexcept {
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
