#include "check.hpp"
#include "protocol_peer.hpp"
#include <algorithm>
#include <chrono>
#include <fcntl.h>
#include <poll.h>
#include <termios.h>
#include <thread>

using namespace telar;
using Clock = std::chrono::steady_clock;

static constexpr std::size_t warmup_samples = 50;
static constexpr std::size_t measured_samples = 500;
static constexpr auto response_timeout = std::chrono::seconds{5};

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

static std::size_t readReplies(char final, std::size_t expected) {
  const auto deadline = Clock::now() + response_timeout;
  std::size_t replies = 0;
  std::array<char, 4096> bytes;
  while (replies != expected) {
    check(Clock::now() < deadline);
    pollfd input{STDIN_FILENO, POLLIN, 0};
    const auto ready = ::poll(&input, 1, 50);
    check(ready >= 0 || errno == EINTR);
    if (ready <= 0) {
      continue;
    }
    const auto count = ::read(STDIN_FILENO, bytes.data(), bytes.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }
    check(count > 0);
    replies += std::count(bytes.begin(), bytes.begin() + count, final);
    check(replies <= expected);
  }
  return replies;
}

struct Workload {
  std::string_view name;
  std::string input;
  std::size_t replies;
  char final;
  bool fragment = false;
};

static void measure(std::ostream &output, const Workload &workload) {
  writeAll("\x1b" "c");
  std::this_thread::sleep_for(std::chrono::milliseconds{10});
  std::array<std::uint64_t, measured_samples> samples;
  for (std::size_t index = 0; index < warmup_samples + measured_samples; ++index) {
    const auto started = Clock::now();
    if (workload.fragment) {
      for (const char &byte : workload.input) {
        writeAll({&byte, 1});
      }
    } else {
      writeAll(workload.input);
    }
    readReplies(workload.final, workload.replies);
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - started).count();
    if (index >= warmup_samples) {
      samples[index - warmup_samples] = static_cast<std::uint64_t>(elapsed);
    }
  }
  output << "\"" << workload.name << "\":{\"input_bytes\":" << workload.input.size()
         << ",\"replies_per_roundtrip\":" << workload.replies << ",\"roundtrip_ns\":[";
  for (std::size_t index = 0; index < samples.size(); ++index) {
    output << (index ? "," : "") << samples[index];
  }
  output << "]}";
}

// Stop reading responses for 100 ms while submitting 5000 DSRs. Both PTY
// directions remain nonblocking; resumption pumps them together to avoid a
// fixture deadlock when the runtime correctly applies read backpressure.
static void saturate(std::ostream &output) {
  constexpr std::size_t queries = 5000;
  std::string requests;
  for (std::size_t index = 0; index < queries; ++index) {
    requests += "\x1b[5n";
  }
  const auto output_flags = ::fcntl(STDOUT_FILENO, F_GETFL);
  const auto input_flags = ::fcntl(STDIN_FILENO, F_GETFL);
  check(output_flags >= 0 && input_flags >= 0);
  check(::fcntl(STDOUT_FILENO, F_SETFL, output_flags | O_NONBLOCK) == 0);
  check(::fcntl(STDIN_FILENO, F_SETFL, input_flags | O_NONBLOCK) == 0);
  const auto started = Clock::now();
  auto last_activity = started;
  std::size_t sent = 0;
  std::size_t replies = 0;
  std::size_t child_write_eagain = 0;
  std::array<char, 4096> bytes;
  while (Clock::now() - started < response_timeout) {
    const auto now = Clock::now();
    if (sent < requests.size()) {
      const auto count = ::write(STDOUT_FILENO, requests.data() + sent, requests.size() - sent);
      if (count > 0) {
        sent += static_cast<std::size_t>(count);
        last_activity = now;
      } else {
        check(count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR));
        child_write_eagain += errno != EINTR;
      }
    }
    if (now - started >= std::chrono::milliseconds{100}) {
      const auto count = ::read(STDIN_FILENO, bytes.data(), bytes.size());
      if (count > 0) {
        replies += std::count(bytes.begin(), bytes.begin() + count, 'n');
        last_activity = now;
      } else {
        check(count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR));
      }
    }
    if (sent == requests.size() && now - last_activity >= std::chrono::milliseconds{300}) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::microseconds{100});
  }
  check(::fcntl(STDOUT_FILENO, F_SETFL, output_flags) == 0);
  check(::fcntl(STDIN_FILENO, F_SETFL, input_flags) == 0);
  check(sent == requests.size());
  writeAll("\x1b[5n");
  readReplies('n', 1);
  output << "\"saturation\":{\"queries\":" << queries << ",\"received\":" << replies
         << ",\"child_write_eagain\":" << child_write_eagain << ",\"recovery_replies\":1}";
}

static int child(const char *report_path) {
  termios settings;
  check(::tcgetattr(STDIN_FILENO, &settings) == 0);
  ::cfmakeraw(&settings);
  check(::tcsetattr(STDIN_FILENO, TCSANOW, &settings) == 0);
  std::ofstream output{report_path, std::ios::binary};
  check(output.good());
  output << "{\"warmup\":" << warmup_samples << ",\"samples\":" << measured_samples << ",\"cases\":{";
  std::string burst;
  for (std::size_t index = 0; index < 32; ++index) {
    burst += "\x1b[5n";
  }
  const std::array workloads{
      Workload{"operating-status", "\x1b[5n", 1, 'n'},
      Workload{"cursor", "\x1b[6n", 1, 'R'},
      Workload{"cursor-byte-writes", "\x1b[6n", 1, 'R', true},
      Workload{"burst-32", burst, 32, 'n'},
      Workload{"mixed", std::string(128, 'x') + "\x1b[6n", 1, 'R'},
      Workload{"unknown-then-status", "\x1b[55555n\x1b[5n", 1, 'n'},
      Workload{"ordinary-then-status", std::string(3584, 'x') + "\x1b[5n", 1, 'n'},
  };
  for (std::size_t index = 0; index < workloads.size(); ++index) {
    output << (index ? "," : "");
    measure(output, workloads[index]);
  }
  output << "},";
  saturate(output);
  output << "}\n";
  output.close();
  check(output.good());
  writeAll("control-pty-measurement-complete");
  for (;;) {
    char byte;
    if (::read(STDIN_FILENO, &byte, 1) <= 0) {
      return 0;
    }
  }
}

int main(int argc, char **argv) {
  if (argc == 3 && std::string_view{argv[1]} == "--latency-child") {
    return child(argv[2]);
  }
  if (argc != 3) {
    return 2;
  }
  try {
    ProtocolPeer peer{argv[1]};
    peer.send(RequestRuntimeState{.client_identity = 102, .interactive = true});
    const std::array<std::string_view, 3> arguments{argv[0], "--latency-child", argv[2]};
    const auto opened = peer.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = {80, 24, 0, 0}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
    const auto deadline = Clock::now() + std::chrono::seconds{30};
    for (;;) {
      check(Clock::now() < deadline);
      const auto text = peer.exchange<PaneText>(ReadPane{.request_id = 2, .pane_id = opened.pane_id, .rows = 24});
      if (text.text.contains("control-pty-measurement-complete")) {
        break;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds{2});
    }
    peer.send(ClosePane{.request_id = 3, .pane_id = opened.pane_id});
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
