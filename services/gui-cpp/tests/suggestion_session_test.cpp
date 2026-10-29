#include "application/session.hpp"
#include "assertions.hpp"
#include "core/memory.hpp"
#include "session_fixture.hpp"
#include "suggestions/state.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <concepts>
#include <cstddef>
#include <exception>
#include <iostream>
#include <limits>
#include <stdexcept>

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::test;

class SuggestionTransport : public Transport {
public:
  template <typename Message>
  void send(const Message &message) {
    if constexpr (std::same_as<Message, SuggestCommand>) {
      if (reject_request) {
        throw std::length_error{"Suggestion queue is full"};
      }
    }

    if constexpr (std::same_as<Message, PaneInput>) {
      if (reject_paste) {
        throw std::length_error{"Paste queue is full"};
      }
    }

    Transport::send(message);
  }

  bool reject_request = false;
  bool reject_paste = false;
};

void requestingAndEditingKeepOneCurrentResponse() {
  SystemAllocator memory;
  SuggestionTransport transport;
  Session client{memory, transport};
  client.beginSuggestion();
  require(!client.submitSuggestion("task") && client.suggestion().phase() == SuggestionPhase::failed && transport.count(ClientTag::suggest_command) == 0, "a missing pane must fail locally instead of asking without context");
  openFirstPane(client, transport);
  client.beginSuggestion();
  require(!client.submitSuggestion({}) && transport.count(ClientTag::suggest_command) == 0, "an empty task must not create a request");
  require(!client.submitSuggestion("describe the files") && client.suggestion().phase() == SuggestionPhase::waiting, "the first submit must request a suggestion while retaining the prompt");
  const auto first = transport.last<SuggestCommand>();
  require(first.pane_id == 1 && first.text == "describe the files", "the request must retain the focused pane and the entire task");
  require(!client.submitSuggestion("duplicate") && transport.count(ClientTag::suggest_command) == 1 && transport.count(ClientTag::pane_input) == 0, "repeated Enter while waiting must not queue another provider request");
  client.invalidateSuggestion();
  require(deliver(client, CommandSuggestion{.request_id = first.request_id, .text = "obsolete"}) == Change::none, "editing must retire the old request before its wire response arrives");
  require(!client.submitSuggestion("new task"), "an edited task must request a replacement instead of pasting the old command");
  const auto second = transport.last<SuggestCommand>();
  require(second.request_id != first.request_id, "a replacement must own another request identity");
  require(deliver(client, CommandSuggestion{.request_id = second.request_id, .text = "printf 'review first'"}) == Change::suggestion, "the current wire response must publish the suggestion");
  const auto before_input = transport.sent.size();
  require(client.submitSuggestion("new task") && transport.inputSince(before_input) == "printf 'review first'", "the second submit must paste the landed command without Enter");
  client.disconnected();
  require(client.suggestion().phase() == SuggestionPhase::idle && client.suggestion().text().empty(), "disconnecting must discard the disposable suggestion");
}

void rejectedRequestsAndPastesRemainRetryable() {
  SystemAllocator system;
  BudgetAllocator memory{system, std::numeric_limits<std::size_t>::max()};
  SuggestionTransport transport;
  {
    Session client{memory, transport};
    openFirstPane(client, transport);
    client.beginSuggestion();
    transport.reject_request = true;
    bool request_rejected = false;
    try {
      static_cast<void>(client.submitSuggestion("task"));
    } catch (const std::length_error &) {
      request_rejected = true;
    }

    require(request_rejected && client.suggestion().phase() == SuggestionPhase::idle && client.suggestion().pendingRequest() == 0, "rejected request admission must not leave a waiting generation");
    transport.reject_request = false;
    require(!client.submitSuggestion("task"), "a rejected request must be retryable");
    const auto request = transport.last<SuggestCommand>();
    require(deliver(client, CommandSuggestion{.request_id = request.request_id, .text = "echo review"}) == Change::suggestion, "the admitted retry must own its response");
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
      static_cast<void>(client.submitSuggestion("task"));
    } catch (const std::length_error &) {
      paste_rejected = true;
    }

    require(paste_rejected && transport.count(ClientTag::pane_input) == 0 && client.suggestion().phase() == SuggestionPhase::ready, "a rejected paste must retain the command and deliver no partial marker");
    transport.reject_paste = false;
    const auto before_input = transport.sent.size();
    require(client.submitSuggestion("task") && transport.count(ClientTag::pane_input) == 1 && transport.inputSince(before_input) == "\x1b[200~echo review\x1b[201~", "a retry must admit the entire bracketed command in one frame");
  }

  require(memory.liveBytes() == 0, "suggestion requests and replies must release all injected session allocations");
}

void unsafeRuntimeTextCannotBecomeTerminalInput() {
  SystemAllocator memory;
  SuggestionTransport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  client.beginSuggestion();
  require(!client.submitSuggestion("task"), "the unsafe-response fixture must ask first");
  const auto request = transport.last<SuggestCommand>();
  deliver(client, CommandSuggestion{.request_id = request.request_id, .text = "echo unsafe\x1b[201~\r"});
  bool rejected = false;
  try {
    static_cast<void>(client.submitSuggestion("task"));
  } catch (const EncodingError &) {
    rejected = true;
  }

  require(rejected && transport.count(ClientTag::pane_input) == 0, "a malformed runtime suggestion must not break out of paste framing or execute a command");
}

}

int main() {
  try {
    requestingAndEditingKeepOneCurrentResponse();
    rejectedRequestsAndPastesRemainRetryable();
    unsafeRuntimeTextCannotBecomeTerminalInput();
    std::cout << "gui-suggestion-session: passed\n";
  } catch (const std::exception &error) {
    std::cerr << "gui-suggestion-session: " << error.what() << '\n';

    return 1;
  }
}
