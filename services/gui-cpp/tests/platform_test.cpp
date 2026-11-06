#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <string_view>
#include <cstdint>
#include <array>
#include <climits>
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <dirent.h>
#include <fcntl.h>
#include <algorithm>
#include <cstdlib>
#include <limits.h>
#include <sys/stat.h>
#include <cstdio>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <sys/socket.h>
#include <unistd.h>



import telar.gui.platform.login_shell;
import telar.gui.platform.private_file_stamp;
import telar.gui.platform.notification_commands;
import telar.platform;

namespace {

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

void windowLease() {
  using telar::gui::platform::WindowLease;
  const telar::runtime::TemporaryDirectory directory{(std::filesystem::temp_directory_path() / "telar-gui-lease-XXXXXX").string()};
  const std::filesystem::path directory_path{directory.path()};
  const auto endpoint = (directory_path / "runtime.sock").string();

  {
    WindowLease first{endpoint};
    WindowLease second{endpoint};
    require(first.slot() == 0 && second.slot() == 1, "live windows must hold separate kernel leases");
  }

  {
    WindowLease reopened{endpoint};
    require(reopened.slot() == 0, "closing a window must make its stable identity available for restoration");
  }

  const auto lock = directory_path / "runtime.sock.gui-0.lock";
  constexpr mode_t world_writable_file = 0666;
  require(::chmod(lock.c_str(), world_writable_file) == 0, "prepare unsafe lock fixture");
  bool rejected = false;
  try {
    WindowLease unsafe{endpoint};
  } catch (const std::exception &) {
    rejected = true;
  }

  require(rejected, "world-writable lock files must be rejected");
  std::filesystem::remove(lock);
  std::filesystem::create_symlink(directory_path / "runtime.sock.gui-1.lock", lock);
  rejected = false;
  try {
    WindowLease unsafe{endpoint};
  } catch (const std::exception &) {
    rejected = true;
  }

  require(rejected, "window leases must never follow lock file symlinks");
  std::filesystem::remove(lock);
  constexpr mode_t world_writable_directory = 0777;
  require(::chmod(directory_path.c_str(), world_writable_directory) == 0, "prepare unsafe endpoint fixture");
  rejected = false;
  try {
    WindowLease unsafe{endpoint};
  } catch (const std::exception &) {
    rejected = true;
  }

  require(rejected, "untrusted endpoint directories must be rejected");
  constexpr mode_t owner_only_directory = 0700;
  require(::chmod(directory_path.c_str(), owner_only_directory) == 0, "restore endpoint directory permissions");
}

void managedDirectorySafety() {
  const telar::runtime::TemporaryDirectory directory{(std::filesystem::temp_directory_path() / "telar-gui-managed-XXXXXX").string()};
  const std::filesystem::path base{directory.path()};
  const auto managed = (base / "telar").string();
  telar::gui::platform::prepareManagedDirectory(managed);
  constexpr mode_t shared_mode = 0777;
  require(::chmod(managed.c_str(), shared_mode) == 0, "prepare owned permissive directory");
  telar::gui::platform::prepareManagedDirectory(managed);
  struct stat state{};
  constexpr mode_t permissions = 0777;
  constexpr mode_t owner_only = 0700;
  require(::stat(managed.c_str(), &state) == 0 && (state.st_mode & permissions) == owner_only, "managed runtime directories must be restricted owner-only");
  const auto link = base / "link";
  std::filesystem::create_directory_symlink(managed, link);
  bool rejected = false;
  try {
    telar::gui::platform::prepareManagedDirectory(link.string());
  } catch (const std::exception &) {
    rejected = true;
  }

  require(rejected, "managed directory preparation must never follow a final symlink");
  rejected = false;
  const auto missing = base / "absent";
  try {
    telar::gui::platform::prepareManagedDirectory((missing / "telar").string());
  } catch (const std::exception &) {
    rejected = true;
  }

  require(rejected && !std::filesystem::exists(missing), "a missing environment base must fail without creating ancestors");
}

void peerCredentials() {
  std::array<int, 2> descriptors{};
  require(::socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors.data()) == 0, "create peer credential fixture");
  const auto valid = telar::gui::platform::isCurrentUser(descriptors[0]);
  ::close(descriptors[0]);
  ::close(descriptors[1]);
  require(valid, "local peers must authenticate through kernel credentials");
  require(!telar::gui::platform::isCurrentUser(-1), "invalid descriptors must fail authentication");
}

void temporaryDirectoryCleanup() {
  std::filesystem::path path;
  {
    const telar::runtime::TemporaryDirectory directory{(std::filesystem::temp_directory_path() / "telar-gui-cleanup-XXXXXX").string()};
    path = directory.path();
    std::filesystem::create_directories(path / ".hidden" / "...");
    std::filesystem::create_directories(path / "visible" / "nested");
  }

  require(!std::filesystem::exists(path), "shared temporary directories must remove hidden and nested entries on both platforms");
}

}

int main() {
  try {
    windowLease();
    peerCredentials();
    managedDirectorySafety();
    temporaryDirectoryCleanup();
    std::puts("gui-platform: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-platform: " << error.what() << '\n';

    return 1;
  }
}
