#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../diagnostics/line.hpp"
#include "telar_platform/trace.hpp"
#include "../graphics/kitty_framing.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstring>
#include <variant>
#include "../graphics/media_budget.hpp"
#include "../graphics/kitty_control.hpp"
#include <cstddef>
#include <cstdint>
#include <span>
#include <algorithm>
#include "../graphics/child_file.hpp"
#include "telar_platform/graphics/child_shared_memory.hpp"
#include <utility>
#include "../terminal/control/classification.hpp"
#include "../terminal/control/parser.hpp"
#include "../terminal/pty_response_queue.hpp"
#include "telar_base/memory/allocator.hpp"
#include <stdexcept>
#include "../graphics/temporary_path.hpp"
#include <charconv>
#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
#include <optional>
#include "telar_base/diagnostics/config.hpp"
#include "telar_config/graphics/limits.hpp"
#include <limits>
#include "telar_platform/file_descriptor.hpp"
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <string_view>
#include <sys/mman.h>
#include <atomic>
#include "telar_client/serializers/telar_frame.hpp"
#include "cell_layout.hpp"
#include "../terminal/control/engine.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "../terminal/graphics_cursor.hpp"
#include <cassert>
#include <sys/types.h>
#include <chrono>
#include <bit>
#include <concepts>
#include "telar_client/serializers/telar_messages.hpp"
#include <exception>
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/serializers/telar_serializer.hpp"
#include <cerrno>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include <unistd.h>
#include <tuple>
#include <memory>
#include "telar_base/program_identity.hpp"
#include <limits.h>
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>
#include <system_error>
#include "telar_base/diagnostics/limit_reach.hpp"
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#include <sched.h>
#endif
#if (defined(__linux__))
#include <sys/epoll.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__))
#endif
#include <new>
#include "telar_config/terminal/control/policy.hpp"
#include <sys/stat.h>
#include "client_peer.hpp"
#include "clipboard_task.hpp"
#include <poll.h>
#include <termios.h>



import telar.runtime.terminal.text_reader;
import telar.runtime.runtime.delivery.client_delivery;
import telar.runtime.runtime.runtime;

using namespace telar;
using namespace telar::runtime;
using namespace telar::runtime::control_test;

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

void finishDesktop(auto &panes, auto &client, auto &pane, const OwnedClipboardTask &task, const ClipboardResult &result) {
  std::array<ClipboardRepresentation, 4> contents;
  std::array<std::string_view, 16> available;
  check(result.contents.size() <= contents.size() && result.available.size() <= available.size());
  for (std::size_t index = 0; index < result.contents.size(); ++index) {
    contents[index] = {result.contents[index].mime, result.contents[index].data};
  }
  for (std::size_t index = 0; index < result.available.size(); ++index) {
    available[index] = result.available[index];
  }
  check(ClipboardService<SystemAllocator>::complete(panes, client.session(), CompleteClipboardDesktop{
      .ticket = task.ticket,
      .status = result.status,
      .contents = std::span{contents}.first(result.contents.size()),
      .available = std::span{available}.first(result.available.size()),
  }) == &pane);
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

std::string ptyUntil(int descriptor, std::string_view suffix, std::string_view marker = {}) {
  std::string result;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{3};
  while (!result.ends_with(suffix) || !result.contains(marker)) {
    check(std::chrono::steady_clock::now() < deadline);
    pollfd pending{.fd = descriptor, .events = POLLIN, .revents = 0};
    if (::poll(&pending, 1, 10) <= 0) {
      continue;
    }
    std::array<char, 4096> output;
    const auto count = ::read(descriptor, output.data(), output.size());
    check(count > 0);
    result.append(output.data(), static_cast<std::size_t>(count));
    check(result.size() <= 8192);
  }
  return result;
}

std::string pasteGrant(auto &model, auto &clients, auto &panes, auto &client, auto &pane) {
  termios settings{};
  check(::tcgetattr(pane.process->descriptor(), &settings) == 0);
  ::cfmakeraw(&settings);
  check(::tcsetattr(pane.process->descriptor(), TCSANOW, &settings) == 0);
  pane.terminal.feed(bytes("\x1b[?5522h"));
  const std::array<std::string_view, 1> available{"text/plain"};
  panes.pasteClipboard(model, clients, client.session().id, PastePaneClipboard{.request_id = 4242, .pane_id = pane.id, .pane_generation = pane.generation, .listing_only = true, .text = {}, .available = available});
  check(client.template receive<RequestCompleted>().request_id == 4242);
  const auto listing = ptyUntil(pane.process->descriptor(), "\x1b\\", "status=DONE:pw=");
  constexpr std::string_view prefix = "\x1b]5522;type=read:status=OK:pw=";
  check(listing.starts_with(prefix));
  const auto end = listing.find("\x1b\\", prefix.size());
  check(end != std::string::npos && end - prefix.size() == 32);
  return listing.substr(prefix.size(), end - prefix.size());
}

void actualRouting(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/clipboard.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientPeer first{memory, model, clients, ClientRole::interactive};
  ClientPeer second{memory, model, clients, ClientRole::interactive};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  workspaces.open(model, panes, clients, first.session().id, OpenPane{.request_id = 1, .size = {80, 24, 9, 18}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  const auto opened = first.receive<PaneOpened>();
  auto &pane = panes.require(model.panes, opened.pane_id);
  panes.attach(model, second.session(), pane.id, {80, 24, 9, 18});
  ConfigurePaneDesktop desktop{.pane_id = pane.id, .pane_generation = pane.generation, .visible = true, .clipboard = true};
  panes.configureDesktop(model, clients, first.session().id, desktop);
  desktop.focused = true;
  panes.configureDesktop(model, clients, second.session().id, desktop);
  pane.terminal.feed(bytes("\x1b]5522;type=read:id=route;dGV4dC9wbGFpbg==\x1b\\"));
  ClipboardService<SystemAllocator> service;
  service.advance(clients, pane, std::chrono::steady_clock::now());
  const auto request = second.receive<ClipboardDesktopRequest>();
  OwnedClipboardTask task{request};
  check(task.ticket.pane_id == pane.id && task.ticket.client_generation == second.session().generation);
  CompleteClipboardDesktop completion{.ticket = task.ticket, .status = ClipboardDesktopStatus::denied, .prepared = true};
  check(service.complete(model.panes, first.session(), completion) == nullptr);
  ++completion.ticket.pane_generation;
  check(service.complete(model.panes, second.session(), completion) == nullptr);
  --completion.ticket.pane_generation;
  check(service.complete(model.panes, second.session(), completion) == &pane);
  check(drain(pane.terminal) == "\x1b]5522;type=read:status=EPERM:id=route\x1b\\");
  check(service.complete(model.panes, second.session(), completion) == nullptr);

  const auto descriptor = pane.process->descriptor();
  termios attributes{};
  check(::tcgetattr(descriptor, &attributes) == 0);
  ::cfmakeraw(&attributes);
  check(::tcsetattr(descriptor, TCSANOW, &attributes) == 0);
  service.configure(clients, pane);
  const std::array<std::string_view, 2> available{"text/plain", "text/html"};
  PastePaneClipboard paste{.request_id = 41, .pane_id = pane.id, .pane_generation = pane.generation, .listing_only = true, .text = bytes("must-not-be-pasted"), .available = available};
  pane.terminal.feed(bytes("\x1b[?5522h"));
  panes.pasteClipboard(model, clients, second.session().id, paste);
  check(second.receive<RequestCompleted>().request_id == paste.request_id);
  const auto event = ptyUntil(descriptor, "\x1b\\", "status=DONE:pw=");
  check(event.starts_with("\x1b]5522;type=read:status=OK:pw="));
  check(event.contains("status=DATA:mime=Lg==:pw="));
  check(event.contains(";dGV4dC9wbGFpbiB0ZXh0L2h0bWwK\x1b\\"));
  check(event.contains("status=DONE:pw=") && !event.contains("must-not-be-pasted"));

  const auto password_start = event.find(":pw=") + std::string_view{":pw="}.size();
  const auto password_end = event.find("\x1b\\", password_start);
  check(password_end != std::string::npos && password_end > password_start);
  const auto password = event.substr(password_start, password_end - password_start);
  MemoryClipboard provider;
  for (unsigned step = 0; step < 3; ++step) {
    const auto id = std::to_string(step);
    const auto request_bytes = "\x1b]5522;type=read:id=" + id + ":name=QXBw:pw=" + password + ";" + (step == 0 ? "Lg==" : "dGV4dC9wbGFpbg==") + "\x1b\\";
    pane.terminal.feed(bytes(request_bytes));
    service.advance(clients, pane, std::chrono::steady_clock::now());
    const OwnedClipboardTask read_task{second.receive<ClipboardDesktopRequest>()};
    check(read_task.prompt == (step == 2) && read_task.listing == (step == 0));
    check(service.complete(model.panes, second.session(), CompleteClipboardDesktop{.ticket = read_task.ticket, .status = step == 2 ? ClipboardDesktopStatus::denied : ClipboardDesktopStatus::success, .prepared = true}) == &pane);
    if (step != 2) {
      service.advance(clients, pane, std::chrono::steady_clock::now());
      check(second.receive<ClipboardDesktopExecute>().ticket == read_task.ticket);
      finishDesktop(model.panes, second, pane, read_task, executeClipboard(read_task, ClipboardConsent::once, provider));
    }
    panes.flushInput(pane);
    const auto suffix = step == 2 ? std::string{"status=EPERM:id=2\x1b\\"} : "status=DONE:id=" + id + "\x1b\\";
    const auto response = ptyUntil(descriptor, suffix);
    if (step == 2) {
      check(response == "\x1b]5522;type=read:status=EPERM:id=2\x1b\\");
    } else {
      const auto expected_data = step == 0 ? "mime=Lg==;dGV4dC9wbGFpbiB0ZXh0L2h0bWwK" : "mime=dGV4dC9wbGFpbg==;aGVsbG8=";
      const auto expected = "\x1b]5522;type=read:status=OK:id=" + id + "\x1b\\\x1b]5522;type=read:status=DATA:id=" + id + ":" + expected_data + "\x1b\\\x1b]5522;type=read:status=DONE:id=" + id + "\x1b\\";
      check(response == expected);
    }
  }
  check(provider.reads == 2 && provider.writes == 0);

  pane.terminal.feed(bytes("\x1b[?5522l"));
  ++paste.request_id;
  panes.pasteClipboard(model, clients, second.session().id, paste);
  check(second.receive<RequestCompleted>().request_id == paste.request_id);
  check(pane.input.empty() && pane.terminal.responses().empty());
  pane.terminal.feed(bytes("\x1b[?5522h\x1b[?2004h"));
  ++paste.request_id;
  paste.listing_only = false;
  paste.text = {};
  panes.pasteClipboard(model, clients, second.session().id, paste);
  check(second.receive<RequestCompleted>().request_id == paste.request_id);
  ++paste.request_id;
  paste.text = bytes("ordinary text");
  panes.pasteClipboard(model, clients, second.session().id, paste);
  check(second.receive<RequestCompleted>().request_id == paste.request_id);
  check(ptyUntil(descriptor, "\x1b[201~") == "\x1b[200~ordinary text\x1b[201~");
  panes.remove(model, clients, pane.id);

}

void closeBeforeExecution(SystemAllocator &memory) {
  RuntimeModel model{memory};
  ClientStore<SystemAllocator> clients{memory};
  LimitService<SystemAllocator> limits;
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/clipboard-close.sock"}};
  WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
  ClientPeer client{memory, model, clients, ClientRole::interactive};
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  workspaces.open(model, panes, clients, client.session().id, OpenPane{.request_id = 1, .size = {80, 24, 9, 18}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  auto &pane = panes.require(model.panes, client.receive<PaneOpened>().pane_id);
  ConfigurePaneDesktop desktop{.pane_id = pane.id, .pane_generation = pane.generation, .visible = true, .clipboard = true};
  panes.configureDesktop(model, clients, client.session().id, desktop);
  pane.terminal.feed(bytes("\x1b]5522;type=write:id=close\x1b\\\x1b]5522;type=wdata\x1b\\"));
  ClipboardService<SystemAllocator> service;
  service.advance(clients, pane, std::chrono::steady_clock::now());
  const OwnedClipboardTask task{client.receive<ClipboardDesktopRequest>()};
  const CompleteClipboardDesktop prepared{.ticket = task.ticket, .status = ClipboardDesktopStatus::success, .prepared = true};
  check(service.complete(model.panes, client.session(), prepared) == &pane);
  workspaces.closePane(model, client.session(), ClosePane{.request_id = 2, .pane_id = pane.id});
  check(pane.close_requested && !pane.output_closed);
  service.advance(clients, pane, std::chrono::steady_clock::now());
  service.advance(clients, pane, std::chrono::steady_clock::now());
  const auto response = client.receiveAny<ClipboardDesktopExecute, CancelClipboardDesktop>();
  MemoryClipboard provider;
  if (const auto *execution = std::get_if<ClipboardDesktopExecute>(&response)) {
    check(execution->ticket == task.ticket);
    executeClipboard(task, ClipboardConsent::once, provider);
    std::fprintf(stderr, "Clipboard provider effects after accepted close: reads=%u writes=%u\n", provider.reads, provider.writes);
  }
  check(provider.inspections == 0 && provider.reads == 0 && provider.writes == 0);
  check(std::get<CancelClipboardDesktop>(response).ticket == task.ticket);
  check(drain(pane.terminal) == "\x1b]5522;type=write:status=EPERM:id=close\x1b\\");
  check(service.complete(model.panes, client.session(), prepared) == nullptr);
  panes.remove(model, clients, pane.id);
}

void resetPendingOperations(SystemAllocator &memory) {
  enum class Stage { requested, prepared, committed };
  constexpr std::array<std::string_view, 3> transitions{"\x1b" "c", "\x1b[!p", "\x1b[?1049h\x1b[?1049l"};
  for (const auto transition : transitions) {
    for (const auto stage : {Stage::requested, Stage::prepared, Stage::committed}) {
      RuntimeModel model{memory};
      ClientStore<SystemAllocator> clients{memory};
      LimitService<SystemAllocator> limits;
      NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
      PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/clipboard-reset.sock"}};
      WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
      ClientPeer client{memory, model, clients, ClientRole::interactive};
      const std::array<std::string_view, 1> arguments{"/bin/cat"};
      workspaces.open(model, panes, clients, client.session().id, OpenPane{.request_id = 1, .size = {80, 24, 9, 18}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
      auto &pane = panes.require(model.panes, client.receive<PaneOpened>().pane_id);
      panes.configureDesktop(model, clients, client.session().id, ConfigurePaneDesktop{.pane_id = pane.id, .pane_generation = pane.generation, .visible = true, .clipboard = true});
      ClipboardService<SystemAllocator> service;
      const auto password = pasteGrant(model, clients, panes, client, pane);
      pane.terminal.feed(bytes("\x1b]5522;type=write:id=reset\x1b\\\x1b]5522;type=wdata\x1b\\"));
      service.advance(clients, pane, std::chrono::steady_clock::now());
      const OwnedClipboardTask task{client.receive<ClipboardDesktopRequest>()};
      const CompleteClipboardDesktop prepared{.ticket = task.ticket, .status = ClipboardDesktopStatus::success, .prepared = true};
      MemoryClipboard provider;
      std::optional<ClipboardResult> result;
      if (stage != Stage::requested) {
        check(service.complete(model.panes, client.session(), prepared) == &pane);
      }
      if (stage == Stage::committed) {
        service.advance(clients, pane, std::chrono::steady_clock::now());
        check(client.receive<ClipboardDesktopExecute>().ticket == task.ticket);
        result = executeClipboard(task, ClipboardConsent::once, provider);
        check(provider.writes == 1);
      }

      pane.terminal.feed(bytes(transition));
      const bool full_reset = transition == transitions.front();
      service.advance(clients, pane, std::chrono::steady_clock::now());
      if (full_reset) {
        check(client.receive<CancelClipboardDesktop>().ticket == task.ticket);
        check(!pane.terminal.clipboardControl().route() && !pane.terminal.clipboardControl().execution());
        check(service.complete(model.panes, client.session(), prepared) == nullptr);
        check(service.complete(model.panes, client.session(), CompleteClipboardDesktop{.ticket = task.ticket, .status = ClipboardDesktopStatus::success}) == nullptr);
        check(drain(pane.terminal) == "\x1b]5522;type=write:status=EPERM:id=reset\x1b\\");
      } else {
        if (stage == Stage::requested) {
          check(service.complete(model.panes, client.session(), prepared) == &pane);
          service.advance(clients, pane, std::chrono::steady_clock::now());
        }
        if (stage != Stage::committed) {
          check(client.receive<ClipboardDesktopExecute>().ticket == task.ticket);
          result = executeClipboard(task, ClipboardConsent::once, provider);
        }
        finishDesktop(model.panes, client, pane, task, *result);
        check(drain(pane.terminal) == "\x1b]5522;type=write:status=DONE:id=reset\x1b\\");
      }
      const unsigned expected_writes = full_reset && stage != Stage::committed ? 0 : 1;
      check(provider.writes == expected_writes && provider.inspections == expected_writes && provider.reads == 0);
      check(!pane.terminal.hasPendingControl());
      pane.terminal.feed(bytes("\x1b]5522;type=read:id=otp:name=QXBw:pw=" + password + ";dGV4dC9wbGFpbg==\x1b\\"));
      service.advance(clients, pane, std::chrono::steady_clock::now());
      const OwnedClipboardTask otp{client.receive<ClipboardDesktopRequest>()};
      check(otp.prompt == full_reset);
      check(service.complete(model.panes, client.session(), CompleteClipboardDesktop{.ticket = otp.ticket, .status = full_reset ? ClipboardDesktopStatus::denied : ClipboardDesktopStatus::success, .prepared = true}) == &pane);
      if (!full_reset) {
        service.advance(clients, pane, std::chrono::steady_clock::now());
        check(client.receive<ClipboardDesktopExecute>().ticket == otp.ticket);
        finishDesktop(model.panes, client, pane, otp, executeClipboard(otp, ClipboardConsent::once, provider));
      }
      check(drain(pane.terminal) == (full_reset ? "\x1b]5522;type=read:status=EPERM:id=otp\x1b\\" : "\x1b]5522;type=read:status=OK:id=otp\x1b\\\x1b]5522;type=read:status=DONE:id=otp\x1b\\"));
      check(provider.reads == (full_reset ? 0u : 1u));
      if (stage == Stage::requested) {
        pane.terminal.controlPolicy().clipboard_write = control::Access::ask;
        constexpr std::string_view grant_request = "\x1b]5522;type=write:id=grant:name=QXBw:pw=cHc=\x1b\\\x1b]5522;type=wdata\x1b\\";
        pane.terminal.feed(bytes(grant_request));
        service.advance(clients, pane, std::chrono::steady_clock::now());
        const OwnedClipboardTask grant{client.receive<ClipboardDesktopRequest>()};
        check(grant.prompt && grant.rememberable);
        check(service.complete(model.panes, client.session(), CompleteClipboardDesktop{.ticket = grant.ticket, .status = ClipboardDesktopStatus::success, .remember = true, .prepared = true}) == &pane);
        service.advance(clients, pane, std::chrono::steady_clock::now());
        check(client.receive<ClipboardDesktopExecute>().ticket == grant.ticket);
        finishDesktop(model.panes, client, pane, grant, executeClipboard(grant, ClipboardConsent::session, provider));
        check(drain(pane.terminal) == "\x1b]5522;type=write:status=DONE:id=grant\x1b\\");
        pane.terminal.feed(bytes(transition));
        pane.terminal.feed(bytes(grant_request));
        service.advance(clients, pane, std::chrono::steady_clock::now());
        const OwnedClipboardTask repeated{client.receive<ClipboardDesktopRequest>()};
        check(repeated.prompt == full_reset);
        check(service.complete(model.panes, client.session(), CompleteClipboardDesktop{.ticket = repeated.ticket, .status = full_reset ? ClipboardDesktopStatus::denied : ClipboardDesktopStatus::success, .prepared = true}) == &pane);
        if (!full_reset) {
          service.advance(clients, pane, std::chrono::steady_clock::now());
          check(client.receive<ClipboardDesktopExecute>().ticket == repeated.ticket);
          finishDesktop(model.panes, client, pane, repeated, executeClipboard(repeated, ClipboardConsent::once, provider));
        }
        check(drain(pane.terminal) == (full_reset ? "\x1b]5522;type=write:status=EPERM:id=grant\x1b\\" : "\x1b]5522;type=write:status=DONE:id=grant\x1b\\"));
        check(provider.writes == expected_writes + 1 + static_cast<unsigned>(!full_reset));
      }
      panes.remove(model, clients, pane.id);
    }
  }
}

void doubleQueuePressure(SystemAllocator &memory) {
  enum class Cancellation { expired, closing, unannounced };
  for (const auto cancellation : {Cancellation::expired, Cancellation::closing, Cancellation::unannounced}) {
    RuntimeModel model{memory};
    ClientStore<SystemAllocator> clients{memory};
    LimitService<SystemAllocator> limits;
    NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
    PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/clipboard-pressure.sock"}};
    WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
    ClientPeer client{memory, model, clients, ClientRole::interactive};
    const std::array<std::string_view, 1> arguments{"/bin/cat"};
    workspaces.open(model, panes, clients, client.session().id, OpenPane{.request_id = 1, .size = {80, 24, 9, 18}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
    auto &pane = panes.require(model.panes, client.receive<PaneOpened>().pane_id);
    panes.configureDesktop(model, clients, client.session().id, ConfigurePaneDesktop{.pane_id = pane.id, .pane_generation = pane.generation, .visible = true, .clipboard = true});
    pane.terminal.feed(bytes("\x1b]5522;type=write:id=pressure\x1b\\\x1b]5522;type=wdata\x1b\\"));
    ClipboardService<SystemAllocator> service;
    auto &clipboard = pane.terminal.clipboardControl();
    std::optional<OwnedClipboardTask> task;
    if (cancellation != Cancellation::unannounced) {
      service.advance(clients, pane, std::chrono::steady_clock::now());
      task.emplace(client.receive<ClipboardDesktopRequest>());
      check(service.complete(model.panes, client.session(), CompleteClipboardDesktop{.ticket = task->ticket, .status = ClipboardDesktopStatus::success, .prepared = true}) == &pane);
      check(clipboard.execution().has_value());
    }
    constexpr auto client_capacity = OutgoingFrames<SystemAllocator>::response_capacity;
    for (std::size_t index = 0; index < client_capacity; ++index) {
      client.session().connection.send(RequestCompleted{.request_id = 900 + index});
    }
    for (std::size_t index = 0; index < PtyResponseQueue::message_capacity; ++index) {
      check(pane.pty_responses->tryPush(bytes("N")));
    }
    MemoryClipboard provider;
    service.advance(clients, pane, std::chrono::steady_clock::now());
    if (task) {
      check(clipboard.execution().has_value());
    }
    if (cancellation == Cancellation::closing) {
      workspaces.closePane(model, client.session(), ClosePane{.request_id = 2, .pane_id = pane.id});
      service.advance(clients, pane, std::chrono::steady_clock::now());
    } else {
      service.advance(clients, pane, std::chrono::steady_clock::now() + std::chrono::seconds{31});
    }
    service.advance(clients, pane, std::chrono::steady_clock::now());
    check(!clipboard.execution() && !clipboard.route() && clipboard.hasReply());
    check(clipboard.cancellation().has_value() == task.has_value());
    check(!client.session().connection.closing && client.session().connection.responseDepth() == client_capacity);
    check(client.session().connection.droppedResponses() == 0);
    check(pane.pty_responses->snapshot().messages == PtyResponseQueue::message_capacity && pane.pty_responses->snapshot().dropped == 0);
    check(provider.inspections == 0 && provider.reads == 0 && provider.writes == 0);

    for (std::size_t index = 0; index < client_capacity; ++index) {
      check(client.receive<RequestCompleted>().request_id == 900 + index);
    }
    service.advance(clients, pane, std::chrono::steady_clock::now());
    service.advance(clients, pane, std::chrono::steady_clock::now());
    check(client.session().connection.responseDepth() == (task ? 1 : 0));
    if (task) {
      check(client.receive<CancelClipboardDesktop>().ticket == task->ticket);
      check(service.complete(model.panes, client.session(), CompleteClipboardDesktop{.ticket = task->ticket, .status = ClipboardDesktopStatus::success, .prepared = true}) == nullptr);
      check(service.complete(model.panes, client.session(), CompleteClipboardDesktop{.ticket = task->ticket, .status = ClipboardDesktopStatus::success}) == nullptr);
    }
    check(drain(pane.terminal) == std::string(PtyResponseQueue::message_capacity, 'N') + "\x1b]5522;type=write:status=EPERM:id=pressure\x1b\\");
    check(!clipboard.hasReply() && !clipboard.cancellation());
    if (cancellation != Cancellation::closing) {
      pane.terminal.feed(bytes("\x1b]5522;type=write:id=again\x1b\\\x1b]5522;type=wdata\x1b\\"));
      service.advance(clients, pane, std::chrono::steady_clock::now());
      const OwnedClipboardTask next{client.receive<ClipboardDesktopRequest>()};
      check(service.complete(model.panes, client.session(), CompleteClipboardDesktop{.ticket = next.ticket, .status = ClipboardDesktopStatus::success, .prepared = true}) == &pane);
      service.advance(clients, pane, std::chrono::steady_clock::now());
      check(client.receive<ClipboardDesktopExecute>().ticket == next.ticket);
      const auto result = executeClipboard(next, ClipboardConsent::once, provider);
      check(provider.writes == 1);
      const CompleteClipboardDesktop completed{.ticket = next.ticket, .status = result.status};
      check(service.complete(model.panes, client.session(), completed) == &pane);
      check(drain(pane.terminal) == "\x1b]5522;type=write:status=DONE:id=again\x1b\\");
      check(service.complete(model.panes, client.session(), completed) == nullptr && provider.writes == 1);
    }
    panes.remove(model, clients, pane.id);
  }
}

void revokedCapabilitiesAndReuse(SystemAllocator &memory) {
  enum class Change { hidden, clipboard_disabled, control_only, pane_reused };
  enum class Stage { requested, prepared, committed };
  for (const auto change : {Change::hidden, Change::clipboard_disabled, Change::control_only, Change::pane_reused}) {
    for (const auto stage : {Stage::requested, Stage::prepared, Stage::committed}) {
      RuntimeModel model{memory};
      ClientStore<SystemAllocator> clients{memory};
      LimitService<SystemAllocator> limits;
      NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
      PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/clipboard-capability.sock"}};
      WorkspaceService<SystemAllocator, decltype(poller)> workspaces{memory};
      ClientPeer client{memory, model, clients, ClientRole::interactive};
      const std::array<std::string_view, 1> arguments{"/bin/cat"};
      const Launch launch{.cwd = "/tmp", .arguments = arguments};
      constexpr TerminalSize size{80, 24, 9, 18};
      workspaces.open(model, panes, clients, client.session().id, OpenPane{.request_id = 1, .size = size, .launch = launch});
      auto *pane = &panes.require(model.panes, client.receive<PaneOpened>().pane_id);
      termios settings{};
      check(::tcgetattr(pane->process->descriptor(), &settings) == 0);
      ::cfmakeraw(&settings);
      check(::tcsetattr(pane->process->descriptor(), TCSANOW, &settings) == 0);
      ConfigurePaneDesktop desktop{.pane_id = pane->id, .pane_generation = pane->generation, .visible = true, .clipboard = true};
      panes.configureDesktop(model, clients, client.session().id, desktop);
      ClipboardService<SystemAllocator> service;
      const auto password = pasteGrant(model, clients, panes, client, *pane);
      pane->terminal.feed(bytes("\x1b]5522;type=write:id=old\x1b\\\x1b]5522;type=wdata\x1b\\"));
      service.advance(clients, *pane, std::chrono::steady_clock::now());
      const OwnedClipboardTask old{client.receive<ClipboardDesktopRequest>()};
      const CompleteClipboardDesktop prepared{.ticket = old.ticket, .status = ClipboardDesktopStatus::success, .prepared = true};
      MemoryClipboard provider;
      if (stage != Stage::requested) {
        check(service.complete(model.panes, client.session(), prepared) == pane);
      }
      if (stage == Stage::committed) {
        service.advance(clients, *pane, std::chrono::steady_clock::now());
        check(client.receive<ClipboardDesktopExecute>().ticket == old.ticket);
        check(executeClipboard(old, ClipboardConsent::once, provider).status == ClipboardDesktopStatus::success);
      }
      const auto previous_writes = provider.writes;
      if (change == Change::pane_reused) {
        const auto identity = pane->id;
        const auto location = pane->location;
        panes.remove(model, clients, identity);
        Command command{memory, launch};
        pane = &panes.launch(model, nullptr, command, location, size, identity);
        check(pane->id == old.ticket.pane_id && pane->generation != old.ticket.pane_generation);
        panes.attach(model, client.session(), pane->id, size);
        bool rejected = false;
        try {
          panes.configureDesktop(model, clients, client.session().id, desktop);
        } catch (const RequestError &) {
          rejected = true;
        }
        check(rejected);
      } else if (change == Change::control_only) {
        client.session().role = ClientRole::control;
      } else {
        desktop.visible = change != Change::hidden;
        desktop.clipboard = change != Change::clipboard_disabled;
        panes.configureDesktop(model, clients, client.session().id, desktop);
      }
      check(service.complete(model.panes, client.session(), prepared) == nullptr);
      check(service.complete(model.panes, client.session(), CompleteClipboardDesktop{.ticket = old.ticket, .status = ClipboardDesktopStatus::success}) == nullptr);
      service.advance(clients, *pane, std::chrono::steady_clock::now());
      service.advance(clients, *pane, std::chrono::steady_clock::now());
      if (change != Change::pane_reused) {
        check(client.receive<CancelClipboardDesktop>().ticket == old.ticket);
        panes.flushInput(*pane);
        check(ptyUntil(pane->process->descriptor(), "status=EPERM:id=old\x1b\\") == "\x1b]5522;type=write:status=EPERM:id=old\x1b\\");
      } else {
        check(drain(pane->terminal).empty());
      }
      check(provider.writes == previous_writes && previous_writes == (stage == Stage::committed ? 1u : 0u));
      client.session().role = ClientRole::interactive;
      desktop.pane_generation = pane->generation;
      desktop.visible = true;
      desktop.clipboard = true;
      panes.configureDesktop(model, clients, client.session().id, desktop);
      service.configure(clients, *pane);
      pane->terminal.feed(bytes("\x1b]5522;type=read:id=otp:name=QXBw:pw=" + password + ";dGV4dC9wbGFpbg==\x1b\\"));
      service.advance(clients, *pane, std::chrono::steady_clock::now());
      const OwnedClipboardTask otp{client.receive<ClipboardDesktopRequest>()};
      check(otp.prompt);
      check(service.complete(model.panes, client.session(), CompleteClipboardDesktop{.ticket = otp.ticket, .status = ClipboardDesktopStatus::denied, .prepared = true}) == pane);
      check(drain(pane->terminal) == "\x1b]5522;type=read:status=EPERM:id=otp\x1b\\");
      check(provider.writes == previous_writes && provider.reads == 0);
      pane->terminal.feed(bytes("\x1b]5522;type=write:id=fresh\x1b\\\x1b]5522;type=wdata\x1b\\"));
      service.advance(clients, *pane, std::chrono::steady_clock::now());
      const OwnedClipboardTask fresh{client.receive<ClipboardDesktopRequest>()};
      check(fresh.ticket.nonce != old.ticket.nonce);
      check(service.complete(model.panes, client.session(), prepared) == nullptr);
      check(service.complete(model.panes, client.session(), CompleteClipboardDesktop{.ticket = fresh.ticket, .status = ClipboardDesktopStatus::success, .prepared = true}) == pane);
      service.advance(clients, *pane, std::chrono::steady_clock::now());
      check(client.receive<ClipboardDesktopExecute>().ticket == fresh.ticket);
      finishDesktop(model.panes, client, *pane, fresh, executeClipboard(fresh, ClipboardConsent::once, provider));
      check(provider.writes == previous_writes + 1 && provider.reads == 0);
      check(drain(pane->terminal) == "\x1b]5522;type=write:status=DONE:id=fresh\x1b\\");
      panes.remove(model, clients, pane->id);
    }
  }
}

void deferredAllocationFailure() {
  FailingAllocator upstream;
  BudgetAllocator memory{upstream, 64 * 1024 * 1024};
  {
    RuntimeModel model{memory};
    ClientStore<decltype(memory)> clients{memory};
    LimitService<decltype(memory)> limits;
    NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
    PaneService panes{memory, poller, limits, PaneLaunchOptions{.socket = "/unused/control-failure.sock"}};
    const std::array<std::string_view, 1> arguments{"/bin/cat"};
    const Launch launch{.cwd = "/tmp", .arguments = arguments};
    const TabLocation location{.workspace = {.id = 7}, .tab_id = 1};
    auto &failed = panes.launch(model, nullptr, launch, location, {80, 24, 9, 18});
    auto &healthy = panes.launch(model, nullptr, launch, location, {80, 24, 9, 18});
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
    panes.remove(model, clients, failed_id);
    panes.remove(model, clients, healthy_id);
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
  closeBeforeExecution(system);
  resetPendingOperations(system);
  doubleQueuePressure(system);
  revokedCapabilitiesAndReuse(system);
  deferredAllocationFailure();
  std::puts("Native clipboard protocol, consent, routing and ownership tests passed");
}
