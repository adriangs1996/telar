#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>
#include "cell_layout.hpp"
#include <cstdio>
#include <termios.h>
#include <ghostty/vt.h>

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.runtime.terminal.control;
import telar.client;
import telar.runtime.terminal.text_reader;

using namespace telar;
using namespace telar::runtime;

static void writeAll(int descriptor, std::string_view bytes) {
  while (!bytes.empty()) {
    const auto count = ::write(descriptor, bytes.data(), bytes.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }

    if (count <= 0) {
      throw SocketError{"Probe write failed"};
    }

    bytes.remove_prefix(static_cast<std::size_t>(count));
  }
}

static std::string marker(unsigned sequence) {
  std::array<char, 32> buffer{};
  std::snprintf(buffer.data(), buffer.size(), "::%06u::", sequence);
  return buffer.data();
}

static std::string fixture(std::string_view workload, unsigned sequence) {
  std::string output = "\x1b[?2026h";

  if (workload == "sparse") {
    output += "\x1b[12;20H" + std::string(20, 'A' + sequence % 26);
  } else if (workload == "full") {
    output += "\x1b[H";
    for (unsigned row = 0; row < 24; ++row) {
      output += "\x1b[" + std::to_string(row + 1) + ";1H";
      output += "\x1b[38;5;" + std::to_string((sequence + row) % 256) + "m";
      output += std::string(79, 'A' + (sequence + row) % 26);
    }
  } else if (workload == "bulk") {
    for (unsigned row = 0; row < 4096; ++row) {
      output += std::string(78, 'A' + (sequence + row) % 26) + "\r\n";
    }
  } else if (workload == "scroll") {
    for (unsigned row = 0; row < 40; ++row) {
      output += "log line " + std::to_string(sequence * 40 + row) + "\r\n";
    }
  } else if (workload == "graphemes") {
    output += "\x1b[3;1He";
    for (unsigned index = 0; index < 5000; ++index) {
      output += "́";
    }
  } else if (workload == "unicode") {
    output += "\x1b[3;1H\x1b[1;3;4:3;38;2;41;55;200m";
    output += "café é 界 🙂 👩‍💻\x1b[0m\x1b[5;1H";
    output += std::string(20, 'A' + sequence % 26);
  } else if (workload == "modes") {
    output += sequence % 2 == 0 ? "\x1b[?1;1004;1006;2004h\x1b[6 q" : "\x1b[?1;1004;1006;2004l\x1b[2 q";
  } else if (workload == "links") {
    output += "\x1b[4;1H\x1b]8;;https://example.test/" + std::to_string(sequence) + "\x1b\\link\x1b]8;;\x1b\\";
  } else if (workload == "mixed") {
    static constexpr std::array<std::string_view, 8> operations{
        "\x1b[?1049h\x1b[2J\x1b[4;1Halternate screen",
        "\x1b[?1049l\x1b[2;79H界界\x1b[3;79Habc界",
        "\x1b[5;1H\x1b[41mbackground\x1b[K\x1b[0m",
        "\x1b[4;1H\x1b[2L\x1b[2Pinsert/delete",
        "\x1b[?5h\x1b[?25l",
        "\x1b[?5l\x1b[?25h\x1b[>4;2m\x1b]22;pointer\x1b\\",
        "\x1b[>4;0m\x1b]22;text\x1b\\\x1b[0 q",
        "\x1b[?1049h\x1b[?1049l\x1b[2J",
    };
    output += operations[sequence % operations.size()];
  } else if (workload == "graphics-cursor") {
    static constexpr std::array<std::string_view, 8> operations{
        "\x1b[4;3H\x1b_Ga=T,s=32,v=64,i=1,q=2;bad\x1b\\after-image",
        "\x1b[4;3H\x1b_Ga=p,i=1,c=3,q=2;\x1b\\after-put",
        "\x1b[6;3H\x1b_Ga=T,c=4,r=3,q=2,m=1;\x1b\\\x1b_Gm=0;\x1b\\after-chunks",
        "\x1b[4;3H\x1b_Ga=p,i=99,c=3,r=3,q=2;\x1b\\missing-image",
        "\x1b[4;3H\x1b_Ga=T,f=100,q=2;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\x1b\\after-png",
        "\x1b[4;9r\x1b[9;79H\x1b_Ga=T,c=3,r=2,q=2;bad\x1b\\wrapped\x1b[r",
        "\x1b[4;3H\x1b_Ga=d,d=I,i=1,q=2;\x1b\\\x1b_Ga=p,i=1,q=2;\x1b\\deleted-image",
        "\x1b[4;3H\x1b_Ga=T,c=7,r=5,C=1,q=2;bad\x1b\\cursor-stays",
    };
    output += operations[sequence % operations.size()];
  } else if (workload == "colors") {
    output += "\x1b]10;#123456\x1b\\\x1b]11;#654321\x1b\\\x1b]4;1;#112233\x1b\\";
    output += "\x1b[3;1Hdefault \x1b[31mindexed\x1b[0m";
  } else {
    throw SocketError{"Unknown probe workload"};
  }

  output += "\x1b[0m\x1b[1;1H" + marker(sequence) + "\x1b[?2026l";
  return output;
}

static int child(std::string_view workload) {
  termios settings{};
  if (::tcgetattr(STDIN_FILENO, &settings) != 0) {
    return 2;
  }

  ::cfmakeraw(&settings);
  if (::tcsetattr(STDIN_FILENO, TCSANOW, &settings) != 0) {
    return 2;
  }

  writeAll(STDOUT_FILENO, fixture(workload, 0));
  unsigned sequence = 0;
  char command = 0;
  while (::read(STDIN_FILENO, &command, 1) == 1) {
    if (command == 'q') {
      writeAll(STDOUT_FILENO, "\x1b[2;1Hfinal-output-before-exit");
      return 23;
    }

    if (command == 'n') {
      writeAll(STDOUT_FILENO, fixture(workload, ++sequence));
    }
  }

  return 0;
}

class Probe {
public:
  explicit Probe(const char *socket_path)
      : socket_path_(socket_path),
        client_(Client::init(socket_path)),
        incoming_(max_payload_size),
        outgoing_(max_payload_size),
        scratch_(512 * 1024) {
    client_.handshake();
    const timeval timeout{.tv_sec = 5,
                          .tv_usec = 0};
    ::setsockopt(client_.descriptor(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    client_.send(ConfigureFrameInterval{.interval_ns = 1'000'000'000 / 240});
  }

  ~Probe() {
    client_.deinit();
  }

  void open(const char *executable, std::string_view workload, bool fresh_workspace = false) {
    const std::array<std::string_view, 3> arguments{executable, "--child", workload};
    const TerminalSize size{80, 24, 8, 16};
    const Launch launch{.cwd = "/tmp", .arguments = arguments};
    if (fresh_workspace) {
      send(CreateWorkspace{.request_id = 1, .size = size, .name = "Probe", .launch = launch});
    } else {
      send(OpenPane{.request_id = 1, .size = size, .launch = launch});
    }

    while (pane_id_ == 0) {
      receive();
    }

    waitForMarker(0);
  }

  void next(unsigned sequence) {
    const std::array<Byte, 1> input{'n'};
    send(PaneInput{.pane_id = pane_id_,
                   .bytes = input});
    waitForMarker(sequence);
  }

  void resize(std::uint16_t columns, std::uint16_t rows) {
    send(PaneResize{.pane_id = pane_id_,
                    .size = {.cols = columns,
                             .rows = rows,
                             .cell_width_px = 8,
                             .cell_height_px = 16}});
    while (header_.cols != columns || header_.rows != rows) {
      receive();
    }
  }

  void reconnect(unsigned sequence) {
    client_.deinit();
    client_ = Client::init(socket_path_.c_str());
    client_.handshake();
    const timeval timeout{.tv_sec = 5,
                          .tv_usec = 0};
    ::setsockopt(client_.descriptor(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    send(OpenPane{.request_id = 9,
                  .target = {.kind = PaneTarget::Kind::pane,
                             .id = pane_id_},
                  .size = {.cols = 80,
                           .rows = 24,
                           .cell_width_px = 8,
                           .cell_height_px = 16}});
    cells_.clear();
    header_ = {};
    waitForMarker(sequence);
  }

  void dumpMatches(std::ostream &output) {
    for (const auto needle : {"log", "café", "LINK", "AAA"}) {
      matches_received_ = false;
      send(SearchPane{.request_id = 4,
                      .pane_id = pane_id_,
                      .needle = needle});
      while (!matches_received_) {
        receive();
      }
      output.write(reinterpret_cast<const char *>(matches_.data()), matches_.size());
    }
  }

  void dumpText(std::ostream &output) {
    for (auto source : {PaneTextSource::screen, PaneTextSource::recent}) {
      text_received_ = false;
      send(ReadPane{.request_id = 2,
                    .pane_id = pane_id_,
                    .pane_generation = pane_generation_,
                    .rows = 100,
                    .source = source});
      while (!text_received_) {
        receive();
      }

      const auto size = static_cast<std::uint32_t>(text_.size());
      output.write(reinterpret_cast<const char *>(&size), sizeof(size));
      output.write(text_.data(), text_.size());
    }

    text_received_ = false;
    send(CopySelection{.pane_id = pane_id_,
                       .start_x = 2,
                       .start_y = 0,
                       .end_x = 10,
                       .end_y = 2});
    while (!text_received_) {
      receive();
    }

    const auto size = static_cast<std::uint32_t>(text_.size());
    output.write(reinterpret_cast<const char *>(&size), sizeof(size));
    output.write(text_.data(), text_.size());
  }

  void finish() {
    const std::array<Byte, 1> input{'q'};
    send(PaneInput{.pane_id = pane_id_,
                   .bytes = input});
    while (!exited_) {
      receive();
    }

    const std::string_view expected = "final-output-before-exit";
    for (std::size_t index = 0; index < expected.size(); ++index) {
      if (cells_.at(80 + index).text[0] != expected[index]) {
        throw SocketError{"Exit arrived before final terminal output"};
      }
    }
  }

  void dump(std::ostream &output) {
    auto remaining = std::span<Byte>{outgoing_};
    auto header = header_;
    header.pane_id = 1;
    header.frame_id = 2;
    header.base_frame_id = 1;
    FrameSerializer::encodeBody(header, remaining);

    for (const auto &cell : cells_) {
      u8::encode(cell.length, remaining);
      u8::encode(static_cast<Byte>(cell.width), remaining);
      ValueCodec<CellStyle>::encode(cell.style, remaining);
      std::copy_n(cell.text.data(), cell.length, remaining.data());
      remaining = remaining.subspan(cell.length);
    }

    output.write(reinterpret_cast<const char *>(outgoing_.data()), outgoing_.size() - remaining.size());
    output.write(reinterpret_cast<const char *>(metadata_.data()), metadata_.size());
  }

private:
  template <typename Message>
  void send(const Message &message) {
    client_.send(message, outgoing_);
  }

  void waitForMarker(unsigned sequence) {
    const auto expected = marker(sequence);
    const auto matches = [&] {
      if (cells_.size() < expected.size()) {
        return false;
      }

      for (std::size_t index = 0; index < expected.size(); ++index) {
        if (cells_[index].length != 1 || cells_[index].text[0] != expected[index]) {
          return false;
        }
      }

      return true;
    };

    while (!matches()) {
      receive();
    }
  }

  void receive() {
    const auto payload = client_.receiveFrame(incoming_);
    DecodeStorage storage{scratch_};
    switch (static_cast<ServerTag>(payload.front())) {
    case ServerTag::pane_opened: {
      const auto opened = Codec::decode<PaneOpened>(payload, storage);
      pane_id_ = opened.pane_id;
      pane_generation_ = opened.pane_generation;
      break;
    }
    case ServerTag::pane_matches: {
      auto matches = Codec::decode<PaneMatches>(payload, storage);
      matches.pane_id = 1;
      const auto encoded = Codec::encode(matches, outgoing_);
      matches_.assign(encoded.begin(), encoded.end());
      matches_received_ = true;
      break;
    }
    case ServerTag::pane_text: {
      const auto text = Codec::decode<PaneText>(payload, storage);
      text_.assign(text.text);
      text_received_ = true;
      break;
    }
    case ServerTag::pane_clipboard: {
      const auto clipboard = Codec::decode<PaneClipboard>(payload, storage);
      text_.assign(reinterpret_cast<const char *>(clipboard.bytes.data()), clipboard.bytes.size());
      text_received_ = true;
      break;
    }
    case ServerTag::pane_frame:
      apply(Codec::decode<PaneFrame>(payload, storage));
      break;
    case ServerTag::pane_exited: {
      const auto exit = Codec::decode<PaneExited>(payload, storage);
      if (exit.kind != ExitKind::exited || exit.value != 23) {
        throw SocketError{"Unexpected child exit status"};
      }

      exited_ = true;
      break;
    }
    case ServerTag::request_failed: {
      const auto failure = Codec::decode<RequestFailed>(payload, storage);
      std::fprintf(stderr, "Request failed: %.*s\n", static_cast<int>(failure.message.size()), failure.message.data());
      throw SocketError{"Probe request rejected"};
    }
    default:
      break;
    }
  }

  void apply(const PaneFrame &frame) {
    if (frame.base_frame_id != 0 && frame.base_frame_id != header_.frame_id) {
      throw SocketError{"Frame refers to an unacknowledged baseline"};
    }

    cells_.resize(static_cast<std::size_t>(frame.cols) * frame.rows);
    for (const auto &span : frame.spans) {
      auto reader = span.reader();
      for (std::size_t offset = 0; offset < span.count; ++offset) {
        const auto cell = *reader.next();
        auto &destination = cells_.at(span.start + offset);
        destination = {};
        destination.length = static_cast<Byte>(cell.text.size());
        destination.width = cell.width;
        destination.style = cell.style;
        std::copy(cell.text.begin(), cell.text.end(), destination.text.begin());
      }
    }

    if (frame.text_metadata) {
      auto remaining = std::span<Byte>{outgoing_};
      ValueCodec<TextMetadata>::encode(*frame.text_metadata, remaining);
      metadata_.assign(outgoing_.begin(), outgoing_.begin() + (outgoing_.size() - remaining.size()));
    }

    header_ = frame;
    header_.spans = {};
    header_.text_metadata.reset();
    client_.send(FrameAck{.pane_id = frame.pane_id,
                          .frame_id = frame.frame_id});
  }

  std::string socket_path_;
  Client client_;
  std::vector<Byte> incoming_;
  std::vector<Byte> outgoing_;
  std::vector<Byte> scratch_;
  std::vector<Byte> metadata_;
  std::vector<ScreenCell> cells_;
  FrameBody header_{};
  std::uint64_t pane_id_ = 0;
  bool exited_ = false;
  std::uint64_t pane_generation_ = 0;
  std::string text_;
  bool text_received_ = false;
  bool matches_received_ = false;
  std::vector<Byte> matches_;
};

static void measureConcurrent(Probe &foreground, char **arguments, unsigned iterations) {
  std::atomic<bool> ready{false};
  std::exception_ptr failure;
  unsigned background_iterations = 0;
  std::jthread background{[&](std::stop_token stopping) {
    try {
      Probe probe{arguments[1]};
      probe.open(arguments[0], "bulk", true);
      probe.next(++background_iterations);
      ready.store(true, std::memory_order_release);
      while (!stopping.stop_requested()) {
        probe.next(++background_iterations);
      }
    } catch (...) {
      failure = std::current_exception();
      ready.store(true, std::memory_order_release);
    }
  }};

  while (!ready.load(std::memory_order_acquire)) {
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }

  std::vector<std::int64_t> latencies;
  latencies.reserve(iterations);
  const auto started = std::chrono::steady_clock::now();
  for (unsigned sequence = 1; sequence <= iterations; ++sequence) {
    const auto sent = std::chrono::steady_clock::now();
    foreground.next(sequence);
    latencies.push_back(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - sent).count());
  }
  const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
  background.request_stop();
  background.join();
  if (failure) {
    std::rethrow_exception(failure);
  }

  std::sort(latencies.begin(), latencies.end());
  std::ofstream dump{arguments[4], std::ios::binary};
  foreground.dump(dump);
  foreground.dumpText(dump);
  foreground.finish();
  std::printf("{\"iterations\":%u,\"background_iterations\":%u,\"elapsed_ns\":%lld,\"ns_per_iteration\":%.3f,\"p50_ns\":%lld,\"p95_ns\":%lld,\"p99_ns\":%lld,\"max_ns\":%lld}\n", iterations, background_iterations, static_cast<long long>(elapsed), static_cast<double>(elapsed) / iterations, static_cast<long long>(latencies[(iterations - 1) * 50 / 100]), static_cast<long long>(latencies[(iterations - 1) * 95 / 100]), static_cast<long long>(latencies[(iterations - 1) * 99 / 100]), static_cast<long long>(latencies.back()));
}

int main(int argc, char **argv) {
  try {
    if (argc == 3 && std::string_view{argv[1]} == "--child") {
      return child(argv[2]);
    }

    if (argc != 5) {
      std::fprintf(stderr, "usage: runtime-probe SOCKET WORKLOAD ITERATIONS DUMP\n");
      return 2;
    }

    const unsigned iterations = static_cast<unsigned>(std::stoul(argv[3]));
    Probe probe{argv[1]};
    const bool concurrent = std::string_view{argv[2]} == "concurrent";
    probe.open(argv[0], concurrent ? "sparse" : argv[2]);
    if (concurrent) {
      measureConcurrent(probe, argv, iterations);
      return 0;
    }
    std::ofstream dump{argv[4], std::ios::binary};
    probe.dump(dump);
    const auto begin = std::chrono::steady_clock::now();

    for (unsigned sequence = 1; sequence <= iterations; ++sequence) {
      probe.next(sequence);
    }

    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - begin).count();
    probe.dump(dump);
    probe.dumpText(dump);
    probe.dumpMatches(dump);
    probe.resize(100, 30);
    probe.dump(dump);
    probe.resize(80, 24);
    probe.reconnect(iterations);
    probe.next(iterations + 1);
    probe.dump(dump);
    probe.finish();
    std::printf("{\"iterations\":%u,\"elapsed_ns\":%lld,\"ns_per_iteration\":%.3f}\n", iterations, static_cast<long long>(elapsed), static_cast<double>(elapsed) / iterations);
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "runtime-probe: %s\n", error.what());
    return 1;
  }
}
