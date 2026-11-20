module telar.cli.server;

import telar.sys.posix;
import telar.sys.process;

import telar.cli.command_limit;
import telar.cli.control_session;
import telar.client;
import telar.cli.runtime_observer;
import telar.platform.daemon;
import telar.platform.error;
import telar.platform.primitives;
import telar.platform.process;
import telar.base.ds;

namespace telar::runtime::cli {

  namespace {

    // One help text: the root has no family, a family no command.
    struct HelpText {
      std::string_view family;
      std::string_view command;
      std::string_view text;
    };

    constexpr ds::Array help_texts{
#include "help_texts.inc"
    };

  }

  namespace {

    // The command a family's second word names, when its help lists it.
    std::string_view knownCommand(Family family, std::string_view word) noexcept {
      const HelpTopic topic{.family = familyName(family), .command = word};

      return !word.empty() && helpText(topic) ? word : std::string_view{};
    }

    bool isHelpFlag(std::string_view word) noexcept {
      return word == "--help" || word == "-h";
    }

  }

  ds::Option<std::string_view> helpText(HelpTopic topic) noexcept {
    for (const auto& entry : help_texts) {
      if (entry.family == topic.family && entry.command == topic.command) {
        return entry.text;
      }
    }

    return ds::none;
  }

  ds::Option<HelpTopic> findHelp(std::span<char* const> words) noexcept {
    if (words.empty()) {
      return ds::none;
    }

    if (isHelpFlag(words.front())) {
      return HelpTopic{};
    }

    const auto family = parseFamily(words.front());
    if (!family) {
      return ds::none;
    }

    bool asked = false;

    for (const std::string_view word : words.subspan(1)) {
      if (word == "--") {
        break;
      }

      if (isHelpFlag(word)) {
        asked = true;
        break;
      }
    }

    if (!asked) {
      return ds::none;
    }

    const std::string_view second = words.size() > 1 ? words[1] : "";

    return HelpTopic{.family = familyName(*family), .command = knownCommand(*family, second)};
  }

  ErrorText<help_reference_bytes> helpReference(std::span<char* const> words) {
    const auto family = words.empty() ? ds::none : parseFamily(words.front());
    if (!family) {
      return ErrorText<help_reference_bytes>{"telar --help"};
    }

    const auto command = knownCommand(*family, words.size() > 1 ? words[1] : "");
    if (command.empty()) {
      return ErrorText<help_reference_bytes>{"telar ", familyName(*family), " --help"};
    }

    return ErrorText<help_reference_bytes>{"telar ", familyName(*family), " ", command, " --help"};
  }

  bool connectExisting(ds::Option<RuntimeConnection>& connection, const char* path) {
    try {
      connection.emplace(path);
      return true;
    } catch (const SystemError& error) {
      if (error.code() != ENOENT && error.code() != ECONNREFUSED) {
        throw;
      }

      return false;
    }
  }

  RuntimeStart startRuntime(Memory& memory, const ServerOptions& options, const RuntimePaths<Memory>& paths) {
    constexpr auto start_window = std::chrono::seconds{10};
    constexpr auto poll_interval = std::chrono::milliseconds{10};

    paths.prepareSocket();
    const auto child = launchDaemon(memory, options, paths, ExecutablePath{runtime_program});
    const auto deadline = std::chrono::steady_clock::now() + start_window;
    ds::Option<RuntimeConnection> connection;

    while (!connectExisting(connection, paths.socket.data())) {
      int status = 0;
      if (::waitpid(child, &status, WNOHANG) == child) {
        return RuntimeStart::exited;
      }

      if (std::chrono::steady_clock::now() >= deadline) {
        return RuntimeStart::timed_out;
      }

      std::this_thread::sleep_for(poll_interval);
    }

    return RuntimeStart::listening;
  }

  namespace {

    template <Allocator Memory>
    void printEndpoint(Memory& memory, const ServerOptions& options, const RuntimePaths<Memory>& paths) {
      ds::Option<RuntimeConnection> connection;
      if (!connectExisting(connection, paths.socket.data())) {
        const auto started = startRuntime(memory, options, paths);
        if (started == RuntimeStart::exited) {
          throw SystemError{"Runtime failed to start; inspect its .runtime.start.log", ECHILD};
        }

        if (started == RuntimeStart::timed_out) {
          throw SystemError{"Runtime did not start within ten seconds", ETIMEDOUT};
        }
      }

      std::print("{}\n{}\n", std::string_view{paths.socket.data()}, textBytes(handshake::schema_id.view()));
    }

    void stopRuntime(const char* socket) {
      ds::Option<RuntimeConnection> connection;
      if (!connectExisting(connection, socket)) {
        std::puts("telar runtime is not running");
        return;
      }

      connection.getMut().requestStop();
      std::puts("telar runtime is stopping");
    }

  }

  [[noreturn]] void execRuntime(Memory& memory, std::span<char* const> arguments) {
    const ExecutablePath runtime{runtime_program};
    ds::Vec<char*, Memory> command{memory};

    command.reserve(arguments.size() + 2);
    command.push(const_cast<char*>(runtime.c_str())); // NOLINT(cppcoreguidelines-pro-type-const-cast): execv's C signature takes the arguments as char*, and does not write them
    command.extend({arguments.begin(), arguments.end()});
    command.push(nullptr);
    ::execv(runtime.c_str(), command.data());
    throw SystemError{"Start telar-runtime, which must be installed beside telar"};
  }

  void runServer(Memory& memory, std::span<char* const> arguments) {
    const auto options = ServerOptions::parse(arguments);
    if (options.action != ServerAction::stop && options.action != ServerAction::endpoint && options.action != ServerAction::bridge) {
      execRuntime(memory, arguments);
    }

    const ProcessEnvironment environment;
    const RuntimePaths<Memory> paths{memory, options, environment};

    switch (options.action) {
    case ServerAction::stop:
      stopRuntime(paths.socket.data());
      return;
    case ServerAction::endpoint:
      printEndpoint(memory, options, paths);
      return;
    case ServerAction::bridge:
      RuntimeConnection{paths.socket.data(), false}.bridge();
    case ServerAction::run:
    case ServerAction::help:
      return;
    }
  }

}
