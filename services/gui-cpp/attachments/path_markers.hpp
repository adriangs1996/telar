#pragma once

#include "attachments/marker_screen.hpp"
#include "terminal/cell_position.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>

namespace telar::gui {

inline constexpr std::size_t attachment_uuid_bytes = 36;
using AttachmentPathUuid = std::array<std::uint8_t, attachment_uuid_bytes>;

struct PathAttachmentMarker {
  AttachmentPathUuid uuid{};
  CellPosition start;
  CellPosition end;
  std::optional<std::uint16_t> cells;
};

class PathAttachmentMarkers {
public:
  static constexpr std::uint16_t maximum_cells = 512;

  [[nodiscard]] static std::optional<PathAttachmentMarker> find(AttachmentMarkerScreen screen, const AttachmentPathUuid &uuid) noexcept {
    Scan scan{screen};
    while (const auto point = scan.position()) {
      const auto head = parseHead(screen, *point);
      if (head && head->uuid == uuid) {
        return extend(screen, *head);
      }

      scan.step();
    }

    return std::nullopt;
  }

  [[nodiscard]] static std::size_t collect(AttachmentMarkerScreen screen, std::span<PathAttachmentMarker> output) noexcept {
    if (output.empty()) {
      return 0;
    }

    std::size_t count = 0;
    Scan scan{screen};
    while (const auto point = scan.position()) {
      const auto head = parseHead(screen, *point);
      scan.step();
      if (!head || std::ranges::any_of(output.first(count), [&](const auto &known) { return known.uuid == head->uuid; })) {
        continue;
      }

      if (count == output.size()) {
        std::move(output.begin() + 1, output.begin() + static_cast<std::ptrdiff_t>(count), output.begin());
        --count;
      }

      output[count++] = extend(screen, *head);
    }

    return count;
  }

  [[nodiscard]] static std::optional<std::uint16_t> cursorOnRow(AttachmentMarkerScreen screen, std::uint16_t row) noexcept {
    if (screen.cursor.visible) {
      return screen.cursor.y == row ? std::optional{screen.cursor.x} : std::nullopt;
    }

    for (std::uint16_t column = 0; column < screen.columns; ++column) {
      if (screen.isolatedInverse({.x = column, .y = row})) {
        return column;
      }
    }

    return std::nullopt;
  }

  [[nodiscard]] static bool cursorAt(AttachmentMarkerScreen screen, CellPosition point) noexcept {
    return screen.cursor.visible ? screen.cursor.x == point.x && screen.cursor.y == point.y : screen.isolatedInverse(point);
  }

private:
  static constexpr std::string_view prefix = "pi-clipboard-";
  static constexpr std::array<std::string_view, 4> extensions{"png", "jpg", "webp", "gif"};
  static constexpr std::array<std::size_t, 4> dash_positions{8, 13, 18, 23};

  class Scan {
  public:
    explicit Scan(AttachmentMarkerScreen screen, CellPosition point = {}) noexcept
        : screen_(screen),
          point_(point) {}

    [[nodiscard]] std::optional<CellPosition> position() noexcept {
      if (screen_.columns < 2) {
        return std::nullopt;
      }

      if (point_.x >= screen_.columns - 1) {
        point_.x = 0;
        ++point_.y;
      }

      return point_.y < screen_.rows ? std::optional{point_} : std::nullopt;
    }

    [[nodiscard]] CellPosition rawPosition() const noexcept {
      return point_;
    }

    void step() noexcept {
      ++point_.x;
    }

    [[nodiscard]] bool expect(std::uint8_t byte) noexcept {
      const auto point = position();
      const auto *const cell = point ? screen_.cell(*point) : nullptr;
      if (cell == nullptr || !single(*cell) || cell->text[0] != byte) {
        return false;
      }

      step();

      return true;
    }

  private:
    AttachmentMarkerScreen screen_;
    CellPosition point_;
  };

  [[nodiscard]] static bool single(const CellValue &cell) noexcept {
    return cell.width == CellWidth::single && cell.length == 1;
  }

  [[nodiscard]] static bool blank(const CellValue &cell) noexcept {
    return cell.length == 0 || cell.utf8() == " ";
  }

  [[nodiscard]] static bool hex(std::uint8_t byte) noexcept {
    return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F');
  }

  [[nodiscard]] static bool alphanumeric(std::uint8_t byte) noexcept {
    return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z');
  }

  [[nodiscard]] static std::optional<CellPosition> matchExtension(Scan scan) noexcept {
    for (const auto extension : extensions) {
      auto attempt = scan;
      bool matched = true;
      for (const auto byte : extension) {
        matched = matched && attempt.expect(static_cast<std::uint8_t>(byte));
      }

      if (matched) {
        return attempt.rawPosition();
      }
    }

    return std::nullopt;
  }

  [[nodiscard]] static std::optional<PathAttachmentMarker> parseHead(AttachmentMarkerScreen screen, CellPosition start) noexcept {
    if (start.y >= screen.rows || start.x >= screen.columns || screen.columns < 2) {
      return std::nullopt;
    }

    Scan scan{screen, start};
    for (const auto byte : prefix) {
      if (!scan.expect(static_cast<std::uint8_t>(byte))) {
        return std::nullopt;
      }
    }

    AttachmentPathUuid uuid{};
    for (std::size_t index = 0; index < uuid.size(); ++index) {
      const auto point = scan.position();
      const auto *const cell = point ? screen.cell(*point) : nullptr;
      if (cell == nullptr || !single(*cell)) {
        return std::nullopt;
      }

      const auto byte = cell->text[0];
      const bool dash = std::ranges::find(dash_positions, index) != dash_positions.end();
      if ((dash && byte != '-') || (!dash && !hex(byte))) {
        return std::nullopt;
      }

      uuid[index] = byte;
      scan.step();
    }

    if (!scan.expect('.')) {
      return std::nullopt;
    }

    const auto end = matchExtension(scan);
    if (!end) {
      return std::nullopt;
    }

    if (end->x < screen.columns - 1) {
      const auto *const following = screen.cell(*end);
      if (following != nullptr && single(*following) && alphanumeric(following->text[0])) {
        return std::nullopt;
      }
    }

    return PathAttachmentMarker{.uuid = uuid, .start = start, .end = *end, .cells = std::nullopt};
  }

  [[nodiscard]] static bool rowForceWrapped(AttachmentMarkerScreen screen, std::uint32_t row) noexcept {
    if (screen.columns < 2) {
      return false;
    }

    const auto *const last = screen.cell({.x = static_cast<std::uint16_t>(screen.columns - 2), .y = row});
    const auto *const reserved = screen.cell({.x = static_cast<std::uint16_t>(screen.columns - 1), .y = row});

    return last != nullptr && reserved != nullptr && !blank(*last) && blank(*reserved);
  }

  [[nodiscard]] static CellPosition pathStart(AttachmentMarkerScreen screen, CellPosition marker) noexcept {
    auto point = marker;
    std::optional<CellPosition> slash;
    for (;;) {
      if (point.x == 0) {
        if (point.y == 0 || !rowForceWrapped(screen, point.y - 1)) {
          break;
        }

        --point.y;
        point.x = static_cast<std::uint16_t>(screen.columns - 1);
        continue;
      }

      const auto *const previous = screen.cell({.x = static_cast<std::uint16_t>(point.x - 1), .y = point.y});
      if (previous == nullptr) {
        break;
      }

      if (previous->width == CellWidth::continuation) {
        --point.x;
        continue;
      }

      if (blank(*previous)) {
        break;
      }

      --point.x;
      if (single(*previous) && previous->text[0] == '/') {
        slash = point;
      }
    }

    return slash.value_or(marker);
  }

  [[nodiscard]] static std::optional<std::uint16_t> countCells(AttachmentMarkerScreen screen, CellPosition start, CellPosition end) noexcept {
    if (screen.columns < 2 || start.y >= screen.rows || start.x >= screen.columns) {
      return std::nullopt;
    }

    Scan scan{screen, start};
    std::uint16_t count = 0;
    for (;;) {
      if (scan.rawPosition() == end) {
        return count;
      }

      const auto point = scan.position();
      const auto *const value = point ? screen.cell(*point) : nullptr;
      if (value == nullptr) {
        return std::nullopt;
      }

      count = static_cast<std::uint16_t>(count + (value->width != CellWidth::continuation ? 1 : 0));
      if (count > maximum_cells) {
        return std::nullopt;
      }

      scan.step();
    }
  }

  [[nodiscard]] static PathAttachmentMarker extend(AttachmentMarkerScreen screen, PathAttachmentMarker head) noexcept {
    head.start = pathStart(screen, head.start);
    head.cells = countCells(screen, head.start, head.end);

    return head;
  }
};

}
