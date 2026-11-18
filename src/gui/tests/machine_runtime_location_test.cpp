#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "assertions.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <iostream>
#include <limits>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

import telar.gui.features.machines;
import telar.gui.foundation.system;
import telar.base.ds;

namespace {

  using namespace telar::gui;

  using namespace telar::gui::features::machines;
  using telar::gui::test::require;

  struct Environment {
    telar::ds::Array<std::pair<std::string_view, std::string_view>, 4> values;

    [[nodiscard]] telar::ds::Option<std::string_view> operator()(const char* name) const {
      for (const auto& [key, value] : values) {
        if (key == name) {
          return value;
        }
      }

      return telar::ds::none;
    }
  };

  void precedenceAndManagedDefaults() {
    constexpr std::uint32_t user = 1234;
    const Environment explicit_environment{.values = {{{"TELAR_SOCKET", "/explicit.sock"}, {"TELAR_SOCKET_PATH", "/inherited.sock"}, {"XDG_RUNTIME_DIR", "/run/user"}, {"TMPDIR", "/temporary"}}}};
    const auto explicit_location = MachineRuntimeLocation::resolve(explicit_environment, user);

    require(explicit_location.endpoint() == "/explicit.sock" && !explicit_location.managedDirectory(), "TELAR_SOCKET must override inherited and managed locations");
    auto inherited = explicit_environment;

    inherited.values.atMut(0).second = "";
    require(MachineRuntimeLocation::resolve(inherited, user).endpoint() == "/inherited.sock", "an empty explicit variable must retain the pane runtime fallback");
    inherited.values.atMut(1).second = "";
    const auto managed = MachineRuntimeLocation::resolve(inherited, user);

    require(managed.endpoint() == "/run/user/telar/runtime.sock" && managed.managedDirectory() == "/run/user/telar", "XDG runtime placement must create only its Telar subdirectory");
    inherited.values.atMut(2).second = "";
    require(MachineRuntimeLocation::resolve(inherited, user).endpoint() == "/temporary/telar-1234/runtime.sock", "TMPDIR must namespace the managed directory by real user ID");
    inherited.values.atMut(3).second = "";
    require(MachineRuntimeLocation::resolve(inherited, user).endpoint() == "/tmp/telar-1234/runtime.sock", "missing runtime placement must use the original portable fallback");
    require(MachineRuntimeLocation::resolve(inherited, std::numeric_limits<std::uint32_t>::max()).endpoint() == "/tmp/telar-4294967295/runtime.sock", "the full native user ID must remain representable");
    inherited.values.atMut(2).second = "/run/user/";
    require(MachineRuntimeLocation::resolve(inherited, user).endpoint() == managed.endpoint(), "managed placement must preserve a single existing path separator");
  }

  void invalidLocationsAndCapacity() {
    const std::string boundary = "/" + std::string(system::SocketLimits::path_bytes - 1, 'x');

    require(MachineRuntimeLocation::explicitPath(boundary).endpoint() == boundary, "the native Unix socket path boundary must be admitted");
    const auto too_long = boundary + 'x';
    const telar::ds::Array<std::string_view, 5> invalid{"", "relative", std::string_view{"/a\0b", 4}, too_long, "/run/user/"};

    for (const auto path : invalid) {
      bool rejected = false;

      try {
        static_cast<void>(MachineRuntimeLocation::explicitPath(path));
      } catch (const MachineFailure& failure) {
        rejected = failure.code() == MachineError::invalid_runtime_directory;
      }

      require(rejected, "invalid endpoint bytes must fail before native directory work");
    }

    const Environment relative{.values = {{{"XDG_RUNTIME_DIR", "relative"}, {}, {}, {}}}};
    bool rejected = false;

    try {
      static_cast<void>(MachineRuntimeLocation::resolve(relative, std::uint32_t{1}));
    } catch (const MachineFailure& failure) {
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
  } catch (const std::exception& failure) {
    std::cerr << failure.what() << '\n';

    return 1;
  }
}
