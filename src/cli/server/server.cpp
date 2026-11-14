module telar.cli.server;

import telar.sys.posix;
import telar.sys.process;

import telar.cli.control_session;
import telar.client;

namespace telar::runtime::cli {

  namespace {

    // One help text: the root has no family, a family no command.
    struct HelpText {
      std::string_view family;
      std::string_view command;
      std::string_view text;
    };

    constexpr std::array help_texts{
#include "help_texts.inc"
    };

  }

  std::optional<std::string_view> helpText(HelpTopic topic) noexcept {
    for (const auto& entry : help_texts) {
      if (entry.family == topic.family && entry.command == topic.command) {
        return entry.text;
      }
    }

    return std::nullopt;
  }

  // The command a family's second word names, when its help lists it.
  std::string_view knownCommand(Family family, std::string_view word) noexcept {
    const HelpTopic topic{.family = familyName(family), .command = word};

    return !word.empty() && helpText(topic) ? word : std::string_view{};
  }

  bool isHelpFlag(std::string_view word) noexcept {
    return word == "--help" || word == "-h";
  }

  std::optional<HelpTopic> findHelp(std::span<char* const> words) noexcept {
    if (words.empty()) {
      return std::nullopt;
    }

    if (isHelpFlag(words.front())) {
      return HelpTopic{};
    }

    const auto family = parseFamily(words.front());
    if (!family) {
      return std::nullopt;
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
      return std::nullopt;
    }

    const std::string_view second = words.size() > 1 ? words[1] : "";

    return HelpTopic{.family = familyName(*family), .command = knownCommand(*family, second)};
  }

  std::string helpReference(std::span<char* const> words) {
    const auto family = words.empty() ? std::nullopt : parseFamily(words.front());
    if (!family) {
      return "telar --help";
    }

    std::string reference{"telar "};

    reference += familyName(*family);
    const auto command = knownCommand(*family, words.size() > 1 ? words[1] : "");
    if (!command.empty()) {
      reference += ' ';
      reference += command;
    }

    reference += " --help";
    return reference;
  }

  bool connectExisting(std::optional<RuntimeConnection>& connection, const char* path) {
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

  template <Allocator Memory>
  RuntimeStart startRuntime(Memory& memory, const ServerOptions& options, const RuntimePaths<Memory>& paths) {
    constexpr auto start_window = std::chrono::seconds{10};
    constexpr auto poll_interval = std::chrono::milliseconds{10};

    paths.prepareSocket();
    const auto child = launchDaemon(memory, options, paths, ExecutablePath{runtime_program});
    const auto deadline = std::chrono::steady_clock::now() + start_window;
    std::optional<RuntimeConnection> connection;

    while (!connectExisting(connection, paths.socket.c_str())) {
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

  template <Allocator Memory>
  void printEndpoint(Memory& memory, const ServerOptions& options, const RuntimePaths<Memory>& paths) {
    std::optional<RuntimeConnection> connection;
    if (!connectExisting(connection, paths.socket.c_str())) {
      const auto started = startRuntime(memory, options, paths);
      if (started == RuntimeStart::exited) {
        throw SystemError{"Runtime failed to start; inspect its .runtime.start.log", ECHILD};
      }

      if (started == RuntimeStart::timed_out) {
        throw SystemError{"Runtime did not start within ten seconds", ETIMEDOUT};
      }
    }

    std::printf("%s\n", paths.socket.c_str());
    std::fwrite(handshake::schema_id.data(), 1, handshake::schema_id.size(), stdout);
    std::fputc('\n', stdout);
  }

  void stopRuntime(const char* socket) {
    std::optional<RuntimeConnection> connection;
    if (!connectExisting(connection, socket)) {
      std::puts("telar runtime is not running");
      return;
    }

    connection->requestStop();
    std::puts("telar runtime is stopping");
  }

  template <Allocator Memory>
  [[noreturn]] void execRuntime(Memory& memory, std::span<char* const> arguments) {
    const ExecutablePath runtime{runtime_program};
    Vector<char*, Memory> command{AllocatorRef<char*, Memory>{memory}};

    command.reserve(arguments.size() + 2);
    command.push_back(const_cast<char*>(runtime.c_str()));
    command.insert(command.end(), arguments.begin(), arguments.end());
    command.push_back(nullptr);
    ::execv(runtime.c_str(), command.data());
    throw SystemError{"Start telar-runtime, which must be installed beside telar"};
  }

  template <Allocator Memory>
  void runServer(Memory& memory, std::span<char* const> arguments) {
    const auto options = ServerOptions::parse(arguments);
    if (options.action != ServerAction::stop && options.action != ServerAction::endpoint && options.action != ServerAction::bridge) {
      execRuntime(memory, arguments);
    }

    const ProcessEnvironment environment;
    const RuntimePaths paths{memory, options, environment};

    switch (options.action) {
    case ServerAction::stop:
      stopRuntime(paths.socket.c_str());
      return;
    case ServerAction::endpoint:
      printEndpoint(memory, options, paths);
      return;
    case ServerAction::bridge:
      RuntimeConnection{paths.socket.c_str(), false}.bridge();
    case ServerAction::run:
    case ServerAction::help:
      return;
    }
  }

  template RuntimeStart startRuntime<Memory>(Memory& memory, const ServerOptions& options, const RuntimePaths<Memory>& paths);
  template void execRuntime<Memory>(Memory& memory, std::span<char* const> arguments);
  template void runServer<Memory>(Memory& memory, std::span<char* const> arguments);

}
