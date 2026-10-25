#pragma once

#include "../memory/allocator.hpp"
#include <array>
#include <cstdint>
#include <optional>
#include <span>

namespace telar::runtime {

template <Allocator Memory>
class FuzzyMatch {
public:
  explicit FuzzyMatch(Memory &memory)
      : matrix_(AllocatorRef<std::int32_t, Memory>{memory}) {
    matrix_.resize(2 * maximum_needle * maximum_path);
  }

  std::optional<std::int32_t> score(std::string_view path, std::string_view query, std::span<std::uint16_t> positions = {}) {
    if (query.empty()) {
      return 0;
    }
    if (query.size() > maximum_needle || query.size() > path.size()) {
      return std::nullopt;
    }
    std::array<std::uint16_t, maximum_needle> first_matches;
    std::size_t offset = 0;
    for (std::size_t matched = 0; matched < query.size(); ++matched) {
      const char wanted = lower(query[matched]);
      while (offset < path.size() && lower(path[offset]) != wanted) {
        ++offset;
      }
      if (offset == path.size()) {
        return std::nullopt;
      }

      first_matches[matched] = static_cast<std::uint16_t>(offset);
      if (!positions.empty()) {
        positions[matched] = first_matches[matched];
      }
      ++offset;
    }
    if (path.size() > maximum_path) {
      return minimum_score / 2;
    }
    if (path.size() == query.size()) {
      return std::numeric_limits<std::int32_t>::max() / 2;
    }

    std::array<std::int32_t, maximum_path> bonuses;
    char previous = '/';
    for (std::size_t index = 0; index < path.size(); ++index) {
      bonuses[index] = bonus(previous, path[index]);
      previous = path[index];
    }

    const bool retain_rows = !positions.empty();
    for (std::size_t index = 0; index < query.size(); ++index) {
      const auto current = retain_rows ? index : index % 2;
      const auto preceding = retain_rows ? (index == 0 ? 0 : index - 1) : 1 - current;
      const auto ending = row(current, false);
      const auto best = row(current, true);
      const auto previous_ending = row(preceding, false);
      const auto previous_best = row(preceding, true);
      const int gap = index + 1 == query.size() ? trailing_gap : inner_gap;
      const char wanted = lower(query[index]);
      auto running = minimum_score;
      // Earlier columns cannot reach this query prefix; later columns leave too few bytes for its suffix.
      const auto alignment_end = path.size() - (query.size() - index - 1);
      for (std::size_t column = first_matches[index]; column < alignment_end; ++column) {
        if (lower(path[column]) != wanted) {
          ending[column] = minimum_score;
          running = plus(running, gap);
          best[column] = running;
          continue;
        }

        auto cell = minimum_score;
        if (index == 0) {
          cell = static_cast<int>(column) * leading_gap + bonuses[column];
        } else if (column != 0) {
          cell = std::max(plus(previous_best[column - 1], bonuses[column]), plus(previous_ending[column - 1], consecutive_score));
        }

        ending[column] = cell;
        running = std::max(cell, plus(running, gap));
        best[column] = running;
      }
    }

    if (retain_rows) {
      bool required = false;
      std::size_t column = path.size();
      for (std::size_t index = query.size(); index != 0;) {
        --index;
        while (column > first_matches[index]) {
          --column;
          const auto cell = row(index, false)[column];
          if (cell == minimum_score || (!required && cell != row(index, true)[column])) {
            continue;
          }
          required = index != 0 && column != 0 && cell == plus(row(index - 1, false)[column - 1], consecutive_score);
          positions[index] = static_cast<std::uint16_t>(column);
          break;
        }
      }
    }

    return row(retain_rows ? query.size() - 1 : (query.size() - 1) % 2, true)[path.size() - 1];
  }

private:
  static char lower(char value) noexcept {
    return value >= 'A' && value <= 'Z' ? static_cast<char>(value + ('a' - 'A')) : value;
  }

  static std::int32_t plus(std::int32_t value, int increment) noexcept {
    return value == minimum_score ? minimum_score : value + increment;
  }

  static int bonus(char previous, char value) noexcept {
    const char folded = lower(value);
    if (!((folded >= 'a' && folded <= 'z') || (value >= '0' && value <= '9'))) {
      return 0;
    }
    switch (previous) {
    case '/':
      return 900;
    case '-':
    case '_':
    case ' ':
      return 800;
    case '.':
      return 600;
    default:
      return previous >= 'a' && previous <= 'z' && value >= 'A' && value <= 'Z' ? 700 : 0;
    }
  }

  std::span<std::int32_t> row(std::size_t index, bool best) noexcept {
    return std::span{matrix_}.subspan((index * 2 + static_cast<unsigned>(best)) * maximum_path, maximum_path);
  }

  static constexpr std::size_t maximum_path = 1024;
  static constexpr std::size_t maximum_needle = 64;
  static constexpr int consecutive_score = 1000;
  static constexpr int leading_gap = -5;
  static constexpr int inner_gap = -10;
  static constexpr int trailing_gap = -5;
  static constexpr auto minimum_score = std::numeric_limits<std::int32_t>::min();
  Vector<std::int32_t, Memory> matrix_;
};

}
