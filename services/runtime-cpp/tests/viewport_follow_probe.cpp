#include "../../gui-cpp/terminal/screen.hpp"
#include "tests/check.hpp"
#include "tests/protocol_peer.hpp"
#include <array>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <limits>
#include <string>
#include <termios.h>
#include <thread>
#include <unistd.h>

using namespace telar;
using namespace telar::runtime;

namespace {

enum class Scenario {
  return_live,
  hold_ack,
  retain_history,
  clamp_live,
  reflow
};

constexpr std::uint32_t initial_lines = 100;
constexpr std::uint32_t additional_lines = 25;
constexpr std::size_t reflow_fill = 60;
constexpr std::uint16_t narrow_columns = 41;
constexpr TerminalSize size{.cols = 82, .rows = 21, .cell_width_px = 0, .cell_height_px = 0};

static std::string rowLabel(std::uint32_t index) {
  std::array<char, 32> buffer{};
  const auto length = std::snprintf(buffer.data(), buffer.size(), "row%06u", index);
  check(length == 9);
  return {buffer.data(), static_cast<std::size_t>(length)};
}

static std::string rowText(std::uint32_t index, bool reflow) {
  auto text = rowLabel(index);
  if (reflow) {
    text.append(reflow_fill, 'x');
  }

  return text;
}

static void writeAll(std::string_view bytes) {
  while (!bytes.empty()) {
    const auto count = ::write(STDOUT_FILENO, bytes.data(), bytes.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }

    check(count > 0);
    bytes.remove_prefix(static_cast<std::size_t>(count));
  }
}

static void emit(std::uint32_t first, std::uint32_t count, bool reflow) {
  std::string output;
  for (std::uint32_t index = first; index < first + count; ++index) {
    output += rowText(index, reflow) + "\r\n";
  }

  writeAll(output);
}

static int child(const char *receipt_path, bool reflow) {
  termios settings{};
  check(::tcgetattr(STDIN_FILENO, &settings) == 0);
  ::cfmakeraw(&settings);
  check(::tcsetattr(STDIN_FILENO, TCSANOW, &settings) == 0);
  {
    std::ofstream receipt{receipt_path};
    receipt << "{\"pid\":" << ::getpid() << ",\"initial_lines\":" << initial_lines << ",\"additional_lines\":" << additional_lines << "}\n";
    check(receipt.good());
  }

  emit(0, initial_lines, reflow);

  for (;;) {
    char command{};
    const auto count = ::read(STDIN_FILENO, &command, 1);
    if (count < 0 && errno == EINTR) {
      continue;
    }

    check(count == 1);
    if (command == 'q') {
      return 0;
    }

    check(command == 'a');
    emit(initial_lines, additional_lines, reflow);
  }
}

struct Observation {
  std::uint32_t total;
  std::uint32_t offset;
  std::uint32_t bottom;
  std::uint64_t frame;
  std::string top;
};

class View {
public:
  explicit View(const char *socket)
      : peer(socket, false),
        screen(memory) {}

  void apply(const PaneFrame &frame) {
    check(frame.pane_id == pane);
    check(screen.apply(frame) == telar::gui::FrameApplication::applied);
    latest_frame = frame.frame_id;

    if (acknowledge) {
      peer.send(FrameAck{pane, latest_frame});
    }
  }

  Observation observation() const {
    check(screen.columns() == expected_columns && screen.rows() == size.rows);
    const auto total = screen.scroll().total_rows;
    check(total >= screen.rows());
    check(screen.scroll().offset <= total - screen.rows());

    for (std::uint32_t row = 0; row < screen.rows(); ++row) {
      const auto absolute = screen.scroll().offset + row;
      const auto rows_per_line = reflow && expected_columns == narrow_columns ? 2U : 1U;
      const auto expected = absolute == total - 1 ? std::string{} : rowText(absolute / rows_per_line, reflow).substr((absolute % rows_per_line) * expected_columns, expected_columns);

      for (std::uint32_t column = 0; column < screen.columns(); ++column) {
        const auto &cell = screen.cells()[row * screen.columns() + column];
        const auto character = column < expected.size() ? expected[column] : ' ';
        check(cell.width == CellWidth::single && cell.utf8() == std::string_view{&character, 1});
      }
    }

    std::string top;
    for (std::uint32_t column = 0; column < rowLabel(0).size(); ++column) {
      top += screen.cells()[column].utf8();
    }

    return {total, screen.scroll().offset, total - screen.rows(), latest_frame, top};
  }

  Observation until(std::uint32_t total, std::optional<std::uint32_t> wanted = std::nullopt) {
    for (;;) {
      apply(peer.receive<PaneFrame>());

      if (screen.scroll().total_rows == total && (!wanted || screen.scroll().offset == *wanted)) {
        return observation();
      }
    }
  }

  // ReadPane is an output barrier while frame acknowledgements are withheld.
  // Independent snapshots may replace the outstanding frame; apply them too.
  void awaitOutput(std::uint64_t generation) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};

    for (;;) {
      check(std::chrono::steady_clock::now() < deadline);
      peer.send(ReadPane{.request_id = 3, .pane_id = pane, .pane_generation = generation, .rows = size.rows});

      for (;;) {
        const auto reply = peer.receiveAny<PaneText, PaneFrame>();

        if (const auto *frame = std::get_if<PaneFrame>(&reply)) {
          check(frame->base_frame_id == 0);
          apply(*frame);

          if (screen.scroll().total_rows == initial_lines + 1 || screen.scroll().total_rows == initial_lines + additional_lines + 1) {
            observation();
          }

          ++frames_while_held;
          continue;
        }

        const auto &text = std::get<PaneText>(reply);
        check(text.request_id == 3 && text.pane_id == pane);

        if (text.text.contains(rowLabel(initial_lines + additional_lines - 1))) {
          return;
        }

        break;
      }

      std::this_thread::sleep_for(std::chrono::milliseconds{1});
    }
  }

  void finish() {
    const std::array<Byte, 1> quit{'q'};
    peer.send(PaneInput{pane, quit});
    for (;;) {
      const auto reply = peer.receiveAny<PaneExited, PaneFrame>();

      if (const auto *frame = std::get_if<PaneFrame>(&reply)) {
        apply(*frame);
        continue;
      }

      const auto &exited = std::get<PaneExited>(reply);
      check(exited.pane_id == pane && exited.value == 0);
      break;
    }

    peer.send(ClosePane{.request_id = 2, .pane_id = pane});
  }

  ProtocolPeer peer;
  SystemAllocator memory;
  telar::gui::Screen<SystemAllocator> screen;
  std::uint64_t pane = 0;
  bool acknowledge = true;
  bool reflow = false;
  std::uint16_t expected_columns = size.cols;
  std::uint64_t latest_frame = 0;
  std::uint32_t frames_while_held = 0;
};

static void record(const char *name, const Observation &value, bool comma) {
  std::printf("%s\"%s\":{\"total\":%u,\"offset\":%u,\"bottom\":%u,\"frame\":%llu,\"top\":\"%s\"}", comma ? "," : "", name, value.total, value.offset, value.bottom, static_cast<unsigned long long>(value.frame), value.top.c_str());
}

} // namespace

int main(int argc, char **argv) {
  if (argc == 3 && (std::string_view{argv[1]} == "--child" || std::string_view{argv[1]} == "--reflow-child")) {
    return child(argv[2], std::string_view{argv[1]} == "--reflow-child");
  }
  if (argc != 4) {
    return 2;
  }

  const std::string_view mode{argv[3]};
  Scenario scenario;

  if (mode == "return") {
    scenario = Scenario::return_live;
  } else if (mode == "held") {
    scenario = Scenario::hold_ack;
  } else if (mode == "history") {
    scenario = Scenario::retain_history;
  } else if (mode == "clamp") {
    scenario = Scenario::clamp_live;
  } else if (mode == "reflow") {
    scenario = Scenario::reflow;
  } else {
    return 2;
  }

  try {
    View view{argv[1]};
    view.reflow = scenario == Scenario::reflow;
    view.peer.send(RequestRuntimeState{.client_identity = 103, .interactive = true});
    const std::array<std::string_view, 3> arguments{argv[0], view.reflow ? "--reflow-child" : "--child", argv[2]};
    const auto opened = view.peer.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
    view.pane = opened.pane_id;
    const auto initial = view.until(initial_lines + 1);
    check(initial.offset == initial.bottom);
    const auto historical_offset = initial.bottom - size.rows;
    view.acknowledge = scenario != Scenario::hold_ack;
    view.peer.send(SetPaneViewport{view.pane, historical_offset});
    const auto historical = view.until(initial_lines + 1, historical_offset);

    if (scenario == Scenario::reflow) {
      view.expected_columns = narrow_columns;
      view.peer.send(PaneResize{view.pane, {.cols = narrow_columns, .rows = size.rows}});
      const auto narrow = view.until(initial_lines * 2 + 1);
      view.expected_columns = size.cols;
      view.peer.send(PaneResize{view.pane, size});
      const auto restored = view.until(initial_lines + 1);
      const bool anchored = narrow.offset == historical.offset * 2 && restored.offset == historical.offset;
      view.finish();
      std::printf("{\"mode\":\"reflow\",\"matches_expected\":%s,", anchored ? "true" : "false");
      record("initial", initial, false);
      record("historical", historical, true);
      record("narrow", narrow, true);
      record("restored", restored, true);
      std::printf(",\"cells_verified\":true,\"child_exited\":true}\n");
      return 0;
    }

    if (scenario != Scenario::retain_history) {
      const auto target = scenario == Scenario::clamp_live ? std::numeric_limits<std::uint32_t>::max() : initial.bottom;
      view.peer.send(SetPaneViewport{view.pane, target});
    }

    const auto returned = scenario == Scenario::hold_ack || scenario == Scenario::retain_history ? historical : view.until(initial_lines + 1, initial.bottom);
    const std::array<Byte, 1> append{'a'};
    view.peer.send(PaneInput{view.pane, append});

    if (scenario == Scenario::hold_ack) {
      view.awaitOutput(opened.pane_generation);
      view.acknowledge = true;
      view.peer.send(FrameAck{view.pane, view.latest_frame});
    }

    const auto grown = view.screen.scroll().total_rows == initial_lines + additional_lines + 1 ? view.observation() : view.until(initial_lines + additional_lines + 1);
    const bool matches_expected = scenario == Scenario::retain_history ? grown.offset == historical.offset : grown.offset == grown.bottom;
    view.finish();
    std::printf("{\"mode\":\"%s\",\"matches_expected\":%s,\"frames_while_held\":%u,", argv[3], matches_expected ? "true" : "false", view.frames_while_held);
    record("initial", initial, false);
    record("historical", historical, true);
    record("before_output", returned, true);
    record("grown", grown, true);
    std::printf(",\"follows_live\":%s,\"cells_verified\":true,\"child_exited\":true}\n", grown.offset == grown.bottom ? "true" : "false");
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "viewport-follow: %s\n", error.what());
    return 1;
  }
}
