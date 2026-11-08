#include "assertions.hpp"
#include "attachments/marker_screen.hpp"
#include "attachments/numeric_markers.hpp"
#include "attachments/path_markers.hpp"
#include "terminal/cell_position.hpp"
#include "terminal/screen.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <optional>
#include <span>
#include <string_view>

namespace {

using namespace telar::gui;
using telar::gui::test::require;
using telar::gui::test::requireValue;
constexpr CellPosition origin{};
constexpr std::uint16_t wrapped_end = 5;

constexpr std::uint16_t columns = 80;
constexpr std::uint16_t rows = 4;
using Cells = std::array<CellValue, static_cast<std::size_t>(columns) * rows>;

void text(Cells &cells, CellPosition point, std::string_view value) {
  for (std::size_t index = 0; index < value.size(); ++index) {
    cells[(static_cast<std::size_t>(point.y) * columns) + point.x + index].text[0] = static_cast<std::uint8_t>(value[index]);
  }
}

void wrappedPlaceholdersAndNearestPrompt() {
  Cells cells;
  text(cells, origin, "[Image #7]");
  constexpr std::uint16_t prompt_row = 2;
  constexpr std::uint16_t wrapped_start = columns - 6;
  text(cells, {.x = wrapped_start, .y = prompt_row}, "[Image");
  text(cells, {.x = 2, .y = prompt_row + 1}, "#7]");
  const AttachmentMarkerScreen screen{.cells = cells, .columns = columns, .rows = rows, .cursor = {.visible = true, .x = wrapped_end, .y = prompt_row + 1}};
  const auto marker = NumericAttachmentMarkers::closest(screen, 7);
  require(marker && marker->start == CellPosition{.x = wrapped_start, .y = prompt_row} && marker->end == CellPosition{.x = wrapped_end, .y = prompt_row + 1}, "wrapped placeholders must retain both rows and choose the prompt nearest to its cursor");
  NumericAttachmentMarkers scan{screen};
  const auto first = requireValue(scan.next(), "the first marker must be present");
  const auto second = requireValue(scan.next(), "the wrapped marker must be present");
  require(first.start.y == 0 && second.start.y == prompt_row && !scan.next(), "scanning must preserve row-major order across wrapped placeholders");
}

void malformedNumbersAndAtomicEditorSteps() {
  Cells cells;
  text(cells, origin, "[Image #0] [Image #65536] [Image #3]");
  const AttachmentMarkerScreen screen{.cells = cells, .columns = columns, .rows = rows, .cursor = {}};
  require(!NumericAttachmentMarkers::parse(screen, {}), "zero cannot name an image marker");
  constexpr std::uint16_t oversized_start = 11;
  require(!NumericAttachmentMarkers::parse(screen, {.x = oversized_start}), "marker numbers must not overflow uint16");
  constexpr std::uint16_t valid_start = 26;
  const auto valid = requireValue(NumericAttachmentMarkers::parse(screen, {.x = valid_start}), "the final marker must parse");
  require(valid.number == 3, "an invalid earlier marker must not hide later valid placeholders");
  const auto steps = NumericAttachmentMarkers::steps(screen, 0, valid_start, valid.end.x);
  require(steps == 1, "a complete atomic placeholder occupies one editor navigation step");
}

void pathMarkersRetainExactIdentityAndStartAtThePath() {
  Cells cells;
  constexpr std::string_view path = "/tmp/pi-clipboard-12345678-1234-ABCD-1234-123456789abc.png";
  text(cells, origin, path);
  constexpr std::size_t capacity = 8;
  std::array<PathAttachmentMarker, capacity> found{};
  const AttachmentMarkerScreen screen{.cells = cells, .columns = columns, .rows = rows, .cursor = {.visible = true, .x = static_cast<std::uint16_t>(path.size())}};
  require(PathAttachmentMarkers::collect(screen, found) == 1, "a UUID image path must be recognized");
  require(found[0].start == CellPosition{} && found[0].end.x == path.size() && found[0].cells == path.size(), "the marker must include the complete path before its file name");
  require(PathAttachmentMarkers::find(screen, found[0].uuid).has_value() && PathAttachmentMarkers::cursorAt(screen, found[0].end), "path identity and cursor boundary must agree");
}

}

int main() try {
  wrappedPlaceholdersAndNearestPrompt();
  malformedNumbersAndAtomicEditorSteps();
  pathMarkersRetainExactIdentityAndStartAtThePath();

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
