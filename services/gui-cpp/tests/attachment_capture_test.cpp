#include "assertions.hpp"
#include "attachments/capture_state.hpp"
#include "attachments/types.hpp"
#include <cstdint>
#include <exception>
#include <iostream>
#include <initializer_list>
#include <limits>
#include <stdexcept>
#include <string_view>

namespace {

using namespace telar::gui;
using telar::gui::test::require;
using telar::gui::test::requireValue;

constexpr AttachmentTarget first_prompt{.pane_id = 1, .pane_generation = 7};
constexpr AttachmentTarget replacement_prompt{.pane_id = first_prompt.pane_id, .pane_generation = first_prompt.pane_generation + 1};

void onlyTheExactCaptureCanCompleteOrCancel() {
  ClipboardCaptureState state;
  const auto first = requireValue(state.reserve(first_prompt), "the first valid prompt must reserve a capture");
  require(!state.reserve(replacement_prompt), "only one capture may run at a time");
  require(!state.finish(first.id + 1) && state.current() == first, "a different completion must retain the current capture");
  require(!state.cancel(replacement_prompt) && state.current() == first, "the same pane's other generation cannot cancel a capture");
  require(state.cancel(first_prompt) && !state.current(), "the exact prompt must cancel its capture");

  const auto second = requireValue(state.reserve(replacement_prompt), "a cancelled capture must release its reservation");
  require(second.id == first.id + 1, "cancellation must not reuse the capture identity");
  require(!state.finish(first.id) && state.current() == second, "a late worker cannot consume a newer capture");
  require(state.finish(second.id) == second && !state.current(), "the matching result must transfer its capture exactly once");
  require(!state.finish(second.id), "a repeated result must be ignored");
}

void busyPrecedesInvalidInputAndExhaustion() {
  constexpr auto final_id = std::numeric_limits<std::uint64_t>::max();
  ClipboardCaptureState state{final_id};
  const auto final = requireValue(state.reserve(first_prompt), "the final nonzero identity must remain valid");
  require(final.id == final_id && state.nextId() == ClipboardCapture::invalid_id, "the next identity must become the exhausted sentinel");
  require(!state.reserve(AttachmentTarget{}), "a busy state must reject without validating another request");
  require(state.finish(final_id) == final, "the final capture must complete normally");

  try {
    static_cast<void>(state.reserve(first_prompt));
    require(false, "exhausted identities must not wrap back to a valid capture");
  } catch (const std::overflow_error &error) {
    require(std::string_view{error.what()} == "ClipboardCaptureIdExhausted", "identity exhaustion must preserve the original failure name");
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
      require(false, "a missing pane identity or generation must be rejected");
    } catch (const std::invalid_argument &error) {
      require(std::string_view{error.what()} == "InvalidAttachmentTarget", "invalid captures must preserve the original failure name");
    }

    require(!state.current() && state.nextId() == ClipboardCapture::first_id, "failed admission must neither reserve nor consume an identity");
  }
}

}

int main() try {
  onlyTheExactCaptureCanCompleteOrCancel();
  busyPrecedesInvalidInputAndExhaustion();
  invalidTargetsPreserveTheNextIdentity();

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
