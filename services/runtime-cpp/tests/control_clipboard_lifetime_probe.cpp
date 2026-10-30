#include "check.hpp"
#include "protocol_peer.hpp"
#include "ui/workbench/clipboard_task.hpp"
#include <chrono>
#include <poll.h>
#include <termios.h>
#include <thread>

using namespace telar;
using namespace workbench;
using Clock = std::chrono::steady_clock;

namespace {
void writeAll(std::string_view bytes) {
  while (!bytes.empty()) {
    const auto count = ::write(STDOUT_FILENO, bytes.data(), bytes.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }
    check(count > 0);
    bytes.remove_prefix(static_cast<std::size_t>(count));
  }
}

void expectInput(std::string_view expected) {
  std::string received;
  const auto deadline = Clock::now() + std::chrono::seconds{10};
  while (received.size() < expected.size()) {
    check(Clock::now() < deadline);
    pollfd pending{STDIN_FILENO, POLLIN, 0};
    const auto ready = ::poll(&pending, 1, 50);
    if (ready < 0 && errno == EINTR) {
      continue;
    }
    check(ready >= 0);
    if (ready == 0) {
      continue;
    }
    std::array<char, 256> bytes;
    const auto count = ::read(STDIN_FILENO, bytes.data(), std::min(bytes.size(), expected.size() - received.size()));
    check(count > 0);
    received.append(bytes.data(), static_cast<std::size_t>(count));
  }
  check(received == expected);
}

std::string readListing() {
  std::string result;
  unsigned endings = 0;
  const auto deadline = Clock::now() + std::chrono::seconds{5};
  while (endings != 3) {
    check(Clock::now() < deadline);
    pollfd pending{STDIN_FILENO, POLLIN, 0};
    if (::poll(&pending, 1, 50) <= 0) {
      continue;
    }
    char byte;
    check(::read(STDIN_FILENO, &byte, 1) == 1);
    result += byte;
    check(result.size() <= 1024);
    endings += result.ends_with("\x1b\\");
  }
  return result;
}

int child(const char *report) {
  termios settings{};
  check(::tcgetattr(STDIN_FILENO, &settings) == 0);
  ::cfmakeraw(&settings);
  check(::tcsetattr(STDIN_FILENO, TCSANOW, &settings) == 0);
  writeAll("\r\nclipboard-child-ready\r\n");
  expectInput("S");
  writeAll("\x1b[?5522h\r\npaste-grant-ready\r\n");
  const auto listing = readListing();
  constexpr std::string_view prefix = "\x1b]5522;type=read:status=OK:pw=";
  check(listing.starts_with(prefix));
  const auto end = listing.find("\x1b\\", prefix.size());
  check(end != std::string::npos);
  const auto password = listing.substr(prefix.size(), end - prefix.size());
  check(password.size() == 32);
  check(listing == std::string{prefix} + password + "\x1b\\\x1b]5522;type=read:status=DATA:mime=Lg==:pw=" + password + ";dGV4dC9wbGFpbgo=\x1b\\\x1b]5522;type=read:status=DONE:pw=" + password + "\x1b\\");
  writeAll("\x1b]5522;type=write:id=old\x1b\\\x1b]5522;type=wdata\x1b\\");
  expectInput("\x1b]5522;type=write:status=EPERM:id=old\x1b\\");
  writeAll("\r\nold-operation-denied\r\n");
  expectInput("N");
  writeAll("\x1b]5522;type=read:id=grant:name=QXBw:pw=" + password + ";dGV4dC9wbGFpbg==\x1b\\");
  expectInput("\x1b]5522;type=read:status=EPERM:id=grant\x1b\\");
  writeAll("\x1b]5522;type=write:id=fresh\x1b\\\x1b]5522;type=wdata\x1b\\");
  expectInput("\x1b]5522;type=write:status=DONE:id=fresh\x1b\\");
  std::ofstream output{report};
  output << "{\"old_denial_byte_exact\":true,\"fresh_completion_byte_exact\":true,\"old_paste_grant_revoked\":true}\n";
  output.close();
  check(output.good());
  writeAll("\r\nclipboard-lifetime-complete\r\n");
  char last;
  while (::read(STDIN_FILENO, &last, 1) > 0) {}
  return 0;
}

void awaitScreen(ProtocolPeer &peer, std::uint64_t pane, std::string_view marker) {
  const auto deadline = Clock::now() + std::chrono::seconds{5};
  while (Clock::now() < deadline) {
    const auto text = peer.exchange<PaneText>(ReadPane{.request_id = 90, .pane_id = pane, .rows = 24});
    if (text.text.contains(marker)) {
      return;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds{2});
  }
  check(false);
}

struct MemoryClipboard {
  unsigned writes = 0;
  bool supports(bool primary) const { return !primary; }
  ClipboardResult read(const OwnedClipboardTask &) { std::abort(); }
  ClipboardResult write(const OwnedClipboardTask &task) {
    check(task.contents.empty());
    ++writes;
    return {.status = ClipboardDesktopStatus::success};
  }
};

int parent(char **argv) {
  const std::string_view stage{argv[3]};
  check(stage == "requested" || stage == "committed");
  ProtocolPeer peer{argv[1]};
  peer.send(RequestRuntimeState{.client_identity = 103, .interactive = true});
  const std::array<std::string_view, 3> arguments{argv[0], "--clipboard-child", argv[2]};
  const auto opened = peer.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  ConfigurePaneDesktop desktop{.pane_id = opened.pane_id, .pane_generation = opened.pane_generation, .visible = true, .focused = true, .clipboard = true};
  peer.send(desktop);
  awaitScreen(peer, opened.pane_id, "clipboard-child-ready");
  constexpr std::array<Byte, 1> start{'S'};
  peer.send(PaneInput{opened.pane_id, start});
  awaitScreen(peer, opened.pane_id, "paste-grant-ready");
  const std::array<std::string_view, 1> available{"text/plain"};
  check(peer.exchange<RequestCompleted>(PastePaneClipboard{.request_id = 4, .pane_id = opened.pane_id, .pane_generation = opened.pane_generation, .listing_only = true, .text = {}, .available = available}).request_id == 4);
  const OwnedClipboardTask old{peer.receive<ClipboardDesktopRequest>()};
  check(old.write && old.ticket.pane_generation == opened.pane_generation);
  MemoryClipboard provider;
  if (stage == "committed") {
    peer.send(CompleteClipboardDesktop{.ticket = old.ticket, .status = ClipboardDesktopStatus::success, .prepared = true});
    check(peer.receive<ClipboardDesktopExecute>().ticket == old.ticket);
    check(executeClipboard(old, ClipboardConsent::once, provider).status == ClipboardDesktopStatus::success);
  }
  const auto old_effects = provider.writes;
  peer.reconnect(argv[1]);
  peer.send(RequestRuntimeState{.client_identity = 103, .interactive = true});
  const auto attached = peer.exchange<PaneOpened>(OpenPane{.request_id = 2, .target = {.kind = PaneTarget::Kind::pane, .id = opened.pane_id}, .size = {80, 24, 0, 0}});
  check(!attached.created && attached.pane_generation == opened.pane_generation);
  peer.send(desktop);
  awaitScreen(peer, opened.pane_id, "old-operation-denied");
  peer.send(CompleteClipboardDesktop{.ticket = old.ticket, .status = ClipboardDesktopStatus::success, .prepared = true});
  peer.send(CompleteClipboardDesktop{.ticket = old.ticket, .status = ClipboardDesktopStatus::success});
  constexpr std::array<Byte, 1> next{'N'};
  peer.send(PaneInput{opened.pane_id, next});
  const OwnedClipboardTask revoked{peer.receive<ClipboardDesktopRequest>()};
  check(!revoked.write && revoked.prompt && revoked.ticket.client_generation != old.ticket.client_generation);
  peer.send(CompleteClipboardDesktop{.ticket = revoked.ticket, .status = ClipboardDesktopStatus::denied, .prepared = true});
  const OwnedClipboardTask fresh{peer.receive<ClipboardDesktopRequest>()};
  check(fresh.ticket.pane_id == old.ticket.pane_id && fresh.ticket.pane_generation == old.ticket.pane_generation);
  check(fresh.ticket.client_generation != old.ticket.client_generation && fresh.ticket.nonce != old.ticket.nonce);
  peer.send(CompleteClipboardDesktop{.ticket = old.ticket, .status = ClipboardDesktopStatus::success, .prepared = true});
  peer.send(CompleteClipboardDesktop{.ticket = fresh.ticket, .status = ClipboardDesktopStatus::success, .prepared = true});
  check(peer.receive<ClipboardDesktopExecute>().ticket == fresh.ticket);
  const auto result = executeClipboard(fresh, ClipboardConsent::once, provider);
  check(provider.writes == old_effects + 1);
  peer.send(CompleteClipboardDesktop{.ticket = fresh.ticket, .status = result.status});
  peer.send(CompleteClipboardDesktop{.ticket = fresh.ticket, .status = result.status});
  awaitScreen(peer, opened.pane_id, "clipboard-lifetime-complete");
  peer.send(ClosePane{.request_id = 3, .pane_id = opened.pane_id});
  std::printf("{\"stage\":\"%s\",\"old_provider_writes\":%u,\"fresh_provider_writes\":%u,\"client_generation_changed\":true,\"pane_generation_retained\":true}\n", argv[3], old_effects, provider.writes - old_effects);
  return 0;
}
}

int main(int argc, char **argv) {
  if (argc == 3 && std::string_view{argv[1]} == "--clipboard-child") {
    return child(argv[2]);
  }
  if (argc != 4) {
    return 2;
  }
  try {
    return parent(argv);
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
