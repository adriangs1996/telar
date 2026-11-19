#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/allocator.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_wire/protocol/pane_io.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <cstddef>
#include <cstring>
#include <limits>
#include <span>
#include <stdexcept>
#include <string_view>

import telar.testing;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.wire.editor;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::application::tests::session_fixture;

  class SuggestionTransport final : public Transport {
  public:
    void send(std::span<const Byte> message) override {
      const auto tag = static_cast<ClientTag>(message.front());
      if (tag == MessageSchema<SuggestCommand>::tag && reject_request) {
        throw std::length_error{"Suggestion queue is full"};
      }

      if (tag == MessageSchema<PaneInput>::tag && reject_paste) {
        throw std::length_error{"Paste queue is full"};
      }

      Transport::send(message);
    }

    bool reject_request = false;
    bool reject_paste = false;
  };

  void requestingAndEditingKeepOneCurrentResponse() {
    SystemAllocator memory;
    SuggestionTransport transport;
    TestSession client{memory, transport};

    application::palette::suggest(client);
    check(!application::palette::submit(client, "task") && application::palette::suggestion(client).phase == application::palette::SuggestionPhase::failed && transport.count(ClientTag::suggest_command) == 0, "a missing pane must fail locally instead of asking without context");
    openFirstPane(client, transport);
    application::palette::suggest(client);
    check(!application::palette::submit(client, {}) && transport.count(ClientTag::suggest_command) == 0, "an empty task must not create a request");
    check(!application::palette::submit(client, "describe the files") && application::palette::suggestion(client).phase == application::palette::SuggestionPhase::waiting, "the first submit must request a suggestion while retaining the prompt");
    const auto first = transport.last<SuggestCommand>();

    check(first.pane_id == 1 && first.text == "describe the files", "the request must retain the focused pane and the entire task");
    check(!application::palette::submit(client, "duplicate") && transport.count(ClientTag::suggest_command) == 1 && transport.count(ClientTag::pane_input) == 0, "repeated Enter while waiting must not queue another provider request");
    application::palette::discard(client);
    check(deliver(client, CommandSuggestion{.request_id = first.request_id, .text = "obsolete"}) == application::Change::none, "editing must retire the old request before its wire response arrives");
    check(!application::palette::submit(client, "new task"), "an edited task must request a replacement instead of pasting the old command");
    const auto second = transport.last<SuggestCommand>();

    check(second.request_id != first.request_id, "a replacement must own another request identity");
    check(deliver(client, CommandSuggestion{.request_id = second.request_id, .text = "printf 'review first'"}) == application::Change::suggestion, "the current wire response must publish the suggestion");
    const auto before_input = transport.sent.size();

    check(application::palette::submit(client, "new task") && transport.inputSince(before_input) == "printf 'review first'", "the second submit must paste the landed command without Enter");
    client.disconnected();
    check(application::palette::suggestion(client).phase == application::palette::SuggestionPhase::idle && application::palette::suggestion(client).text.empty(), "disconnecting must discard the disposable suggestion");
  }

  void rejectedRequestsAndPastesRemainRetryable() {
    SystemAllocator system;
    BudgetAllocator budget{system, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;
    SuggestionTransport transport;

    {
      TestSession client{memory, transport};

      openFirstPane(client, transport);
      application::palette::suggest(client);
      transport.reject_request = true;
      bool request_rejected = false;

      try {
        static_cast<void>(application::palette::submit(client, "task"));
      } catch (const std::length_error&) {
        request_rejected = true;
      }

      check(request_rejected && application::palette::suggestion(client).phase == application::palette::SuggestionPhase::idle && application::palette::suggestion(client).pending_request == 0, "rejected request admission must not leave a waiting generation");
      transport.reject_request = false;
      check(!application::palette::submit(client, "task"), "a rejected request must be retryable");
      const auto request = transport.last<SuggestCommand>();

      check(deliver(client, CommandSuggestion{.request_id = request.request_id, .text = "echo review"}) == application::Change::suggestion, "the admitted retry must own its response");
      FrameBody frame;

      frame.pane_id = 1;
      frame.frame_id = 1;
      frame.cols = frame.rows = 1;
      frame.scroll.total_rows = 1;
      frame.input_modes.bracketed_paste = true;
      deliverSingleCell(client, frame);
      transport.reject_paste = true;
      bool paste_rejected = false;

      try {
        static_cast<void>(application::palette::submit(client, "task"));
      } catch (const std::length_error&) {
        paste_rejected = true;
      }

      check(paste_rejected && transport.count(ClientTag::pane_input) == 0 && application::palette::suggestion(client).phase == application::palette::SuggestionPhase::ready, "a rejected paste must retain the command and deliver no partial marker");
      transport.reject_paste = false;
      const auto before_input = transport.sent.size();

      check(application::palette::submit(client, "task") && transport.count(ClientTag::pane_input) == 1 && transport.inputSince(before_input) == "\x1b[200~echo review\x1b[201~", "a retry must admit the entire bracketed command in one frame");
    }

    check(budget.liveBytes() == 0, "suggestion requests and replies must release all injected session allocations");
  }

  void unsafeRuntimeTextCannotBecomeTerminalInput() {
    SystemAllocator memory;
    SuggestionTransport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    application::palette::suggest(client);
    check(!application::palette::submit(client, "task"), "the unsafe-response fixture must ask first");
    const auto request = transport.last<SuggestCommand>();

    deliver(client, CommandSuggestion{.request_id = request.request_id, .text = "echo unsafe\x1b[201~\r"});
    bool rejected = false;

    try {
      static_cast<void>(application::palette::submit(client, "task"));
    } catch (const EncodingError&) {
      rejected = true;
    }

    check(rejected && transport.count(ClientTag::pane_input) == 0, "a malformed runtime suggestion must not break out of paste framing or execute a command");
  }

  const telar::testing::Case case_requesting_and_editing_keep_one_current_response{"suggestion_session.requesting_and_editing_keep_one_current_response", requestingAndEditingKeepOneCurrentResponse};
  const telar::testing::Case case_rejected_requests_and_pastes_remain_retryable{"suggestion_session.rejected_requests_and_pastes_remain_retryable", rejectedRequestsAndPastesRemainRetryable};
  const telar::testing::Case case_unsafe_runtime_text_cannot_become_terminal_input{"suggestion_session.unsafe_runtime_text_cannot_become_terminal_input", unsafeRuntimeTextCannotBecomeTerminalInput};

}
