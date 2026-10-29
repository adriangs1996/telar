#pragma once

#include "core/unicode_scalar.hpp"
#include "limits.hpp"
#include "text/cell_text_measure.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>

namespace telar::gui {

enum class PathLabelTone : std::uint8_t {
  directory,
  name,
  match,
  ellipsis,
};

struct PathLabelRun {
  std::string_view text;
  PathLabelTone tone = PathLabelTone::name;
};

class PathLabel {
public:
  static constexpr std::size_t runs_per_match = 2;
  static constexpr std::size_t structural_runs = 6;
  static constexpr std::size_t maximum_runs = (runs_per_match * PathPickerLimits::query_bytes) + structural_runs;
  static constexpr std::string_view ellipsis = "…";
  static constexpr std::uint32_t ellipsis_columns = 1;

  void layout(std::string_view path, std::span<const std::uint16_t> positions, std::uint16_t width) {
    count_ = 0;
    const auto name_start = nameStart(path);
    if (cellTextColumns(path) <= width) {
      appendSpan({.path = path, .positions = positions, .end = path.size(), .name_start = name_start});

      return;
    }

    const auto name_width = cellTextColumns(path.substr(name_start));
    const auto head_width = width > name_width + ellipsis_columns ? width - name_width - ellipsis_columns : 0;
    const auto head_end = fitting(path.substr(0, name_start), head_width);
    appendSpan({.path = path, .positions = positions, .end = head_end, .name_start = name_start});
    push({.text = ellipsis, .tone = PathLabelTone::ellipsis});
    appendSpan({.path = path, .positions = positions, .start = name_start, .end = path.size(), .name_start = name_start});
  }

  [[nodiscard]] std::span<const PathLabelRun> runs() const noexcept {
    return std::span{runs_}.first(count_);
  }

private:
  struct Span {
    std::string_view path;
    std::span<const std::uint16_t> positions;
    std::size_t start = 0;
    std::size_t end = 0;
    std::size_t name_start = 0;
  };

  [[nodiscard]] static std::size_t nameStart(std::string_view path) noexcept {
    const auto last = path.find_last_not_of('/');
    path.remove_suffix(last == std::string_view::npos ? path.size() : path.size() - last - 1);
    const auto split = path.rfind('/');

    return split == std::string_view::npos ? 0 : split + 1;
  }

  [[nodiscard]] static std::size_t nextScalar(std::string_view text, std::size_t offset) noexcept {
    const auto sequence = Utf8Scalar::sequenceLength(static_cast<unsigned char>(text[offset]));
    const auto length = sequence >= 1 && sequence <= Utf8Scalar::leading_masks.size() ? sequence : 1;

    return std::min(offset + length, text.size());
  }

  [[nodiscard]] static std::size_t fitting(std::string_view text, std::uint32_t width) {
    std::uint32_t used = 0;
    std::size_t end = 0;
    while (end < text.size()) {
      const auto next = nextScalar(text, end);
      const auto columns = cellTextColumns(text.substr(end, next - end));
      if (used + columns > width) {
        break;
      }

      used += columns;
      end = next;
    }

    return end;
  }

  [[nodiscard]] static PathLabelTone toneAt(const Span &span, std::size_t first, std::size_t last) noexcept {
    for (const auto position : span.positions) {
      if (position >= first && position < last) {
        return PathLabelTone::match;
      }
    }

    return first >= span.name_start ? PathLabelTone::name : PathLabelTone::directory;
  }

  void appendSpan(const Span &span) {
    if (span.start == span.end) {
      return;
    }

    auto run_start = span.start;
    auto tone = toneAt(span, span.start, nextScalar(span.path, span.start));
    auto cursor = span.start;
    while (cursor < span.end) {
      const auto next = nextScalar(span.path, cursor);
      const auto current = toneAt(span, cursor, next);
      if (current != tone) {
        push({.text = span.path.substr(run_start, cursor - run_start), .tone = tone});
        run_start = cursor;
        tone = current;
      }

      cursor = next;
    }

    push({.text = span.path.substr(run_start, span.end - run_start), .tone = tone});
  }

  void push(PathLabelRun run) noexcept {
    if (count_ < runs_.size()) {
      runs_[count_++] = run;
    }
  }

  std::array<PathLabelRun, maximum_runs> runs_{};
  std::size_t count_ = 0;
};

}
