module telar.gui.foundation.system;

import std;

import telar.sys.posix;
import telar.sys.socket;
import telar.client;
import telar.vocabulary;
import telar.platform.process;
import telar.base.memory.allocators;
import telar.base.ds;
import telar.gui.foundation.core;

namespace telar::gui::inline foundation::inline system {
  namespace {
    using Clock = std::chrono::steady_clock;
    using namespace std::chrono_literals;
    // A slow login shell, plus telar's own wait for a runtime it has to start.
    constexpr auto answer_timeout = 30s;
    // The socket path and the schema, one per line.
    constexpr std::size_t answer_limit = PATH_MAX + 1 + std::tuple_size_v<telar::SchemaId> + 1;
    // What a failure keeps of telar's standard error.
    constexpr std::size_t error_limit = 4096;

    using Text = ds::String<telar::SystemAllocator>;

    struct Answer {
      Text output;
      Text errors;
      int status = 0;
      bool timed_out = false;
    };

    // The telar in the application bundle that holds this executable, or installed beside it;
    // otherwise the one the login shell finds on PATH, as a terminal would.
    runtime_endpoint::Path telarProgram() {
      const auto found = telar::runtime::ExecutablePath::sibling({"../Resources/bin/telar", "telar"});
      runtime_endpoint::Path program;

      program.assign(found ? found->view() : std::string_view{"telar"});
      return program;
    }

    void keep(Text& buffer, std::span<const telar::Byte> bytes, std::size_t limit) {
      const auto kept = std::min(bytes.size(), limit - buffer.size());

      buffer.append(telar::textView(bytes.first(kept)));
    }

    // Reads both streams until telar closes them, then waits for it to exit, all within one
    // deadline; a telar still running at the deadline is killed with its process group. Only the
    // standard streams reach telar, never another descriptor of this process.
    tbc::view<Answer, tbc::lt::a> ask(tbc::view<telar::SystemAllocator&, tbc::lt::a> memory, std::span<const std::string_view> words) {
      telar::runtime::Command command{memory, telar::Launch{.arguments = words}, telar::runtime::CommandPurpose::configured_helper};
      telar::runtime::CommandOutput<telar::SystemAllocator> process{memory, 0};
      Answer answer{.output = Text{memory}, .errors = Text{memory}};

      try {
        // One byte past the answer's limit tells an oversized answer from one that fits.
        answer.status = process.streamDiagnostics(
            command,
            Clock::now() + answer_timeout,
            [&](std::span<const telar::Byte> bytes) {
              keep(answer.output, bytes, answer_limit + 1);
              return true;
            },
            [&](std::span<const telar::Byte> bytes) {
              keep(answer.errors, bytes, error_limit);
            }
        );
      } catch (const telar::runtime::RequestError&) {
        answer.timed_out = true;
      }

      return answer;
    }

    std::string_view trimmed(std::string_view text) {
      const auto end = text.find_last_not_of(" \t\r\n");

      return end == std::string_view::npos ? std::string_view{} : text.substr(0, end + 1);
    }

    runtime_endpoint::Failure unreadable() noexcept {
      return runtime_endpoint::Failure{"telar answered with something other than the runtime endpoint"};
    }

    // Exactly the socket path and the schema, each ending its line. Anything else, such as what a
    // shell startup file prints, is refused rather than guessed around.
    runtime_endpoint::Path parse(std::string_view answer) {
      const auto end = answer.find('\n');

      if (end == std::string_view::npos) {
        throw unreadable();
      }

      const auto path = answer.substr(0, end);
      const auto schema = answer.substr(end + 1);
      const auto& expected = telar::handshake::schema_id;

      if (path.empty() || path.front() != '/' || path.size() >= sizeof(sockaddr_un::sun_path) ||
          std::ranges::any_of(path, [](unsigned char byte) {
            constexpr unsigned char first_printable = 0x20;
            constexpr unsigned char delete_character = 0x7f;

            return byte < first_printable || byte == delete_character;
          })) {
        throw unreadable();
      }

      if (schema.size() != expected.size() + 1 || schema.back() != '\n' ||
          std::ranges::any_of(schema.substr(0, expected.size()), [](unsigned char byte) {
            return !std::isalnum(byte);
          })) {
        throw unreadable();
      }

      if (!std::ranges::equal(schema.substr(0, expected.size()), expected, {}, [](char byte) {
            return static_cast<telar::Byte>(byte);
          })) {
        throw runtime_endpoint::Failure{"telar speaks wire schema ", schema.substr(0, expected.size()), "; the GUI speaks ", telar::textView(expected), ". Update one of them"};
      }

      runtime_endpoint::Path endpoint;

      endpoint.assign(path);
      return endpoint;
    }
  }

  namespace runtime_endpoint {
    const char* Failure::what() const noexcept {
      return message_.c_str();
    }

    Path program() {
      return telarProgram();
    }

    Path resolve() {
      telar::SystemAllocator memory;
      const auto login = telar::runtime::loginShell();
      const auto shell = login.view();
      const auto program = telarProgram();
      const auto line = telar::runtime::loginShellScript(shell);
      const ds::Array<std::string_view, 7> through_shell{shell, "-l", "-c", line, program.view(), "server", "endpoint"};
      // Without a login shell to go through, telar's own words: the last three.
      const auto arguments = line.empty() ? through_shell.view().last(3) : through_shell.view();
      const auto answer = ask(memory, arguments);

      if (answer.timed_out) {
        throw Failure{"telar did not report the runtime endpoint in time"};
      }

      if (answer.status != 0) {
        throw Failure{"`telar server endpoint` failed: ", trimmed(answer.errors.view())};
      }

      return parse(answer.output.view());
    }
  }
}
