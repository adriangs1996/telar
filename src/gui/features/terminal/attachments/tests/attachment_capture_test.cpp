#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdint>
#include <initializer_list>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string_view>

import telar.testing;
import telar.gui.features.terminal.attachments;
import telar.gui.foundation.core;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  using namespace telar::gui::features::terminal::attachments;

  constexpr AttachmentTarget first_prompt{.pane_id = 1, .pane_generation = 7};
  constexpr AttachmentTarget replacement_prompt{.pane_id = first_prompt.pane_id, .pane_generation = first_prompt.pane_generation + 1};

  void onlyTheExactCaptureCanCompleteOrCancel() {
    ClipboardCaptureState state;
    const auto first_value = state.reserve(first_prompt);

    check(first_value.hasValue(), "the first valid prompt must reserve a capture");
    const auto first = *first_value;

    check(!state.reserve(replacement_prompt), "only one capture may run at a time");
    check(!state.finish(first.id + 1) && state.current() == first, "a different completion must retain the current capture");
    check(!state.cancel(replacement_prompt) && state.current() == first, "the same pane's other generation cannot cancel a capture");
    check(state.cancel(first_prompt) && !state.current(), "the exact prompt must cancel its capture");

    const auto second_value = state.reserve(replacement_prompt);

    check(second_value.hasValue(), "a cancelled capture must release its reservation");
    const auto second = *second_value;

    check(second.id == first.id + 1, "cancellation must not reuse the capture identity");
    check(!state.finish(first.id) && state.current() == second, "a late worker cannot consume a newer capture");
    check(state.finish(second.id) == second && !state.current(), "the matching result must transfer its capture exactly once");
    check(!state.finish(second.id), "a repeated result must be ignored");
  }

  void busyPrecedesInvalidInputAndExhaustion() {
    constexpr auto final_id = std::numeric_limits<std::uint64_t>::max();
    ClipboardCaptureState state{final_id};
    const auto final_value = state.reserve(first_prompt);

    check(final_value.hasValue(), "the final nonzero identity must remain valid");
    const auto final = *final_value;

    check(final.id == final_id && state.nextId() == ClipboardCapture::invalid_id, "the next identity must become the exhausted sentinel");
    check(!state.reserve(AttachmentTarget{}), "a busy state must reject without validating another request");
    check(state.finish(final_id) == final, "the final capture must complete normally");

    try {
      static_cast<void>(state.reserve(first_prompt));
      check(false, "exhausted identities must not wrap back to a valid capture");
    } catch (const std::overflow_error& error) {
      check(std::string_view{error.what()} == "ClipboardCaptureIdExhausted", "identity exhaustion must preserve the original failure name");
    }
  }

  void invalidTargetsPreserveTheNextIdentity() {
    ClipboardCaptureState state;
    const AttachmentTarget no_target{};
    const AttachmentTarget no_generation{.pane_id = first_prompt.pane_id};
    const AttachmentTarget no_pane{.pane_generation = first_prompt.pane_generation};
    const std::initializer_list invalid_targets{no_target, no_generation, no_pane};

    for (const auto target : invalid_targets) {
      try {
        static_cast<void>(state.reserve(target));
        check(false, "a missing pane identity or generation must be rejected");
      } catch (const std::invalid_argument& error) {
        check(std::string_view{error.what()} == "InvalidAttachmentTarget", "invalid captures must preserve the original failure name");
      }

      check(!state.current() && state.nextId() == ClipboardCapture::first_id, "failed admission must neither reserve nor consume an identity");
    }
  }

  const telar::testing::Case case_only_the_exact_capture_can_complete_or_cancel{"attachment_capture.only_the_exact_capture_can_complete_or_cancel", onlyTheExactCaptureCanCompleteOrCancel};
  const telar::testing::Case case_busy_precedes_invalid_input_and_exhaustion{"attachment_capture.busy_precedes_invalid_input_and_exhaustion", busyPrecedesInvalidInputAndExhaustion};
  const telar::testing::Case case_invalid_targets_preserve_the_next_identity{"attachment_capture.invalid_targets_preserve_the_next_identity", invalidTargetsPreserveTheNextIdentity};

}
