module;
#include <cstdint>
#include <cstdio>

#include "telar_platform/process_environment.h"

#include <cstddef>
#include <cctype>
#include <cerrno>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#if (defined(__APPLE__))
#include <mach-o/dyld.h>
#include <sys/attr.h>
#endif

module telar.gui.platform.profile_file;

import std;

import telar.gui.platform.login_shell;
import telar.client;
import telar.platform;


#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif


namespace telar::gui::platform {
namespace {
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;
// A slow login shell, plus telar's own wait for a runtime it has to start.
constexpr auto answer_timeout = 30s;
// The socket path and the schema, one per line.
constexpr std::size_t answer_limit = PATH_MAX + 1 + std::tuple_size_v<telar::SchemaId> + 1;
// What a failure keeps of telar's standard error.
constexpr std::size_t error_limit = 4096;

struct Answer {
  std::string output;
  std::string errors;
  int status = 0;
  bool timed_out = false;
};

// The telar in the application bundle that holds this executable, or installed beside it;
// otherwise the one the login shell finds on PATH, as a terminal would.
std::string telarProgram() {
  const auto found = telar::runtime::ExecutablePath::sibling({"../Resources/bin/telar", "telar"});
  return found ? std::string{found->view()} : std::string{"telar"};
}

void keep(std::string &buffer, std::span<const telar::Byte> bytes, std::size_t limit) {
  const auto kept = std::min(bytes.size(), limit - buffer.size());
  buffer.append(reinterpret_cast<const char *>(bytes.data()), kept);
}

// Reads both streams until telar closes them, then waits for it to exit, all within one
// deadline; a telar still running at the deadline is killed with its process group. Only the
// standard streams reach telar, never another descriptor of this process.
Answer ask(const std::vector<std::string> &arguments) {
  telar::SystemAllocator memory;
  const std::vector<std::string_view> words(arguments.begin(), arguments.end());
  telar::runtime::Command command{memory, telar::Launch{.arguments = words}, telar::runtime::CommandPurpose::configured_helper};
  telar::runtime::CommandOutput<telar::SystemAllocator> process{memory, 0};
  Answer answer;
  try {
    // One byte past the answer's limit tells an oversized answer from one that fits.
    answer.status = process.streamDiagnostics(
        command, Clock::now() + answer_timeout,
        [&](std::span<const telar::Byte> bytes) {
          keep(answer.output, bytes, answer_limit + 1);
          return true;
        },
        [&](std::span<const telar::Byte> bytes) { keep(answer.errors, bytes, error_limit); });
  } catch (const telar::runtime::RequestError &) {
    answer.timed_out = true;
  }

  return answer;
}

std::string_view trimmed(std::string_view text) {
  const auto end = text.find_last_not_of(" \t\r\n");
  return end == std::string_view::npos ? std::string_view{} : text.substr(0, end + 1);
}

// Exactly the socket path and the schema, each ending its line. Anything else, such as what a
// shell startup file prints, is refused rather than guessed around.
std::string parse(std::string_view answer) {
  const auto unreadable =
      std::runtime_error("telar answered with something other than the runtime endpoint");
  const auto end = answer.find('\n');

  if (end == std::string_view::npos) {
    throw unreadable;
  }

  const auto path = answer.substr(0, end);
  const auto schema = answer.substr(end + 1);
  const auto &expected = telar::handshake::schema_id;

  if (path.empty() || path.front() != '/' || path.size() >= sizeof(sockaddr_un::sun_path) ||
      std::ranges::any_of(path, [](unsigned char byte) {
        return byte < 0x20 || byte == 0x7f;
      })) {
    throw unreadable;
  }

  if (schema.size() != expected.size() + 1 || schema.back() != '\n' ||
      std::ranges::any_of(schema.substr(0, expected.size()), [](unsigned char byte) {
        return !std::isalnum(byte);
      })) {
    throw unreadable;
  }

  if (!std::ranges::equal(schema.substr(0, expected.size()), expected, {}, [](char byte) {
        return static_cast<telar::Byte>(byte);
      })) {
    throw std::runtime_error(
        "telar speaks wire schema " + std::string(schema.substr(0, expected.size())) +
        "; the GUI speaks " + std::string(expected.begin(), expected.end()) +
        ". Update one of them");
  }

  return std::string(path);
}
}

namespace runtime_endpoint {
std::string program() {
  return telarProgram();
}

std::string resolve() {
  const auto shell = login_shell::path();
  const auto program = telarProgram();
  std::vector<std::string> arguments;

  if (const char *line = login_shell::script(shell)) {
    arguments = {shell, "-l", "-c", line, program, "server", "endpoint"};
  } else {
    arguments = {program, "server", "endpoint"};
  }

  const auto answer = ask(arguments);

  if (answer.timed_out) {
    throw std::runtime_error("telar did not report the runtime endpoint in time");
  }

  if (answer.status != 0) {
    throw std::runtime_error("`telar server endpoint` failed: " +
                             std::string(trimmed(answer.errors)));
  }

  return parse(answer.output);
}
}
}
