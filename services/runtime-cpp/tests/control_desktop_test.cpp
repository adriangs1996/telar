#include "client_peer.hpp"
#include "config/control_reader.hpp"
#include "runtime/workspace_service.hpp"
#include <string>
#include <chrono>
#include <poll.h>
#include <termios.h>

using namespace telar;
using namespace telar::runtime;

namespace {
std::string query(auto &terminal, std::string_view input) {
  terminal.feed({reinterpret_cast<const Byte *>(input.data()), input.size()});
  std::string output;
  while (!terminal.responses().empty()) {
    const auto response = terminal.responses();
    output.append(reinterpret_cast<const char *>(response.data()), response.size());
    terminal.consumeResponses(response.size());
  }
  return output;
}

void policyConfiguration(SystemAllocator &memory) {
  lua::Vm vm{memory};
  vm.execute("return {clipboard_read='allow', clipboard_write='deny', title_report=true, checksum_report=true, color_format='8-bit', answerback='telar'}", "control-policy");
  control::Policy policy;
  config::readControlPolicy(lua::Value{vm.state(), -1, "control_queries"}, policy);
  check(policy.clipboard_read == control::Access::allow && policy.clipboard_write == control::Access::deny);
  check(policy.title_report && policy.checksum_report && policy.color_format == control::ColorFormat::eight_bit);
  check(std::string_view{policy.answerback.data(), policy.answerback_length} == "telar");
  vm.execute("return {clipboard_read='invalid'}", "invalid-control-policy");
  bool refused = false;
  try {
    config::readControlPolicy(lua::Value{vm.state(), -1, "control_queries"}, policy);
  } catch (const lua::Error &) {
    refused = true;
  }
  check(refused);
}

void ptyReports(auto &pane, auto &panes, std::string_view expected) {
  constexpr std::string_view marker = "\x1b[0n";
  constexpr std::string_view status = "\x1b[5n";
  pane.terminal.feed({reinterpret_cast<const Byte *>(status.data()), status.size()});
  panes.flushInput(pane);
  std::string actual;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{3};
  while (!actual.ends_with(marker)) {
    check(std::chrono::steady_clock::now() < deadline);
    pollfd input{.fd = pane.process->descriptor(), .events = POLLIN, .revents = 0};
    const auto ready = ::poll(&input, 1, 10);
    if (ready < 0 && errno == EINTR) {
      continue;
    }
    check(ready >= 0);
    if (ready == 0) {
      continue;
    }

    std::array<char, 4096> bytes;
    const auto count = ::read(input.fd, bytes.data(), bytes.size());
    if (count < 0 && (errno == EINTR || errno == EAGAIN)) {
      continue;
    }
    check(count > 0);
    actual.append(bytes.data(), static_cast<std::size_t>(count));
    check(actual.size() <= bytes.size());
  }
  if (actual != std::string{expected} + std::string{marker}) {
    std::fputs("Unexpected desktop PTY bytes: ", stderr);
    for (const auto byte : actual) {
      std::fprintf(stderr, "%02x", static_cast<unsigned char>(byte));
    }
    std::fputc('\n', stderr);
  }
  check(actual == std::string{expected} + std::string{marker});
}

void paletteNotification(SystemAllocator &memory) {
  RuntimeModel model{memory};
  Kqueue poller;
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/unused/control-notifications.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientPeer client{memory, model, ClientRole::interactive};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  workspaces.open(client.session(), OpenPane{.request_id = 1, .size = {80, 24, 9, 18}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  auto &pane = panes.require(client.receive<PaneOpened>().pane_id);
  termios settings{};
  check(::tcgetattr(pane.process->descriptor(), &settings) == 0);
  ::cfmakeraw(&settings);
  check(::tcsetattr(pane.process->descriptor(), TCSANOW, &settings) == 0);
  ConfigurePaneDesktop desktop{.pane_id = pane.id, .pane_generation = pane.generation, .visible = true, .light = true};
  panes.configureDesktop(client.session(), desktop);
  query(pane.terminal, "\x1b[?2031h");
  ptyReports(pane, panes, "");

  desktop.palette = std::array<Byte, 48>{};
  (*desktop.palette)[0] = 17;
  panes.configureDesktop(client.session(), desktop);
  ptyReports(pane, panes, "\x1b[?997;2n");
  check(query(pane.terminal, "\x1b]4;0;#112233\x1b\\\x1b]10;#223344\x1b\\\x1b]21;foreground=#334455\x1b\\").empty());
  ptyReports(pane, panes, "");
  panes.remove(pane.id);
}

void notificationTransitions(SystemAllocator &memory) {
  RuntimeModel model{memory};
  Kqueue poller;
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/unused/control-notification-transitions.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientPeer first{memory, model, ClientRole::interactive};
  ClientPeer second{memory, model, ClientRole::interactive};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  workspaces.open(first.session(), OpenPane{.request_id = 1, .size = {80, 24, 9, 18}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  auto &pane = panes.require(first.receive<PaneOpened>().pane_id);
  termios settings{};
  check(::tcgetattr(pane.process->descriptor(), &settings) == 0);
  ::cfmakeraw(&settings);
  check(::tcsetattr(pane.process->descriptor(), TCSANOW, &settings) == 0);
  ConfigurePaneDesktop one{.pane_id = pane.id, .pane_generation = pane.generation, .visible = true, .light = true};
  panes.configureDesktop(first.session(), one);
  constexpr std::string_view subscriptions = "\x1b[?2031;2033;1004;2048h";
  pane.terminal.feed({reinterpret_cast<const Byte *>(subscriptions.data()), subscriptions.size()});
  ptyReports(pane, panes, "\x1b[?999;1n\x1b[O\x1b[48;24;80;432;720t");
  panes.attach(second.session(), pane, {80, 24, 9, 18});
  ptyReports(pane, panes, "");

  auto two = one;
  two.light = false;
  two.focused = true;
  panes.configureDesktop(second.session(), two);
  ptyReports(pane, panes, "\x1b[I");
  panes.resize(second.session(), PaneResize{.pane_id = pane.id, .size = {100, 30, 8, 16}});
  ptyReports(pane, panes, "");
  panes.resize(first.session(), PaneResize{.pane_id = pane.id, .size = {100, 30, 8, 16}});
  ptyReports(pane, panes, "\x1b[48;30;100;480;800t");

  one.visible = false;
  panes.configureDesktop(first.session(), one);
  ptyReports(pane, panes, "\x1b[?997;1n");
  one.visible = true;
  panes.configureDesktop(first.session(), one);
  ptyReports(pane, panes, "\x1b[?997;2n");
  two.visible = false;
  panes.configureDesktop(second.session(), two);
  ptyReports(pane, panes, "\x1b[O");
  two.visible = true;
  panes.configureDesktop(second.session(), two);
  ptyReports(pane, panes, "\x1b[I");
  panes.detach(first.session(), pane.id);
  ptyReports(pane, panes, "\x1b[?997;1n");
  panes.resize(second.session(), PaneResize{.pane_id = pane.id, .size = {100, 40, 8, 16}});
  ptyReports(pane, panes, "\x1b[48;40;100;640;800t");

  second.session().connection.closing = true;
  panes.detachAll(second.session());
  ptyReports(pane, panes, "\x1b[?997;1n\x1b[?999;2n\x1b[O");
  check(query(pane.terminal, "\x1b[18t") == "\x1b[8;40;100t");
  ClientPeer reconnected{memory, model, ClientRole::interactive};
  panes.attach(reconnected.session(), pane, {120, 50, 8, 16});
  ptyReports(pane, panes, "\x1b[?997;1n\x1b[48;50;120;800;960t");
  auto three = two;
  three.focused = false;
  panes.configureDesktop(reconnected.session(), three);
  ptyReports(pane, panes, "\x1b[?997;1n\x1b[?999;1n");

  check(query(pane.terminal, "\x1b[?2031;2033;1004;2048l").empty());
  three.visible = false;
  panes.configureDesktop(reconnected.session(), three);
  panes.resize(reconnected.session(), PaneResize{.pane_id = pane.id, .size = {120, 60, 8, 16}});
  ptyReports(pane, panes, "");
  check(query(pane.terminal, "\x1b[?2031h").empty());
  ConfigureTerminalColors colors{.foreground = std::array<Byte, 3>{22, 33, 44}};
  panes.configureColors(reconnected.session(), colors);
  ptyReports(pane, panes, "\x1b[?997;1n");
  panes.configureColors(reconnected.session(), colors);
  ptyReports(pane, panes, "");
  panes.remove(pane.id);
}

void multipleClients(SystemAllocator &memory) {
  RuntimeModel model{memory};
  Kqueue poller;
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/unused/control-desktop.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientPeer first{memory, model, ClientRole::interactive};
  ClientPeer second{memory, model, ClientRole::interactive};
  ClientPeer outsider{memory, model, ClientRole::interactive};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  const Launch launch{.cwd = "/tmp", .arguments = arguments};
  workspaces.open(first.session(), OpenPane{.request_id = 1, .size = {80, 24, 9, 18}, .launch = launch});
  const auto opened = first.receive<PaneOpened>();
  auto &pane = panes.require(opened.pane_id);
  panes.attach(second.session(), pane, {80, 24, 9, 18});
  auto *workspace = model.workspaces.find(pane.location.workspace.id);
  check(workspace != nullptr);
  workspace->geometry_client = second.session().id;

  check(query(pane.terminal, "\x1b[?998n") == "\x1b[?999;2n");
  ConfigurePaneDesktop one{.pane_id = pane.id,
                           .pane_generation = pane.generation,
                           .visible = true,
                           .focused = false,
                           .light = true,
                           .foreground = std::array<Byte, 3>{0, 0, 0},
                           .background = std::array<Byte, 3>{255, 255, 255},
                           .cursor = std::array<Byte, 3>{1, 2, 3}};
  std::array<Byte, 256> encoded;
  std::array<Byte, 512> arena;
  DecodeStorage storage{arena};
  const auto decoded = Codec::decode<ConfigurePaneDesktop>(Codec::encode(one, encoded), storage);
  check(decoded == one);
  panes.configureDesktop(first.session(), decoded);
  auto two = one;
  two.light = false;
  two.focused = true;
  two.cursor = std::array<Byte, 3>{4, 5, 6};
  panes.configureDesktop(second.session(), two);
  check(query(pane.terminal, "\x1b[?996n\x1b[?998n\x1b]12;?\x1b\\") == "\x1b[?997;2n\x1b[?999;1n\x1b]12;rgb:0101/0202/0303\x1b\\");

  bool stale = false;
  auto old = one;
  ++old.pane_generation;
  try {
    panes.configureDesktop(first.session(), old);
  } catch (const RequestError &) {
    stale = true;
  }
  check(stale);
  bool unattached = false;
  try {
    panes.configureDesktop(outsider.session(), one);
  } catch (const RequestError &) {
    unattached = true;
  }
  check(unattached);

  panes.release(first.session(), pane.id);
  check(query(pane.terminal, "\x1b[?996n\x1b[?998n\x1b]12;?\x1b\\") == "\x1b[?997;1n\x1b[?999;1n\x1b]12;rgb:0404/0505/0606\x1b\\");
  second.session().connection.closing = true;
  panes.detachAll(second.session());
  check(query(pane.terminal, "\x1b[?996n\x1b[?998n") == "\x1b[?997;1n\x1b[?999;2n");
  panes.remove(pane.id);
}
}

int main() {
  SystemAllocator memory;
  policyConfiguration(memory);
  multipleClients(memory);
  paletteNotification(memory);
  notificationTransitions(memory);
  std::puts("Native control configuration and multi-client desktop tests passed");
}
