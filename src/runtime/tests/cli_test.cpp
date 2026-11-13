#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

import std;
import telar.base.memory;
import telar.platform.primitives;
import telar.runtime.tests.check;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.paths;
import telar.client;

using namespace telar;
using namespace telar::runtime;
using namespace telar::runtime::cli;

struct TestEnvironment {
  std::array<std::pair<std::string_view, std::string_view>, 8> values{};

  std::string_view lookup(const char* name) const noexcept {
    for (const auto& [key, value] : values) {
      if (key == name) {
        return value;
      }
    }

    return {};
  }
};

static void testPaths() {
  SystemAllocator memory;
  TestEnvironment environment{{{{"TELAR_SOCKET", "/override/runtime.sock"}, {"TELAR_SOCKET_PATH", "/pane/runtime.sock"}, {"XDG_RUNTIME_DIR", "/runtime/"}, {"HOME", "/home/user"}, {"XDG_DATA_HOME", "/data"}}}};
  ServerOptions options;

  options.socket = "/explicit/runtime.sock";
  RuntimePaths explicit_paths{memory, options, environment};

  check(explicit_paths.socket == options.socket && !explicit_paths.socket_managed);
  options.socket = {};
  RuntimePaths override_paths{memory, options, environment};

  check(override_paths.socket == "/override/runtime.sock" && !override_paths.socket_managed);
  environment.values[0].second = {};
  RuntimePaths pane_paths{memory, options, environment};

  check(pane_paths.socket == "/pane/runtime.sock" && !pane_paths.socket_managed);
  environment.values[1].second = {};
  RuntimePaths managed_paths{memory, options, environment};

  check(managed_paths.socket == "/runtime/telar/runtime.sock" && managed_paths.socket_managed);

  managed_paths.resolveStorage(options, environment);
  check(managed_paths.history == "/data/telar/history.db" && managed_paths.history_managed);
  check(managed_paths.session == "/data/telar/session.ckpt");
  environment.values[4].second = {};
  RuntimePaths home_paths{memory, options, environment};

  home_paths.resolveStorage(options, environment);
  check(home_paths.history == "/home/user/.local/share/telar/history.db");

  environment.values[4] = {"TELAR_HISTORY", "/private/history.db"};
  options.persist_session = false;
  RuntimePaths custom_paths{memory, options, environment};

  custom_paths.resolveStorage(options, environment);
  check(custom_paths.history == "/private/history.db" && !custom_paths.history_managed && custom_paths.session.empty());
}

// Every process finds the configuration directory the same way: an XDG path counts only when
// absolute, HOME too, and without either there is none.
static void testConfigHome() {
  SystemAllocator memory;
  using Paths = RuntimePaths<SystemAllocator>;
  TestEnvironment environment{{{{"XDG_CONFIG_HOME", "/config"}, {"HOME", "/home/user"}, {"TELAR_DEVELOPMENT_CONFIG", ""}}}};

  check(Paths::configHome(memory, environment) == "/config/telar");
  check(Paths::configFile(memory, environment) == "/config/telar/config.lua");
  environment.values[0].second = "relative";
  check(Paths::configHome(memory, environment) == "/home/user/.config/telar");
  environment.values[0].second = {};
  check(Paths::configHome(memory, environment) == "/home/user/.config/telar");
  environment.values[1].second = {};
  check(Paths::configHome(memory, environment).empty() && Paths::configFile(memory, environment).empty());
  environment.values[1].second = "home";
  check(Paths::configHome(memory, environment).empty());
  environment.values[2].second = "/repository/dev/config.lua";
  check(Paths::configFile(memory, environment) == "/repository/dev/config.lua");

  ServerOptions options;

  options.socket = "/run/user/";
  bool rejected = false;

  try {
    RuntimePaths directory{memory, options, environment};
  } catch (const std::invalid_argument&) {
    rejected = true;
  }

  check(rejected);
}

// The errno names scripts read after `error: `: one for denied access, one for anything unknown.
static void testErrorNames() {
  check(std::string_view{systemErrorName(EACCES)} == "AccessDenied" && std::string_view{systemErrorName(EPERM)} == "AccessDenied");
  check(std::string_view{systemErrorName(EIO)} == "InputOutput" && std::string_view{systemErrorName(EEXIST)} == "PathAlreadyExists");
  check(std::string_view{systemErrorName(ENOSPC)} == "NoSpaceLeft" && std::string_view{systemErrorName(EINVAL)} == "InvalidArgument");
  check(std::string_view{systemErrorName(EDOM)} == "Unexpected");
}

static void testArguments() {
  std::array arguments{const_cast<char*>("server"), const_cast<char*>("endpoint"), const_cast<char*>("--socket"), const_cast<char*>("/tmp/runtime.sock"), const_cast<char*>("--no-config")};
  const auto options = ServerOptions::parse(arguments);

  check(options.action == ServerAction::endpoint && options.socket == "/tmp/runtime.sock" && options.no_config);
  arguments.back() = const_cast<char*>("--fresh");
  bool rejected = false;

  try {
    ServerOptions::parse(arguments);
  } catch (const std::invalid_argument&) {
    rejected = true;
  }

  check(rejected);
}

static void testPrivateDirectory() {
  std::array<char, 64> temporary{};

  std::strcpy(temporary.data(), "/tmp/telar-cli-test-XXXXXX");
  check(::mkdtemp(temporary.data()) != nullptr);
  const std::string root = temporary.data();
  const auto path = root + "/parent/child";

  createPrivateDirectory(path);
  struct stat state{};

  check(::stat(path.c_str(), &state) == 0 && (state.st_mode & 0777) == 0700);
  check(::chmod(path.c_str(), 0755) == 0);
  createPrivateDirectory(path);
  check(::stat(path.c_str(), &state) == 0 && (state.st_mode & 0777) == 0700);

  const auto link = root + "/linked";

  check(::symlink(path.c_str(), link.c_str()) == 0);
  bool rejected = false;

  try {
    createPrivateDirectory(link);
  } catch (const SystemError&) {
    rejected = true;
  }

  check(rejected);
  std::filesystem::remove_all(root);
}

// The client's socket is never inherited by a program the process runs, and it is closed once,
// by whichever client owns it last.
static void testClientSocket() {
  std::array<char, 64> temporary{};

  std::strcpy(temporary.data(), "/tmp/telar-client-test-XXXXXX");
  check(::mkdtemp(temporary.data()) != nullptr);
  const std::string root = temporary.data();
  const auto path = root + "/runtime.sock";
  const int listener = ::socket(AF_UNIX, SOCK_STREAM, 0);
  sockaddr_un address{};

  address.sun_family = AF_UNIX;
  std::strcpy(address.sun_path, path.c_str());
  check(listener >= 0 && ::bind(listener, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0 && ::listen(listener, 4) == 0);

  int descriptor = -1;

  {
    auto client = Client::init(path.c_str());

    descriptor = client.descriptor();
    check(descriptor >= 0 && (::fcntl(descriptor, F_GETFD) & FD_CLOEXEC) != 0);
    Client moved{std::move(client)};

    check(client.descriptor() == -1 && moved.descriptor() == descriptor);
    Client assigned = Client::init(path.c_str());
    const auto replaced = assigned.descriptor();

    assigned = std::move(moved);
    check(assigned.descriptor() == descriptor && ::fcntl(replaced, F_GETFD) == -1 && errno == EBADF);
  }

  check(::fcntl(descriptor, F_GETFD) == -1 && errno == EBADF);

  ::close(listener);
  std::filesystem::remove_all(root);
}

void testCli() {
  testPaths();
  testConfigHome();
  testErrorNames();
  testArguments();
  testPrivateDirectory();
  testClientSocket();
}
