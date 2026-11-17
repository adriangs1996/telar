#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/allocator.hpp"
#include "telar_wire/protocol/pane_io.hpp"
#include "telar_wire/protocol/runtime.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <array>
#include <cstddef>
#include <cstring>
#include <limits>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>

import telar.testing;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.wire.editor;
import telar.wire.runtime;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::application::tests::session_fixture;

  class PathTransport : public Transport {
  public:
    void send(std::span<const Byte> message) override {
      const auto tag = static_cast<ClientTag>(message.front());
      if (tag == MessageSchema<FindPaths>::tag && reject_paths) {
        throw std::length_error{"Path queue is full"};
      }

      if (tag == MessageSchema<PaneInput>::tag && reject_paste) {
        throw std::length_error{"Input queue is full"};
      }

      Transport::send(message);
    }

    bool reject_paths = false;
    bool reject_paste = false;
  };

  template <typename Client>
  void publishPaths(Client& client, const PathTransport& transport, std::string_view path, PathKind kind = PathKind::file) {
    const auto request = transport.last<FindPaths>();
    const std::array matches{PathMatch{.path = path, .kind = kind}};

    check(deliver(client, PathResults{.request_id = request.request_id, .root = request.root, .complete = true, .matches = matches}) == application::Change::paths, "the current wire page must update the picker");
  }

  void searchesUseTheRuntimeAndRetainOnlyCurrentResults() {
    SystemAllocator memory;
    PathTransport transport;
    TestSession client{memory, transport};

    check(!application::paths::open(client), "a disconnected client must not open the path picker");
    openFirstPane(client, transport);
    check(!application::paths::open(client), "a pane without a known directory must not search the client filesystem");
    deliver(client, PaneCwd{.pane_id = 1, .cwd = "/work"});
    check(application::paths::open(client), "an attached pane with a known directory must open the picker");
    const auto initial = transport.last<FindPaths>();

    check(initial.root == "/work" && initial.query.empty() && initial.refresh && initial.limit == application::paths::PathPickerLimits::results && initial.kind == PathKindFilter::any, "opening must ask the runtime for its first ranked page and refresh its index");
    const std::string prefix(application::paths::PathPickerLimits::query_bytes - 1, 'a');

    check(application::paths::search(client, prefix + "🧵"), "a long query must remain admissible");
    const auto query = transport.last<FindPaths>();

    check(query.query == prefix && !query.refresh, "wire queries must stop before an incomplete UTF-8 scalar without rebuilding the index");
    const std::array stale{PathMatch{.path = "stale"}};

    check(deliver(client, PathResults{.request_id = initial.request_id, .root = "/work", .complete = true, .matches = stale}) == application::Change::none, "a superseded wire response must leave the current page untouched");
    check(deliver(client, RequestFailed{.request_id = initial.request_id, .code = FailureCode::invalid_request, .message = "obsolete"}) == application::Change::none && client.error().empty(), "a tracked obsolete failure must not produce a notification or repaint");
    publishPaths(client, transport, "src/main.cpp");
    check(application::paths::page(client).path(application::paths::page(client).matches().front()) == "src/main.cpp", "retained paths must survive destruction of the decoder buffer");
    application::paths::close(client);
    check(!application::paths::search(client, "closed"), "closing must stop further requests");
  }

  void directoryNavigationKeepsTheOpeningAnchor() {
    SystemAllocator memory;
    PathTransport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    deliver(client, PaneCwd{.pane_id = 1, .cwd = "/work"});
    check(application::paths::open(client), "the directory fixture must open");
    publishPaths(client, transport, "sub/", PathKind::directory);
    check(application::paths::descend(client, 0), "Tab must browse the selected directory");
    auto request = transport.last<FindPaths>();

    check(request.root == "/work/sub" && request.query.empty() && request.refresh && application::paths::page(client).anchor() == "/work", "descending must reset the query while retaining the opening directory");
    publishPaths(client, transport, "a b'c.txt");
    const auto first_input = transport.sent.size();

    check(application::paths::insert(client, 0, false), "a ready selected file must be insertable");
    check(transport.inputSince(first_input) == "'sub/a b'\\''c.txt'" && transport.count(ClientTag::pane_input) == 1, "insertion must deliver one quoted relative word without executing it");
    check(application::paths::page(client).phase() == application::paths::PathPickerPhase::idle, "successful insertion must close the picker");
    check(application::paths::open(client) && application::paths::ascend(client), "Shift+Tab must browse the current root's parent");
    request = transport.last<FindPaths>();
    check(request.root == "/" && request.refresh && !application::paths::ascend(client), "parent navigation must stop at the filesystem root");
    publishPaths(client, transport, "tmp/file");
    const auto absolute_input = transport.sent.size();

    check(application::paths::insert(client, 0, true) && transport.inputSince(absolute_input) == "/tmp/file", "alternate insertion must preserve the absolute path outside the opening directory");
  }

  template <typename Client>
  void enableBracketedPaste(Client& client) {
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
    BudgetAllocator budget{system, std::numeric_limits<std::size_t>::max()};
    telar::MemoryAdapter adapter{budget};
    telar::Memory& memory = adapter;
    PathTransport transport;

    {
      TestSession client{memory, transport};

      openFirstPane(client, transport);
      deliver(client, PaneCwd{.pane_id = 1, .cwd = "/work"});
      transport.reject_paths = true;
      check(application::paths::open(client) && application::paths::page(client).error() == "Path request queue is full; retry", "queue pressure must leave the picker open with its local error");
      check(application::paths::page(client).pendingRequest() == 0 && transport.count(ClientTag::find_paths) == 0, "rejected search delivery must not acquire a pending correlation");
      transport.reject_paths = false;
      check(application::paths::search(client, {}), "retrying an unsent search must remain possible");
      enableBracketedPaste(client);
      publishPaths(client, transport, "-a b");
      transport.reject_paste = true;
      check(!application::paths::insert(client, 0, false) && application::paths::page(client).error() == "Input is busy; retry", "rejected paste must retain the selected page for a retry");
      check(transport.count(ClientTag::pane_input) == 0 && application::paths::page(client).matches().size() == 1, "a rejected bracketed paste must not leave a partial opening marker in the queue");
      transport.reject_paste = false;
      const auto first_input = transport.sent.size();

      check(application::paths::insert(client, 0, false), "a retry after queue pressure must succeed");
      check(transport.inputSince(first_input) == "\x1b[200~./'-a b'\x1b[201~" && transport.count(ClientTag::pane_input) == 1, "one admitted frame must contain the entire bracketed paste and no Enter");
      check(application::paths::open(client), "a second request must reopen the picker");
      client.disconnected();
      check(application::paths::page(client).phase() == application::paths::PathPickerPhase::idle && !application::paths::search(client, {}), "disconnecting must retire disposable picker state");
    }

    check(budget.liveBytes() == 0, "path searches must release every injected session allocation");
  }

  const telar::testing::Case case_searches_use_the_runtime_and_retain_only_current_results{"path_picker_session.searches_use_the_runtime_and_retain_only_current_results", searchesUseTheRuntimeAndRetainOnlyCurrentResults};
  const telar::testing::Case case_directory_navigation_keeps_the_opening_anchor{"path_picker_session.directory_navigation_keeps_the_opening_anchor", directoryNavigationKeepsTheOpeningAnchor};
  const telar::testing::Case case_rejected_delivery_keeps_the_picker_and_paste_atomic{"path_picker_session.rejected_delivery_keeps_the_picker_and_paste_atomic", rejectedDeliveryKeepsThePickerAndPasteAtomic};

}
