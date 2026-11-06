#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include "telar_base/memory/allocator.hpp"
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <algorithm>
#include <array>
#include <fcntl.h>
#include <limits.h>
#include <string_view>
#include <sys/stat.h>
#include <concepts>
#include <cstdlib>
#include <span>
#include <stdexcept>
#include <charconv>
#include <sys/un.h>
#include <cstring>
#include <filesystem>



import telar.platform;

using namespace telar;
using namespace telar::runtime;
using namespace telar::runtime::cli;

struct TestEnvironment {
  std::array<std::pair<std::string_view, std::string_view>, 8> values{};

  std::string_view lookup(const char *name) const noexcept {
    for (const auto &[key, value] : values) {
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

static void testArguments() {
  std::array arguments{const_cast<char *>("server"), const_cast<char *>("endpoint"), const_cast<char *>("--socket"), const_cast<char *>("/tmp/runtime.sock"), const_cast<char *>("--no-config")};
  const auto options = ServerOptions::parse(arguments);
  check(options.action == ServerAction::endpoint && options.socket == "/tmp/runtime.sock" && options.no_config);
  arguments.back() = const_cast<char *>("--fresh");
  bool rejected = false;
  try {
    ServerOptions::parse(arguments);
  } catch (const std::invalid_argument &) {
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
  } catch (const SystemError &) {
    rejected = true;
  }
  check(rejected);
  std::filesystem::remove_all(root);
}

void testCli() {
  testPaths();
  testArguments();
  testPrivateDirectory();
}
