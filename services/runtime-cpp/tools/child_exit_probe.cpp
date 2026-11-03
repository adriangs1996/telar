#include "terminal/screen.hpp"
#include "tests/check.hpp"
#include "tests/protocol_peer.hpp"
#include <chrono>
#include <csignal>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

using namespace telar;
using Clock = std::chrono::steady_clock;
constexpr unsigned burst_lines = 1024;
constexpr unsigned maximum_read_rows = 2000;
constexpr TerminalSize terminal_size{80, 24, 0, 0};

std::string outputFor(unsigned index, unsigned lines) {
  std::string result;
  for (unsigned line = 0; line < lines; ++line) {
    char prefix[32];
    std::snprintf(prefix, sizeof(prefix), "%02u:%04u:", index, line);
    result += prefix;
    result.append(48, static_cast<char>('a' + line % 26));
    result += '\n';
  }
  result += "END-" + std::to_string(index);
  return result;
}

void writeAll(std::string_view text) {
  while (!text.empty()) {
    const auto count = ::write(STDOUT_FILENO, text.data(), text.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }

    check(count > 0);
    text.remove_prefix(static_cast<std::size_t>(count));
  }
}

int child(int argc, char **argv) {
  check(argc == 6);
  const std::string mode = argv[2];
  const unsigned index = std::stoul(argv[3]);
  const unsigned code = std::stoul(argv[4]);
  const auto deadline = Clock::now() + std::chrono::seconds{10};
  while (mode != "early-exit" && !std::filesystem::exists(argv[5])) {
    check(Clock::now() < deadline);
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }

  if (mode == "forked-writer") {
    ::signal(SIGHUP, SIG_IGN);
    const auto pid = ::fork();
    check(pid >= 0);
    if (pid != 0) {
      int status = 0;
      pid_t waited;
      do {
        waited = ::waitpid(pid, &status, 0);
      } while (waited < 0 && errno == EINTR);
      check(waited == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0);
      return code;
    }

    std::this_thread::sleep_for(std::chrono::milliseconds{30});
  }

  const auto text = outputFor(index, (mode == "immediate" || mode == "early-exit") ? 0 : burst_lines);
  writeAll(text);
  if (mode == "signal") {
    ::signal(SIGTERM, SIG_DFL);
    ::raise(SIGTERM);
    return 99;
  }

  return mode == "forked-writer" ? 0 : code;
}

struct PaneState {
  gui::Screen<gui::SystemAllocator> screen;
  std::uint64_t id = 0;
  std::uint64_t generation = 0;
  std::uint64_t held_ack = 0;
  std::string expected;
  bool text_requested = false;
  bool text_verified = false;
  bool exited = false;
  unsigned code = 0;

  explicit PaneState(gui::SystemAllocator &memory)
      : screen(memory) {}
};

int exercise(int argc, char **argv) {
  check(argc == 6);
  const std::string mode = argv[2];
  const unsigned count = mode == "coalesced" ? 8 : 1;
  const auto release = std::filesystem::path{argv[3]} / "release";
  check(!std::filesystem::exists(release));
  ProtocolPeer peer{argv[1]};
  gui::SystemAllocator memory;
  std::vector<std::unique_ptr<PaneState>> panes;
  std::map<std::uint64_t, PaneState *> by_id;
  std::ofstream canonical{argv[4], std::ios::binary};
  std::uint64_t request_id = 1;
  TabLocation location;
  std::size_t frames = 0;
  auto consumeFrame = [&](const PaneFrame &frame) {
    auto &pane = *by_id.at(frame.pane_id);
    check(!pane.exited);
    check(pane.screen.apply(frame) == gui::FrameApplication::applied);
    ++frames;
    std::string text;
    for (const auto &cell : pane.screen.cells()) {
      text += cell.utf8();
    }

    const auto marker = pane.expected.substr(pane.expected.rfind('\n') == std::string::npos ? 0 : pane.expected.rfind('\n') + 1);
    if (!pane.text_requested && text.find(marker) != std::string::npos) {
      // Hold the last frame's ACK so exit delivery cannot retire the pane before its complete text is read.
      pane.text_requested = true;
      pane.held_ack = frame.frame_id;
      peer.send(ReadPane{.request_id = request_id++, .pane_id = pane.id, .pane_generation = pane.generation, .rows = maximum_read_rows, .source = PaneTextSource::recent});
    } else {
      peer.send(FrameAck{frame.pane_id, frame.frame_id});
    }
  };

  for (unsigned index = 0; index < count; ++index) {
    auto pane = std::make_unique<PaneState>(memory);
    pane->code = mode == "signal" ? SIGTERM : 10 + index;
    pane->expected = outputFor(index, (mode == "immediate" || mode == "early-exit") ? 0 : burst_lines);
    const auto index_text = std::to_string(index);
    const auto code_text = std::to_string(pane->code);
    const auto release_text = release.string();
    const std::array<std::string_view, 6> arguments{argv[5], "--child", mode, index_text, code_text, release_text};
    if (index == 0) {
      peer.send(CreateWorkspace{.request_id = request_id++, .size = terminal_size, .name = "Exit oracle", .launch = Launch{.cwd = argv[3], .arguments = arguments}});
    } else {
      peer.send(CreatePane{.request_id = request_id++, .location = location, .size = terminal_size, .launch = Launch{.cwd = argv[3], .arguments = arguments}});
    }

    for (;;) {
      const auto reply = peer.receiveAny<PaneOpened, PaneFrame>();
      if (const auto *frame = std::get_if<PaneFrame>(&reply)) {
        consumeFrame(*frame);
        continue;
      }

      const auto &opened = std::get<PaneOpened>(reply);
      location = opened.location;
      pane->id = opened.pane_id;
      pane->generation = opened.pane_generation;
      by_id.emplace(pane->id, pane.get());
      break;
    }

    panes.push_back(std::move(pane));
  }

  {
    std::ofstream signal{release};
    signal << "release\n";
  }

  unsigned exited = 0;
  while (exited != count) {
    const auto reply = peer.receiveAny<PaneFrame, PaneExited, PaneText>();
    if (const auto *frame = std::get_if<PaneFrame>(&reply)) {
      consumeFrame(*frame);
    } else if (const auto *text = std::get_if<PaneText>(&reply)) {
      auto &pane = *by_id.at(text->pane_id);
      check(pane.text_requested && !pane.text_verified && pane.held_ack != 0);
      if (text->truncated || text->text != pane.expected) {
        std::ofstream actual{std::filesystem::path{argv[3]} / "actual.txt"};
        actual << text->text;
        std::ofstream expected{std::filesystem::path{argv[3]} / "expected.txt"};
        expected << pane.expected;
        throw std::runtime_error{"Complete PTY text differs"};
      }

      pane.text_verified = true;
      peer.send(FrameAck{pane.id, pane.held_ack});
      pane.held_ack = 0;
    } else {
      const auto &exit = std::get<PaneExited>(reply);
      auto &pane = *by_id.at(exit.pane_id);
      check(!pane.exited && pane.text_verified);
      check(exit.kind == (mode == "signal" ? ExitKind::signaled : ExitKind::exited));
      check(exit.value == pane.code);
      pane.exited = true;
      ++exited;
    }
  }

  for (const auto &pane : panes) {
    canonical << pane->code << ':' << pane->expected.size() << ':' << pane->expected << '\n';
  }

  std::cout << "{\"panes\":" << count << ",\"frames\":" << frames << ",\"complete_text\":true,\"statuses\":true}\n";
  return 0;
}

int main(int argc, char **argv) {
  try {
    return argc > 1 && std::string_view{argv[1]} == "--child" ? child(argc, argv) : exercise(argc, argv);
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
