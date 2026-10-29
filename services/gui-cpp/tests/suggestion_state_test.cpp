#include "assertions.hpp"
#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "input/paste_encoding.hpp"
#include "presentation/palette_geometry.hpp"
#include "presentation/suggestion_geometry.hpp"
#include "presentation/suggestion_labels.hpp"
#include "presentation/suggestion_preview.hpp"
#include "suggestions/limits.hpp"
#include "suggestions/state.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "terminal/font_grid.hpp"
#include <cstddef>
#include <exception>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>

namespace {

using namespace telar;
using namespace telar::gui;
using telar::gui::test::require;

void repliesBelongToOnlyTheCurrentRequest() {
  SuggestionState state;
  state.begin();
  require(state.phase() == SuggestionPhase::idle && state.revision() == 1, "opening must start an empty suggestion generation");
  state.expect(1);
  state.expect(2);
  require(!state.receive({.request_id = 0, .text = "zero"}) && !state.receive({.request_id = 1, .text = "stale"}), "zero and superseded replies must not replace the current generation");
  std::string command = "printf 'review first'";
  require(state.receive({.request_id = 2, .text = command}), "the awaited reply must land");
  command.assign("destroyed");
  require(state.phase() == SuggestionPhase::ready && state.pendingRequest() == 0 && state.text() == "printf 'review first'", "a ready suggestion must own its text after the decoder buffer changes");
  require(!state.receive({.request_id = 2, .text = "duplicate"}), "a duplicate response must not replace a landed command");
  state.invalidate();
  const auto revision = state.revision();
  state.invalidate();
  require(state.revision() == revision && state.text().empty(), "editing an already idle request must not publish another state revision");
  state.expect(3);
  state.invalidate();
  require(!state.receive({.request_id = 3, .text = "cancelled"}) && state.phase() == SuggestionPhase::idle, "editing or cancelling must retire an in-flight response");
}

void emptyAndFailedRepliesRemainRetryable() {
  SuggestionState state;
  state.expect(1);
  require(state.receive({.request_id = 1}), "an empty ready response must still consume its request");
  require(state.phase() == SuggestionPhase::failed && SuggestionLabels::message(state.phase(), state.status()) == "The engine returned no command. Try again.", "an empty response must show the original retry message");
  state.expect(2);
  require(state.receive({.request_id = 2, .status = SuggestionStatus::unavailable}), "an unavailable provider must settle the request");
  require(SuggestionLabels::message(state.phase(), state.status()) == "Configure runtime.engine to enable suggestions.", "an unavailable provider must point to its actual runtime configuration");
  state.begin();
  require(state.status() == SuggestionStatus::unavailable && state.phase() == SuggestionPhase::idle, "opening must preserve the original last-status semantics while resetting the phase");
  require(!SuggestionLabels::canSubmit(SuggestionPhase::idle, {}) && !SuggestionLabels::canSubmit(SuggestionPhase::waiting, "task") && SuggestionLabels::canSubmit(SuggestionPhase::ready, {}), "only a nonempty idle query or a ready command may submit");
  state.expect(3);
  const std::string command(SuggestionLimits::text_bytes, 'x');
  require(state.receive({.request_id = 3, .text = command}) && state.text().size() == SuggestionLimits::text_bytes, "the full wire-sized command must fit without truncation");
}

void previewShorteningDoesNotAlterTheCommand() {
  constexpr FontGrid grid{.width = 1, .height = 1};
  constexpr Rect bounds{.width = 4, .height = 2};
  constexpr std::string_view command = "abcdefghijkl";
  SuggestionPreview preview{command, bounds, grid};
  const auto first = preview.next();
  const auto last = preview.next();
  require(first && first->text == "abcd" && !first->shortened, "the preview must wrap on the terminal column budget");
  require(last && last->text == SuggestionPreview::shortened_message && last->shortened && !preview.next(), "the last visible row must announce hidden command text instead of painting a partial command");
  require(command == "abcdefghijkl", "preview clipping must leave the eventual paste unchanged");
  SuggestionPreview exact{"abcdefgh", bounds, grid};
  require(exact.next().has_value(), "an exact preview must have its first line");
  const auto ending = exact.next();
  require(ending && ending->text == "efgh" && !ending->shortened && !exact.next(), "an exact final line must remain visible without a shortening notice");
}

void geometrySharesTheExistingPaletteFrame() {
  constexpr Rect viewport{.width = 1180, .height = 720};
  const ChromeMetrics chrome;
  const auto palette = PaletteGeometry::measure(viewport, chrome, {.pick_rows = std::nullopt, .suggest = true});
  const auto geometry = SuggestionGeometry::measure(palette, chrome, false);
  const auto nested = SuggestionGeometry::measure(palette, chrome, true);
  require(geometry.back.empty() && !nested.back.empty() && nested.title.x > geometry.title.x, "only a nested suggestion must reserve a back button in the heading");
  require(geometry.preview.x > geometry.body.x && geometry.preview.width < geometry.body.width && geometry.message.y > geometry.heading.y, "the preview and messages must follow the original panel insets and heading gap");
  require(geometry.button.right() <= palette.footer.right() && geometry.footer_caption.right() < geometry.button.x, "the review caption and submit button must stay inside their shared footer without overlap");
}

void pasteEncodingKeepsTheLiteralBytesAndCapacity() {
  constexpr std::size_t capacity = 8;
  require(PasteEncoding::encode<capacity>("echo x", false).view() == "echo x", "plain paste must preserve the exact command bytes");
  require(PasteEncoding::encode<capacity>("echo x", true).view() == "\x1b[200~echo x\x1b[201~", "bracketed paste must be one complete encoded value without Enter");
  bool rejected = false;
  try {
    static_cast<void>(PasteEncoding::encode<capacity>("too many bytes", true));
  } catch (const std::length_error &) {
    rejected = true;
  }

  require(rejected, "paste framing space must not admit text beyond its explicit capacity");
}

}

int main() {
  try {
    repliesBelongToOnlyTheCurrentRequest();
    emptyAndFailedRepliesRemainRetryable();
    previewShorteningDoesNotAlterTheCommand();
    geometrySharesTheExistingPaletteFrame();
    pasteEncodingKeepsTheLiteralBytesAndCapacity();
    std::cout << "gui-suggestion-state: passed\n";
  } catch (const std::exception &error) {
    std::cerr << "gui-suggestion-state: " << error.what() << '\n';

    return 1;
  }
}
