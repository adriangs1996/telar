#include "client_peer.hpp"
#include "config/control_reader.hpp"
#include "runtime/workspace_service.hpp"
#include <string>

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
  std::puts("Native control configuration and multi-client desktop tests passed");
}
