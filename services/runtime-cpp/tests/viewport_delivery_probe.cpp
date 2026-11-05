#include "tests/client_peer.hpp"
#include "runtime/delivery/attachment_delivery.hpp"
#include "runtime/workspace_service.hpp"
#include "terminal/screen.hpp"
#include "../../gui-cpp/terminal/screen.hpp"
#include <cstdio>
#include <string>
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>

using namespace telar;
using namespace telar::runtime;

template <typename Sync>
void requestViewport(Sync &sync) {
  if constexpr (requires { sync.requestViewport(); }) {
    sync.requestViewport();
  } else {
    sync.requestSnapshot();
  }
}

int main() {
  SystemAllocator memory;
  RuntimeModel model{memory};
  NativeEventLoop<SystemAllocator> poller{memory};
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/unused/viewport-delta.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientPeer first{memory, model, ClientRole::interactive};
  ClientPeer second{memory, model, ClientRole::interactive};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  const Launch launch{.cwd = "/tmp", .arguments = arguments};
  workspaces.open(first.session(), OpenPane{.request_id = 1, .size = {82, 21, 0, 0}, .launch = launch});
  const auto opened = first.receive<PaneOpened>();
  auto &pane = panes.require(opened.pane_id);
  panes.attach(second.session(), pane, {82, 21, 0, 0});
  std::string corpus;
  for (unsigned row = 0; row < 200; ++row) {
    corpus += std::to_string(row) + " \x1b[32mviewport\x1b[0m \x1b]8;;https://example.test/" + std::to_string(row) + "\x1b\\link\x1b]8;;\x1b\\\r\n";
  }
  pane.terminal.feed(byteView(corpus));
  std::array<telar::gui::Screen<SystemAllocator>, 2> screens{telar::gui::Screen<SystemAllocator>{memory}, telar::gui::Screen<SystemAllocator>{memory}};
  auto now = std::chrono::steady_clock::now();
  std::uint64_t frames = 0;
  std::uint64_t snapshots = 0;
  const auto select = [&](ClientPeer &peer, std::uint32_t offset) {
    auto &attachment = *peer.session().attachment(pane.id);
    attachment.viewport = offset;
    requestViewport(attachment.frames);
    screens[&peer == &first ? 0 : 1].setViewport(offset);
  };
  const auto deliver = [&](ClientPeer &peer, bool acknowledge, bool snapshot) {
    auto timeout = std::chrono::nanoseconds::max();
    AttachmentDelivery delivery{model, peer.session()};
    check(delivery.prepare(DeliveryLane::cells, now, timeout));
    const auto frame = peer.receive<PaneFrame>();
    auto &screen = screens[&peer == &first ? 0 : 1];
    check(screen.apply(frame) == telar::gui::FrameApplication::applied);
    check(screen.scroll().offset == pane.terminal.screen.scroll.offset);
    check(screen.cells().size() == pane.terminal.screen.cells.size());
    for (std::size_t index = 0; index < screen.cells().size(); ++index) {
      const auto &actual = screen.cells()[index];
      const auto &expected = pane.terminal.screen.cells[index];
      check(actual.length == expected.length && actual.width == expected.width && actual.style == expected.style);
      check(std::equal(actual.text.begin(), actual.text.begin() + actual.length, expected.text.begin()));
    }
    if (snapshot) {
      check(frame.base_frame_id == 0);
    }
    snapshots += frame.base_frame_id == 0;
    ++frames;
    if (acknowledge) {
      check(peer.session().attachment(pane.id)->frames.acknowledge(frame.frame_id));
    }
    return frame.frame_id;
  };
  select(first, 100);
  deliver(first, true, true);
  select(second, 30);
  deliver(second, true, true);
  for (unsigned step = 0; step < 30; ++step) {
    select(first, 100 - step);
    deliver(first, true, false);
    select(second, 30 + step);
    deliver(second, true, false);
    now += std::chrono::seconds{1};
  }
  select(first, 65);
  const auto pending = deliver(first, false, false);
  select(first, 62);
  select(first, 59);
  pane.terminal.feed(byteView("new output during outstanding viewport\r\n"));
  auto timeout = std::chrono::nanoseconds::max();
  AttachmentDelivery blocked{model, first.session()};
  check(!blocked.prepare(DeliveryLane::cells, now, timeout));
  select(second, 9);
  deliver(second, true, false);
  auto &sync = first.session().attachment(pane.id)->frames;
  check(!sync.acknowledge(pending + 1));
  check(sync.acknowledge(pending));
  deliver(first, true, false);
  select(first, 56);
  const auto recovery = deliver(first, false, false);
  sync.requestSnapshot();
  check(sync.acknowledge(recovery));
  deliver(first, true, true);
  first.session().frame_interval = std::chrono::seconds{1};
  pane.terminal.feed(byteView("another line\r\n"));
  now += std::chrono::seconds{1};
  deliver(first, true, false);
  select(first, 53);
  deliver(first, true, false);
  select(first, UINT32_MAX);
  deliver(first, true, false);
  select(second, 0);
  deliver(second, true, false);
  panes.detachAll(first.session());
  panes.detachAll(second.session());
  panes.remove(pane.id);
  std::printf("frames=%llu snapshots=%llu\n", static_cast<unsigned long long>(frames), static_cast<unsigned long long>(snapshots));
}
