#include "terminal/terminal.hpp"
#include "runtime/clipboard_service.hpp"
#include "runtime/workspace_service.hpp"
#include "client_peer.hpp"
#include "ui/workbench/clipboard_task.hpp"
#include <cstdio>

using namespace telar;
using namespace telar::runtime;
using namespace workbench;

namespace {
std::span<const Byte> bytes(std::string_view text) {
  return {reinterpret_cast<const Byte *>(text.data()), text.size()};
}

std::string drain(auto &terminal) {
  std::string result;
  while (!terminal.responses().empty()) {
    const auto pending = terminal.responses();
    result.append(reinterpret_cast<const char *>(pending.data()), pending.size());
    terminal.consumeResponses(pending.size());
  }
  return result;
}

struct MemoryClipboard {
  unsigned inspections = 0;
  unsigned reads = 0;
  unsigned writes = 0;
  bool primary_supported = false;
  std::vector<ClipboardContent> contents{{"text/plain", {'h', 'e', 'l', 'l', 'o'}}, {"text/html", {'<', 'b', '>', 'x', '<', '/', 'b', '>'}}};

  bool supports(bool primary) {
    ++inspections;
    return !primary || primary_supported;
  }

  ClipboardResult read(const OwnedClipboardTask &task) {
    ++reads;
    ClipboardResult result{.status = ClipboardDesktopStatus::success};
    if (task.listing) {
      for (const auto &content : contents) {
        result.available.push_back(content.mime);
      }
    }
    for (const auto &mime : task.mimes) {
      for (const auto &content : contents) {
        if (mime == content.mime) {
          result.contents.push_back(content);
          break;
        }
      }
    }
    return result;
  }

  ClipboardResult write(const OwnedClipboardTask &task) {
    ++writes;
    contents = task.contents;
    return {.status = ClipboardDesktopStatus::success};
  }
};

void complete(auto &terminal, const OwnedClipboardTask &task, ClipboardConsent consent, MemoryClipboard &provider) {
  auto &clipboard = terminal.clipboardControl();
  check(clipboard.complete({1, 13}, CompleteClipboardDesktop{
      .ticket = task.ticket,
      .status = consent == ClipboardConsent::deny ? ClipboardDesktopStatus::denied : ClipboardDesktopStatus::success,
      .remember = task.rememberable && consent == ClipboardConsent::session,
      .prepared = true,
  }));
  if (consent == ClipboardConsent::deny) {
    terminal.resumeControl();
    return;
  }
  check(clipboard.execution().has_value());
  clipboard.committed();
  const auto result = executeClipboard(task, consent, provider);
  std::array<ClipboardRepresentation, 4> contents;
  std::array<std::string_view, 16> available;
  for (std::size_t index = 0; index < result.contents.size(); ++index) {
    contents[index] = {result.contents[index].mime, result.contents[index].data};
  }
  for (std::size_t index = 0; index < result.available.size(); ++index) {
    available[index] = result.available[index];
  }
  check(terminal.clipboardControl().complete({1, 13}, CompleteClipboardDesktop{
      .ticket = task.ticket,
      .status = result.status,
      .remember = result.status == ClipboardDesktopStatus::success && task.rememberable && consent == ClipboardConsent::session,
      .contents = std::span{contents}.first(result.contents.size()),
      .available = std::span{available}.first(result.available.size()),
  }));
  terminal.resumeControl();
}

OwnedClipboardTask take(auto &terminal) {
  auto &clipboard = terminal.clipboardControl();
  const auto request = clipboard.request(7, 11);
  check(request.has_value());
  std::vector<Byte> wire(Codec::encodedSize(*request));
  std::array<Byte, 32 * 1024> arena;
  DecodeStorage storage{arena};
  OwnedClipboardTask task{Codec::decode<ClipboardDesktopRequest>(Codec::encode(*request, wire), storage)};
  std::fill(wire.begin(), wire.end(), 0xff);
  std::fill(arena.begin(), arena.end(), 0xff);
  clipboard.announced();
  return task;
}

void protocolAndPermissions(auto &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  auto &clipboard = terminal.clipboardControl();
  MemoryClipboard provider;
  constexpr std::string_view request = "\x1b]5522;type=read:id=req:name=QXBw:pw=cHc=;dGV4dC9wbGFpbiB0ZXh0L2h0bWwgLg==\a";
  terminal.feed(bytes(request));
  check(drain(terminal) == "\x1b]5522;type=read:status=EPERM:id=req\a");
  check(provider.inspections == 0 && !clipboard.route());
  const std::array<control::ClipboardRoute, 1> routes{{{1, 13}}};
  clipboard.routes(routes, routes[0]);
  terminal.feed(bytes(request));
  auto task = take(terminal);
  check(task.prompt && task.rememberable && task.name == "App" && task.mimes.size() == 2 && task.listing);
  auto stale = task.ticket;
  ++stale.nonce;
  check(!clipboard.complete(routes[0], CompleteClipboardDesktop{.ticket = stale}));
  check(!clipboard.complete({2, 13}, CompleteClipboardDesktop{.ticket = task.ticket}));
  complete(terminal, task, ClipboardConsent::deny, provider);
  check(provider.inspections == 0 && provider.reads == 0);
  check(drain(terminal) == "\x1b]5522;type=read:status=EPERM:id=req\a");

  terminal.feed(bytes(request));
  task = take(terminal);
  complete(terminal, task, ClipboardConsent::session, provider);
  check(provider.reads == 1);
  check(drain(terminal) == "\x1b]5522;type=read:status=OK:id=req\a"
                          "\x1b]5522;type=read:status=DATA:id=req:mime=Lg==;dGV4dC9wbGFpbiB0ZXh0L2h0bWwK\a"
                          "\x1b]5522;type=read:status=DATA:id=req:mime=dGV4dC9wbGFpbg==;aGVsbG8=\a"
                          "\x1b]5522;type=read:status=DATA:id=req:mime=dGV4dC9odG1s;PGI+eDwvYj4=\a"
                          "\x1b]5522;type=read:status=DONE:id=req\a");
  terminal.feed(bytes(request));
  task = take(terminal);
  check(!task.prompt);
  complete(terminal, task, ClipboardConsent::once, provider);
  drain(terminal);

  terminal.feed(bytes("\x1b]5522;type=write:id=write:name=QXBw:pw=cHc=\x1b\\"
                      "\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aG\x1b\\"
                      "\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;VsbG8=\x1b\\"
                      "\x1b]5522;type=wdata:id=other\x1b\\"));
  terminal.controlPolicy().clipboard_write = control::Access::ask;
  task = take(terminal);
  // Write policy was allow at commit; a read grant still does not authorize
  // a subsequent write committed under ask.
  check(task.write && task.contents.size() == 1 && task.contents[0].data == provider.contents[0].data);
  complete(terminal, task, ClipboardConsent::once, provider);
  check(provider.writes == 1);
  check(drain(terminal) == "\x1b]5522;type=write:status=DONE:id=write\x1b\\");
  terminal.feed(bytes("\x1b]5522;type=write:id=again:name=QXBw:pw=cHc=\x1b\\\x1b]5522;type=wdata\x1b\\"));
  task = take(terminal);
  check(task.prompt && task.contents.empty());
  complete(terminal, task, ClipboardConsent::once, provider);
  check(provider.writes == 2 && provider.contents.empty());
  drain(terminal);

  terminal.controlPolicy().clipboard_write = control::Access::deny;
  terminal.feed(bytes("\x1b]5522;type=write:id=denied\a"));
  check(drain(terminal) == "\x1b]5522;type=write:status=EPERM:id=denied\a");
  terminal.feed(bytes("\x1b]52;c;?\a"));
  task = take(terminal);
  check(task.prompt && !task.rememberable);
  complete(terminal, task, ClipboardConsent::deny, provider);
  check(drain(terminal) == "\x1b]52;c;\x1b\\");
  terminal.controlPolicy().clipboard_read = control::Access::allow;
  provider.contents = {{"text/plain", {'h', 'e', 'l', 'l', 'o'}}};
  terminal.feed(bytes("\x1b]52;c;?\a"));
  task = take(terminal);
  check(!task.prompt);
  complete(terminal, task, ClipboardConsent::once, provider);
  check(drain(terminal) == "\x1b]52;c;aGVsbG8=\x1b\\");
  check(terminal.effects.clipboard_revision == 0);
}

void lifetimeAndPressure(auto &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  auto &clipboard = terminal.clipboardControl();
  const std::array<control::ClipboardRoute, 1> routes{{{1, 13}}};
  clipboard.routes(routes, routes[0]);
  constexpr std::string_view request = "\x1b]5522;type=read:id=x;dGV4dC9wbGFpbg==\x1b\\";
  terminal.feed(bytes(request));
  auto task = take(terminal);
  clipboard.routes({}, {});
  terminal.resumeControl();
  check(drain(terminal) == "\x1b]5522;type=read:status=EPERM:id=x\x1b\\");
  check(!clipboard.complete(routes[0], CompleteClipboardDesktop{.ticket = task.ticket}));
  check(clipboard.cancellation()->ticket == task.ticket);
  clipboard.cancelled();
  clipboard.routes(routes, routes[0]);
  terminal.feed(bytes(request));
  task = take(terminal);
  clipboard.expire(control::Clipboard<SystemAllocator>::Clock::now() + std::chrono::seconds{31});
  terminal.resumeControl();
  check(drain(terminal) == "\x1b]5522;type=read:status=EPERM:id=x\x1b\\");

  check(clipboard.cancellation()->ticket == task.ticket);
  clipboard.cancelled();
  terminal.feed(bytes(request));
  task = take(terminal);
  std::string burst;
  std::string expected;
  for (unsigned index = 0; index < 65; ++index) {
    burst.append("\x1b[5n");
    expected.append("\x1b[0n");
  }
  terminal.feed(bytes(burst));
  MemoryClipboard provider;
  complete(terminal, task, ClipboardConsent::once, provider);
  expected.append("\x1b]5522;type=read:status=OK:id=x\x1b\\"
                  "\x1b]5522;type=read:status=DATA:id=x:mime=dGV4dC9wbGFpbg==;aGVsbG8=\x1b\\"
                  "\x1b]5522;type=read:status=DONE:id=x\x1b\\");
  check(drain(terminal) == expected);
  check(!terminal.hasPendingControl() && provider.reads == 1);
}

void traditionalEncoding(auto &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  auto &clipboard = terminal.clipboardControl();
  const std::array<control::ClipboardRoute, 1> routes{{{1, 13}}};
  clipboard.routes(routes, routes[0]);
  MemoryClipboard provider;
  for (const auto encoded : {"YQ==", "YQ", "YR==", "YR", "YWI=", "YWI", "YWJ=", "YWJ"}) {
    terminal.feed(bytes(std::string{"\x1b]52;c;"} + encoded + "\a"));
    const auto task = take(terminal);
    check(task.write && task.contents.size() == 1);
    const std::string expected = std::string_view{encoded}.starts_with("YQ") || std::string_view{encoded}.starts_with("YR") ? "a" : "ab";
    check(std::string_view{reinterpret_cast<const char *>(task.contents[0].data.data()), task.contents[0].data.size()} == expected);
    complete(terminal, task, ClipboardConsent::once, provider);
    check(drain(terminal).empty());
  }
  for (const auto encoded : {"YQ=", "Y===", "YQ===", "YQ==YQ==", "Y Q==", "!!", "A", "AB=C"}) {
    terminal.feed(bytes(std::string{"\x1b]52;c;"} + encoded + "\a"));
    check(!clipboard.request(7, 11));
    check(drain(terminal).empty());
  }

  for (const auto selection : {'c', 'p', 's', 'x'}) {
    const auto sequence = std::string{"\x1b]52;"} + selection + ";?\a";
    terminal.feed(bytes(sequence));
    const auto task = take(terminal);
    check(!task.primary && task.prompt);
    const auto inspections = provider.inspections;
    complete(terminal, task, ClipboardConsent::deny, provider);
    const auto response_kind = selection == 'x' ? 'c' : selection;
    check(drain(terminal) == std::string{"\x1b]52;"} + response_kind + ";\x1b\\");
    check(provider.inspections == inspections);
  }
  terminal.feed(bytes("\x1b]52;c;?\a"));
  const auto task = take(terminal);
  clipboard.routes({}, {});
  terminal.resumeControl();
  check(drain(terminal).empty());
  check(!clipboard.complete(routes[0], CompleteClipboardDesktop{.ticket = task.ticket, .status = ClipboardDesktopStatus::denied, .prepared = true}));
}

struct FailingAllocator {
  SystemAllocator system;
  bool fail = false;
  bool fail_small = false;

  void *allocate(std::size_t size, std::size_t alignment) noexcept {
    return fail || (fail_small && size < 128) ? nullptr : system.allocate(size, alignment);
  }

  void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    system.deallocate(pointer, size, alignment);
  }
};

void encodingFailure(bool retained_paste, bool owner_failure = false) {
  FailingAllocator upstream;
  BudgetAllocator memory{upstream, 64 * 1024 * 1024};
  {
    Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
    auto &clipboard = terminal.clipboardControl();
    const std::array<control::ClipboardRoute, 1> routes{{{1, 13}}};
    clipboard.routes(routes, routes[0]);
    terminal.feed(bytes("\x1b]5522;type=read:id=failure;dGV4dC9wbGFpbg==\x1b\\"));
    auto task = take(terminal);
    if (retained_paste) {
      std::string burst;
      for (unsigned index = 0; index < 64; ++index) {
        burst.append("\x1b[5n");
      }
      terminal.feed(bytes(burst));
      const std::string mime(256, 'a');
      const std::array<std::string_view, 16> available{mime, mime, mime, mime, mime, mime, mime, mime, mime, mime, mime, mime, mime, mime, mime, mime};
      check(clipboard.paste(routes[0], false, available));
      terminal.resumeControl();
    }
    MemoryClipboard provider;
    provider.contents = {{"text/plain", std::vector<Byte>(4096, 'x')}};
    upstream.fail = !owner_failure;
    upstream.fail_small = owner_failure;
    complete(terminal, task, ClipboardConsent::once, provider);
    const auto result = drain(terminal);
    check(result.ends_with("\x1b]5522;type=read:status=EIO:id=failure\x1b\\"));
    check(result.find("status=OK:id=failure") == std::string::npos);
    check(!clipboard.route() && !terminal.hasPendingControl());
    upstream.fail = false;
    upstream.fail_small = false;
  }
  check(memory.liveBytes() == 0);
}

void resetBeforeConsent(auto &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  auto &clipboard = terminal.clipboardControl();
  const std::array<control::ClipboardRoute, 1> routes{{{1, 13}}};
  clipboard.routes(routes, routes[0]);
  terminal.controlPolicy().clipboard_write = control::Access::ask;
  terminal.feed(bytes("\x1b]5522;type=write:id=reset\x1b\\\x1b]5522;type=wdata\x1b\\"));
  const auto task = take(terminal);
  terminal.feed(bytes("\x1b" "c"));
  check(clipboard.cancellation()->ticket == task.ticket);
  check(!clipboard.complete(routes[0], CompleteClipboardDesktop{.ticket = task.ticket, .status = ClipboardDesktopStatus::success, .prepared = true}));
  check(!clipboard.execution());
  check(drain(terminal) == "\x1b]5522;type=write:status=EPERM:id=reset\x1b\\");
}

void asynchronousOrder(auto &memory) {
  auto responses = std::make_shared<PtyResponseQueue>();
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, responses};
  terminal.feed(bytes("\x1b[?1004h"));
  drain(terminal);
  auto filler = std::make_shared<std::vector<Byte>>(1024 * 1024, 'x');
  check(responses->tryPushOwned(*filler, filler));
  auto &clipboard = terminal.clipboardControl();
  const std::array<control::ClipboardRoute, 1> routes{{{1, 13}}};
  clipboard.routes(routes, routes[0]);
  terminal.feed(bytes("\x1b]5522;type=read:id=order;dGV4dC9wbGFpbg==\x1b\\"));
  const auto task = take(terminal);
  MemoryClipboard provider;
  provider.contents = {{"text/plain", std::vector<Byte>(1024 * 1024, 'a')}};
  complete(terminal, task, ClipboardConsent::once, provider);
  check(clipboard.hasReply());
  terminal.configureClientFacts({.focused = true});
  check(responses->snapshot().messages == 1);
  terminal.consumeResponses(filler->size());
  const auto result = drain(terminal);
  check(result.starts_with("\x1b]5522;type=read:status=OK:id=order\x1b\\"));
  check(result.ends_with("\x1b]5522;type=read:status=DONE:id=order\x1b\\\x1b[I"));
}

void actualRouting(SystemAllocator &memory) {
  RuntimeModel model{memory};
  Kqueue poller;
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/unused/clipboard.sock"}};
  WorkspaceService workspaces{memory, model, panes};
  ClientPeer first{memory, model, ClientRole::interactive};
  ClientPeer second{memory, model, ClientRole::interactive};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  workspaces.open(first.session(), OpenPane{.request_id = 1, .size = {80, 24, 9, 18}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  const auto opened = first.receive<PaneOpened>();
  auto &pane = panes.require(opened.pane_id);
  panes.attach(second.session(), pane, {80, 24, 9, 18});
  ConfigurePaneDesktop desktop{.pane_id = pane.id, .pane_generation = pane.generation, .visible = true, .clipboard = true};
  panes.configureDesktop(first.session(), desktop);
  desktop.focused = true;
  panes.configureDesktop(second.session(), desktop);
  pane.terminal.feed(bytes("\x1b]5522;type=read:id=route;dGV4dC9wbGFpbg==\x1b\\"));
  ClipboardService service{model};
  service.advance(pane, std::chrono::steady_clock::now());
  const auto request = second.receive<ClipboardDesktopRequest>();
  OwnedClipboardTask task{request};
  check(task.ticket.pane_id == pane.id && task.ticket.client_generation == second.session().generation);
  CompleteClipboardDesktop completion{.ticket = task.ticket, .status = ClipboardDesktopStatus::denied, .prepared = true};
  check(service.complete(first.session(), completion) == nullptr);
  ++completion.ticket.pane_generation;
  check(service.complete(second.session(), completion) == nullptr);
  --completion.ticket.pane_generation;
  check(service.complete(second.session(), completion) == &pane);
  check(drain(pane.terminal) == "\x1b]5522;type=read:status=EPERM:id=route\x1b\\");
  check(service.complete(second.session(), completion) == nullptr);
  panes.remove(pane.id);
}

void deferredAllocationFailure() {
  FailingAllocator upstream;
  BudgetAllocator memory{upstream, 64 * 1024 * 1024};
  {
    RuntimeModel model{memory};
    Kqueue poller;
    PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/unused/control-failure.sock"}};
    const std::array<std::string_view, 1> arguments{"/bin/cat"};
    const Launch launch{.cwd = "/tmp", .arguments = arguments};
    const TabLocation location{.workspace = {.id = 7}, .tab_id = 1};
    auto &failed = panes.launch(launch, location, {80, 24, 9, 18});
    auto &healthy = panes.launch(launch, location, {80, 24, 9, 18});
    const auto failed_id = failed.id;
    const auto healthy_id = healthy.id;
    std::string input;
    for (unsigned index = 0; index < 65; ++index) {
      input.append("\x1b[5n");
    }
    input.append("\x1bP+q");
    input.append(4096, 'A');
    input.append("\x1b\\");
    failed.terminal.feed(bytes(input));
    check(failed.terminal.hasPendingControl());
    upstream.fail = true;
    panes.flushInput(failed);
    check(failed.output_closed && failed.close_requested);
    check(!failed.terminal.hasPendingControl() && failed.pty_responses->empty());
    upstream.fail = false;
    healthy.terminal.feed(bytes("\x1b[5n"));
    check(drain(healthy.terminal) == "\x1b[0n");
    check(!healthy.output_closed);
    panes.remove(failed_id);
    panes.remove(healthy_id);
  }
  check(memory.liveBytes() == 0);
}
}

int main() {
  SystemAllocator system;
  {
    BudgetAllocator memory{system, 64 * 1024 * 1024};
    protocolAndPermissions(memory);
    traditionalEncoding(memory);
    lifetimeAndPressure(memory);
    resetBeforeConsent(memory);
    asynchronousOrder(memory);
    check(memory.liveBytes() == 0);
  }
  encodingFailure(false);
  encodingFailure(true);
  encodingFailure(false, true);
  encodingFailure(true, true);
  actualRouting(system);
  deferredAllocationFailure();
  std::puts("Native clipboard protocol, consent, routing and ownership tests passed");
}
