#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif
#include "assertions.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include <algorithm>
#include <array>
#include <bit>
#include <charconv>
#include <chrono>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <ghostty/vt/unicode.h>
#include <iostream>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>

import telar.gui.foundation.core;
import telar.gui.foundation.keys;
import telar.gui.foundation.forms;
import telar.gui.features.palette;
import telar.gui.foundation.model;
import telar.gui.foundation.terminal;
import telar.base.ds;
import telar.wire.vocabulary;

namespace {

  using namespace telar;
  using namespace telar::gui;
  using features::palette::PaletteGeometry;
  using features::palette::SuggestionGeometry;
  using features::palette::SuggestionLabels;
  using features::palette::SuggestionPhase;
  using telar::gui::test::require;

  void repliesBelongToOnlyTheCurrentRequest() {
    features::palette::State state;

    features::palette::suggest(state);
    require(features::palette::suggestion(state).phase == SuggestionPhase::idle && features::palette::suggestion(state).revision == 1, "opening must start an empty suggestion generation");
    features::palette::wait(state, 1);
    features::palette::wait(state, 2);
    require(!features::palette::receive(state, {.request_id = 0, .text = "zero"}) && !features::palette::receive(state, {.request_id = 1, .text = "stale"}), "zero and superseded replies must not replace the current generation");
    std::string command = "printf 'review first'";

    require(features::palette::receive(state, {.request_id = 2, .text = command}), "the awaited reply must land");
    command.assign("destroyed");
    require(features::palette::suggestion(state).phase == SuggestionPhase::ready && features::palette::suggestion(state).pending_request == 0 && features::palette::suggestion(state).text == "printf 'review first'", "a ready suggestion must own its text after the decoder buffer changes");
    require(!features::palette::receive(state, {.request_id = 2, .text = "duplicate"}), "a duplicate response must not replace a landed command");
    features::palette::discard(state);
    const auto revision = features::palette::suggestion(state).revision;

    features::palette::discard(state);
    require(features::palette::suggestion(state).revision == revision && features::palette::suggestion(state).text.empty(), "editing an already idle request must not publish another state revision");
    features::palette::wait(state, 3);
    features::palette::discard(state);
    require(!features::palette::receive(state, {.request_id = 3, .text = "cancelled"}) && features::palette::suggestion(state).phase == SuggestionPhase::idle, "editing or cancelling must retire an in-flight response");
  }

  void emptyAndFailedRepliesRemainRetryable() {
    features::palette::State state;

    features::palette::wait(state, 1);
    require(features::palette::receive(state, {.request_id = 1}), "an empty ready response must still consume its request");
    require(features::palette::suggestion(state).phase == SuggestionPhase::failed && SuggestionLabels::message(features::palette::suggestion(state).phase, features::palette::suggestion(state).status) == "The engine returned no command. Try again.", "an empty response must show the original retry message");
    features::palette::wait(state, 2);
    require(features::palette::receive(state, {.request_id = 2, .status = SuggestionStatus::unavailable}), "an unavailable provider must settle the request");
    require(SuggestionLabels::message(features::palette::suggestion(state).phase, features::palette::suggestion(state).status) == "Configure runtime.engine to enable suggestions.", "an unavailable provider must point to its actual runtime configuration");
    features::palette::suggest(state);
    require(features::palette::suggestion(state).status == SuggestionStatus::unavailable && features::palette::suggestion(state).phase == SuggestionPhase::idle, "opening must preserve the original last-status semantics while resetting the phase");
    require(!SuggestionLabels::canSubmit(SuggestionPhase::idle, {}) && !SuggestionLabels::canSubmit(SuggestionPhase::waiting, "task") && SuggestionLabels::canSubmit(SuggestionPhase::ready, {}), "only a nonempty idle query or a ready command may submit");
    features::palette::wait(state, 3);
    const std::string command(SuggestionLimits::text_bytes, 'x');

    require(features::palette::receive(state, {.request_id = 3, .text = command}) && features::palette::suggestion(state).text.size() == SuggestionLimits::text_bytes, "the full wire-sized command must fit without truncation");
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

    require(exact.next().hasValue(), "an exact preview must have its first line");
    const auto ending = exact.next();

    require(ending && ending->text == "efgh" && !ending->shortened && !exact.next(), "an exact final line must remain visible without a shortening notice");
  }

  void geometrySharesTheExistingPaletteFrame() {
    constexpr Rect viewport{.width = 1180, .height = 720};
    const ChromeMetrics chrome;
    const auto palette = PaletteGeometry::measure(viewport, chrome, {.pick_rows = ds::none, .suggest = true});
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
    } catch (const std::length_error&) {
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
  } catch (const std::exception& error) {
    std::cerr << "gui-suggestion-state: " << error.what() << '\n';

    return 1;
  }
}
