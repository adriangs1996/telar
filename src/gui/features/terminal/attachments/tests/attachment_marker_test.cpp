#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>

import telar.testing;
import telar.gui.features.terminal.attachments;
import telar.gui.foundation.terminal;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  using namespace telar::gui::features::terminal::attachments;
  constexpr CellPosition origin{};
  constexpr std::uint16_t wrapped_end = 5;

  constexpr std::uint16_t columns = 80;
  constexpr std::uint16_t rows = 4;
  using Cells = std::array<CellValue, static_cast<std::size_t>(columns) * rows>;

  void text(Cells& cells, CellPosition point, std::string_view value) {
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

    check(marker && marker->start == CellPosition{.x = wrapped_start, .y = prompt_row} && marker->end == CellPosition{.x = wrapped_end, .y = prompt_row + 1}, "wrapped placeholders must retain both rows and choose the prompt nearest to its cursor");
    NumericAttachmentMarkers scan{screen};
    const auto first_value = scan.next();

    check(first_value.has_value(), "the first marker must be present");
    const auto first = *first_value;
    const auto second_value = scan.next();

    check(second_value.has_value(), "the wrapped marker must be present");
    const auto second = *second_value;

    check(first.start.y == 0 && second.start.y == prompt_row && !scan.next(), "scanning must preserve row-major order across wrapped placeholders");
  }

  void malformedNumbersAndAtomicEditorSteps() {
    Cells cells;

    text(cells, origin, "[Image #0] [Image #65536] [Image #3]");
    const AttachmentMarkerScreen screen{.cells = cells, .columns = columns, .rows = rows, .cursor = {}};

    check(!NumericAttachmentMarkers::parse(screen, {}), "zero cannot name an image marker");
    constexpr std::uint16_t oversized_start = 11;

    check(!NumericAttachmentMarkers::parse(screen, {.x = oversized_start}), "marker numbers must not overflow uint16");
    constexpr std::uint16_t valid_start = 26;
    const auto valid_value = NumericAttachmentMarkers::parse(screen, {.x = valid_start});

    check(valid_value.has_value(), "the final marker must parse");
    const auto valid = *valid_value;

    check(valid.number == 3, "an invalid earlier marker must not hide later valid placeholders");
    const auto steps = NumericAttachmentMarkers::steps(screen, 0, valid_start, valid.end.x);

    check(steps == 1, "a complete atomic placeholder occupies one editor navigation step");
  }

  void pathMarkersRetainExactIdentityAndStartAtThePath() {
    Cells cells;
    constexpr std::string_view path = "/tmp/pi-clipboard-12345678-1234-ABCD-1234-123456789abc.png";

    text(cells, origin, path);
    constexpr std::size_t capacity = 8;
    std::array<PathAttachmentMarker, capacity> found{};
    const AttachmentMarkerScreen screen{.cells = cells, .columns = columns, .rows = rows, .cursor = {.visible = true, .x = static_cast<std::uint16_t>(path.size())}};

    check(PathAttachmentMarkers::collect(screen, found) == 1, "a UUID image path must be recognized");
    check(found[0].start == CellPosition{} && found[0].end.x == path.size() && found[0].cells == path.size(), "the marker must include the complete path before its file name");
    check(PathAttachmentMarkers::find(screen, found[0].uuid).has_value() && PathAttachmentMarkers::cursorAt(screen, found[0].end), "path identity and cursor boundary must agree");
  }

  const telar::testing::Case case_wrapped_placeholders_and_nearest_prompt{"attachment_marker.wrapped_placeholders_and_nearest_prompt", wrappedPlaceholdersAndNearestPrompt};
  const telar::testing::Case case_malformed_numbers_and_atomic_editor_steps{"attachment_marker.malformed_numbers_and_atomic_editor_steps", malformedNumbersAndAtomicEditorSteps};
  const telar::testing::Case case_path_markers_retain_exact_identity_and_start_at_the_path{"attachment_marker.path_markers_retain_exact_identity_and_start_at_the_path", pathMarkersRetainExactIdentityAndStartAtThePath};

}
