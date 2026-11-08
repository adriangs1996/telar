#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "assertions.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <sys/un.h>
#include <charconv>
#include <concepts>
#include <cstring>
#include <string_view>
#include <system_error>
#include <optional>
#include <exception>
#include <iostream>
#include <limits>
#include <string>
#include <utility>



import telar.gui.machines.discovery;
import telar.gui.platform.notification_commands;

namespace {

using namespace telar::gui;
using telar::gui::test::require;

struct Environment {
  std::array<std::pair<std::string_view, std::string_view>, 4> values;

  [[nodiscard]] std::optional<std::string_view> operator()(const char *name) const {
    for (const auto &[key, value] : values) {
      if (key == name) {
        return value;
      }
    }

    return std::nullopt;
  }
};

void precedenceAndManagedDefaults() {
  constexpr std::uint32_t user = 1234;
  const Environment explicit_environment{.values = {{{"TELAR_SOCKET", "/explicit.sock"}, {"TELAR_SOCKET_PATH", "/inherited.sock"}, {"XDG_RUNTIME_DIR", "/run/user"}, {"TMPDIR", "/temporary"}}}};
  const auto explicit_location = MachineRuntimeLocation::resolve(explicit_environment, user);
  require(explicit_location.endpoint() == "/explicit.sock" && !explicit_location.managedDirectory(), "TELAR_SOCKET must override inherited and managed locations");
  auto inherited = explicit_environment;
  inherited.values.front().second = "";
  require(MachineRuntimeLocation::resolve(inherited, user).endpoint() == "/inherited.sock", "an empty explicit variable must retain the pane runtime fallback");
  inherited.values[1].second = "";
  const auto managed = MachineRuntimeLocation::resolve(inherited, user);
  require(managed.endpoint() == "/run/user/telar/runtime.sock" && managed.managedDirectory() == "/run/user/telar", "XDG runtime placement must create only its Telar subdirectory");
  inherited.values[2].second = "";
  require(MachineRuntimeLocation::resolve(inherited, user).endpoint() == "/temporary/telar-1234/runtime.sock", "TMPDIR must namespace the managed directory by real user ID");
  inherited.values[3].second = "";
  require(MachineRuntimeLocation::resolve(inherited, user).endpoint() == "/tmp/telar-1234/runtime.sock", "missing runtime placement must use the original portable fallback");
  require(MachineRuntimeLocation::resolve(inherited, std::numeric_limits<std::uint32_t>::max()).endpoint() == "/tmp/telar-4294967295/runtime.sock", "the full native user ID must remain representable");
  inherited.values[2].second = "/run/user/";
  require(MachineRuntimeLocation::resolve(inherited, user).endpoint() == managed.endpoint(), "managed placement must preserve a single existing path separator");
}

void invalidLocationsAndCapacity() {
  const std::string boundary = "/" + std::string(platform::SocketLimits::path_bytes - 1, 'x');
  require(MachineRuntimeLocation::explicitPath(boundary).endpoint() == boundary, "the native Unix socket path boundary must be admitted");
  const auto too_long = boundary + 'x';
  const std::array<std::string_view, 4> invalid{"", "relative", std::string_view{"/a\0b", 4}, too_long};
  for (const auto path : invalid) {
    bool rejected = false;
    try {
      static_cast<void>(MachineRuntimeLocation::explicitPath(path));
    } catch (const MachineFailure &failure) {
      rejected = failure.code() == MachineError::invalid_runtime_directory;
    }

    require(rejected, "invalid endpoint bytes must fail before native directory work");
  }

  const Environment relative{.values = {{{"XDG_RUNTIME_DIR", "relative"}, {}, {}, {}}}};
  bool rejected = false;
  try {
    static_cast<void>(MachineRuntimeLocation::resolve(relative, std::uint32_t{1}));
  } catch (const MachineFailure &failure) {
    rejected = failure.code() == MachineError::invalid_runtime_directory;
  }

  require(rejected, "an invalid managed base must not silently fall back to another runtime");
}

}

int main() {
  try {
    precedenceAndManagedDefaults();
    invalidLocationsAndCapacity();
    std::cout << "gui-machine-runtime-location: passed\n";
  } catch (const std::exception &failure) {
    std::cerr << failure.what() << '\n';

    return 1;
  }
}
