#include "platform/peer_identity.hpp"
#include "platform/temporary_directory.hpp"
#include "platform/window_lease.hpp"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

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
    temporaryDirectoryCleanup();
    std::puts("gui-platform: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-platform: " << error.what() << '\n';

    return 1;
  }
}
