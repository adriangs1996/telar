#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <concepts>
#include <cstdint>
#include <optional>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <algorithm>
#include <cstddef>
#include <limits>
#include <string_view>
#include <array>
#include <span>
#include <stdexcept>
#include <charconv>
#include <cstring>
#include <system_error>
#include "../core/memory.hpp"
#include "../core/terminal_size.hpp"
#include <atomic>
#include <exception>
#include "telar_config/graphics/limits.hpp"
#include <utility>
#include <variant>
#include "../terminal/screen.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "../terminal/cell_position.hpp"
#include <bit>
#include <tuple>
#include <cmath>
#include "../input/wheel_accumulator.hpp"
#include "telar_base/memory/allocator.hpp"
#include <memory>
#include "assertions.hpp"
#include "session_fixture.hpp"
#include <iostream>
#include <string>

#include "core/memory.hpp"


import telar.gui.application.session;
import telar.gui.paths.label;

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::test;

class PathTransport : public Transport {
public:
  template <typename Message>
  void send(const Message &message) {
    if constexpr (std::same_as<Message, FindPaths>) {
      if (reject_paths) {
        throw std::length_error{"Path queue is full"};
      }
    }

    if constexpr (std::same_as<Message, PaneInput>) {
      if (reject_paste) {
        throw std::length_error{"Input queue is full"};
      }
    }

    Transport::send(message);
  }

  bool reject_paths = false;
  bool reject_paste = false;
};

template <typename Client>
void publishPaths(Client &client, const PathTransport &transport, std::string_view path, PathKind kind = PathKind::file) {
  const auto request = transport.last<FindPaths>();
  const std::array matches{PathMatch{.path = path, .kind = kind}};
  require(deliver(client, PathResults{.request_id = request.request_id, .root = request.root, .complete = true, .matches = matches}) == Change::paths, "the current wire page must update the picker");
}

void searchesUseTheRuntimeAndRetainOnlyCurrentResults() {
  SystemAllocator memory;
  PathTransport transport;
  Session client{memory, transport};
  require(!client.beginPathPicker(), "a disconnected client must not open the path picker");
  openFirstPane(client, transport);
  require(!client.beginPathPicker(), "a pane without a known directory must not search the client filesystem");
  deliver(client, PaneCwd{.pane_id = 1, .cwd = "/work"});
  require(client.beginPathPicker(), "an attached pane with a known directory must open the picker");
  const auto initial = transport.last<FindPaths>();
  require(initial.root == "/work" && initial.query.empty() && initial.refresh && initial.limit == PathPickerLimits::results && initial.kind == PathKindFilter::any, "opening must ask the runtime for its first ranked page and refresh its index");
  const std::string prefix(PathPickerLimits::query_bytes - 1, 'a');
  require(client.requestPaths(prefix + "🧵"), "a long query must remain admissible");
  const auto query = transport.last<FindPaths>();
  require(query.query == prefix && !query.refresh, "wire queries must stop before an incomplete UTF-8 scalar without rebuilding the index");
  const std::array stale{PathMatch{.path = "stale"}};
  require(deliver(client, PathResults{.request_id = initial.request_id, .root = "/work", .complete = true, .matches = stale}) == Change::none, "a superseded wire response must leave the current page untouched");
  require(deliver(client, RequestFailed{.request_id = initial.request_id, .code = FailureCode::invalid_request, .message = "obsolete"}) == Change::none && client.error().empty(), "a tracked obsolete failure must not produce a notification or repaint");
  publishPaths(client, transport, "src/main.cpp");
  require(client.pathPicker().path(client.pathPicker().matches().front()) == "src/main.cpp", "retained paths must survive destruction of the decoder buffer");
  client.closePathPicker();
  require(!client.requestPaths("closed"), "closing must stop further requests");
}

void directoryNavigationKeepsTheOpeningAnchor() {
  SystemAllocator memory;
  PathTransport transport;
  Session client{memory, transport};
  openFirstPane(client, transport);
  deliver(client, PaneCwd{.pane_id = 1, .cwd = "/work"});
  require(client.beginPathPicker(), "the directory fixture must open");
  publishPaths(client, transport, "sub/", PathKind::directory);
  require(client.descendPath(0), "Tab must browse the selected directory");
  auto request = transport.last<FindPaths>();
  require(request.root == "/work/sub" && request.query.empty() && request.refresh && client.pathPicker().anchor() == "/work", "descending must reset the query while retaining the opening directory");
  publishPaths(client, transport, "a b'c.txt");
  const auto first_input = transport.sent.size();
  require(client.insertPath(0, false), "a ready selected file must be insertable");
  require(transport.inputSince(first_input) == "'sub/a b'\\''c.txt'" && transport.count(ClientTag::pane_input) == 1, "insertion must deliver one quoted relative word without executing it");
  require(client.pathPicker().phase() == PathPickerPhase::idle, "successful insertion must close the picker");
  require(client.beginPathPicker() && client.ascendPath(), "Shift+Tab must browse the current root's parent");
  request = transport.last<FindPaths>();
  require(request.root == "/" && request.refresh && !client.ascendPath(), "parent navigation must stop at the filesystem root");
  publishPaths(client, transport, "tmp/file");
  const auto absolute_input = transport.sent.size();
  require(client.insertPath(0, true) && transport.inputSince(absolute_input) == "/tmp/file", "alternate insertion must preserve the absolute path outside the opening directory");
}

template <typename Client>
void enableBracketedPaste(Client &client) {
  FrameBody frame;
  frame.pane_id = 1;
  frame.frame_id = 1;
  frame.cols = 1;
  frame.rows = 1;
  frame.input_modes.bracketed_paste = true;
  frame.scroll.total_rows = 1;
  deliverSingleCell(client, frame);
}

void rejectedDeliveryKeepsThePickerAndPasteAtomic() {
  SystemAllocator system;
  BudgetAllocator memory{system, std::numeric_limits<std::size_t>::max()};
  PathTransport transport;
  {
    Session client{memory, transport};
    openFirstPane(client, transport);
    deliver(client, PaneCwd{.pane_id = 1, .cwd = "/work"});
    transport.reject_paths = true;
    require(client.beginPathPicker() && client.pathPicker().error() == "Path request queue is full; retry", "queue pressure must leave the picker open with its local error");
    require(client.pathPicker().pendingRequest() == 0 && transport.count(ClientTag::find_paths) == 0, "rejected search delivery must not acquire a pending correlation");
    transport.reject_paths = false;
    require(client.requestPaths({}), "retrying an unsent search must remain possible");
    enableBracketedPaste(client);
    publishPaths(client, transport, "-a b");
    transport.reject_paste = true;
    require(!client.insertPath(0, false) && client.pathPicker().error() == "Input is busy; retry", "rejected paste must retain the selected page for a retry");
    require(transport.count(ClientTag::pane_input) == 0 && client.pathPicker().matches().size() == 1, "a rejected bracketed paste must not leave a partial opening marker in the queue");
    transport.reject_paste = false;
    const auto first_input = transport.sent.size();
    require(client.insertPath(0, false), "a retry after queue pressure must succeed");
    require(transport.inputSince(first_input) == "\x1b[200~./'-a b'\x1b[201~" && transport.count(ClientTag::pane_input) == 1, "one admitted frame must contain the entire bracketed paste and no Enter");
    require(client.beginPathPicker(), "a second request must reopen the picker");
    client.disconnected();
    require(client.pathPicker().phase() == PathPickerPhase::idle && !client.requestPaths({}), "disconnecting must retire disposable picker state");
  }

  require(memory.liveBytes() == 0, "path searches must release every injected session allocation");
}

}

int main() {
  try {
    searchesUseTheRuntimeAndRetainOnlyCurrentResults();
    directoryNavigationKeepsTheOpeningAnchor();
    rejectedDeliveryKeepsThePickerAndPasteAtomic();
    std::cout << "gui-path-picker-session: passed\n";
  } catch (const std::exception &error) {
    std::cerr << "gui-path-picker-session: " << error.what() << '\n';

    return 1;
  }
}
