#include "client_peer.hpp"
#include "platform/launch_program.hpp"
#include "runtime/worktree_service.hpp"

using namespace telar;
using namespace telar::runtime;

static void testProgramLabels() {
  const std::array<std::string_view, 1> direct{"/usr/bin/command"};
  const std::array<std::string_view, 3> script{"/bin/sh", "-c", "exec /bin/cat"};
  std::array<std::string_view, 6> wrapped{"/bin/zsh", "-l", "-i", "-c", "exec -- \"$0\" \"$@\"", "/bin/cat"};
  check(launchedProgram({}).empty());
  check(launchedProgram(direct) == direct.front());
  check(launchedProgram(script) == script.front());
  check(launchedProgram(wrapped) == wrapped.back());
  check(launchedProgram(std::span{wrapped}.first(5)) == wrapped.front());
  wrapped[4] = "echo \"$0\"";
  check(launchedProgram(wrapped) == wrapped.front());
  wrapped[0] = "/bin/fish";
  wrapped[4] = "exec $argv";
  check(launchedProgram(wrapped) == wrapped.back());
  wrapped[1] = "-li";
  check(launchedProgram(wrapped) == wrapped.front());
}

static void testDeferredClosure(bool worktree) {
  SystemAllocator memory;
  RuntimeModel model{memory};
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/tmp/closure-fixture.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientPeer owner{memory, model, ClientRole::interactive};
  ClientPeer observer{memory, model, ClientRole::interactive};
  constexpr TerminalSize size{80, 24, 0, 0};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  workspaces.open(owner.session(), OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/", .arguments = arguments}});
  const auto opened = owner.receive<PaneOpened>();
  auto &pane = panes.require(opened.pane_id);
  panes.attach(observer.session(), pane, size);
  constexpr std::string_view final_output = "retained final output";
  pane.terminal.feed({reinterpret_cast<const Byte *>(final_output.data()), final_output.size()});

  if (worktree) {
    workspaces.closeWorkspace(opened.location.workspace.id);
    const auto notification = observer.receive<TabClosed>();
    check(notification.request_id == 0 && notification.workspace_closed && notification.location.tab_id == opened.location.tab_id);
  } else {
    workspaces.closeTab(owner.session(), CloseTab{.request_id = 2, .location = opened.location});
    check(observer.session().workspace_resync.has_value());
  }
  const auto response = owner.receive<TabClosed>();
  check(response.workspace_closed && response.location.tab_id == opened.location.tab_id);
  check(model.workspaces.find(opened.location.workspace.id) == nullptr);
  check(model.panes.find(opened.pane_id) == &pane && pane.close_requested);
  check(!owner.session().attachments.empty() && !observer.session().attachments.empty());
  check(owner.session().workspace == opened.location.workspace.id);

  pane.output_closed = true;
  pane.exit_status = SIGKILL;
  workspaces.collectExited();
  check(model.panes.find(opened.pane_id) != nullptr);
  panes.release(owner.session(), opened.pane_id);
  panes.release(observer.session(), opened.pane_id);
  workspaces.collectExited();
  check(model.panes.find(opened.pane_id) == nullptr);
  check(!owner.session().workspace && !observer.session().workspace);
  const auto *retained = model.exited_panes.find(opened.pane_id, opened.pane_generation);
  check(retained != nullptr && retained->exit_code == 128 + SIGKILL);
  check(retained->response(ReadPane{.rows = 24}).text == final_output);
}

void testWorktreeLifecycle() {
  testProgramLabels();
  testDeferredClosure(false);
  testDeferredClosure(true);
}
