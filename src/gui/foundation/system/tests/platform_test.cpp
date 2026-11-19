#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cerrno>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.platform.primitives;
import telar.gui.foundation.system;
import telar.platform.net;
import telar.platform.fs;
import telar.base.ds;

namespace {

  using telar::testing::check;

  void windowLease() {
    using telar::gui::system::WindowLease;
    const telar::runtime::TemporaryDirectory directory{(std::filesystem::temp_directory_path() / "telar-gui-lease-XXXXXX").string()};
    const std::filesystem::path directory_path{directory.path()};
    const auto endpoint = (directory_path / "runtime.sock").string();

    {
      WindowLease first{endpoint};
      WindowLease second{endpoint};

      check(first.slot() == 0 && second.slot() == 1, "live windows must hold separate kernel leases");
    }

    {
      WindowLease reopened{endpoint};

      check(reopened.slot() == 0, "closing a window must make its stable identity available for restoration");
    }

    const auto lock = directory_path / "runtime.sock.gui-0.lock";
    constexpr mode_t world_writable_file = 0666;

    check(::chmod(lock.c_str(), world_writable_file) == 0, "prepare unsafe lock fixture");
    bool rejected = false;

    try {
      WindowLease unsafe{endpoint};
    } catch (const std::exception&) {
      rejected = true;
    }

    check(rejected, "world-writable lock files must be rejected");
    std::filesystem::remove(lock);
    std::filesystem::create_symlink(directory_path / "runtime.sock.gui-1.lock", lock);
    rejected = false;
    try {
      WindowLease unsafe{endpoint};
    } catch (const std::exception&) {
      rejected = true;
    }

    check(rejected, "window leases must never follow lock file symlinks");
    std::filesystem::remove(lock);
    constexpr mode_t world_writable_directory = 0777;

    check(::chmod(directory_path.c_str(), world_writable_directory) == 0, "prepare unsafe endpoint fixture");
    rejected = false;
    try {
      WindowLease unsafe{endpoint};
    } catch (const std::exception&) {
      rejected = true;
    }

    check(rejected, "untrusted endpoint directories must be rejected");
    constexpr mode_t owner_only_directory = 0700;

    check(::chmod(directory_path.c_str(), owner_only_directory) == 0, "restore endpoint directory permissions");
  }

  void managedDirectorySafety() {
    const telar::runtime::TemporaryDirectory directory{(std::filesystem::temp_directory_path() / "telar-gui-managed-XXXXXX").string()};
    const std::filesystem::path base{directory.path()};
    const auto managed = (base / "telar").string();

    telar::gui::system::prepareManagedDirectory(managed);
    constexpr mode_t shared_mode = 0777;

    check(::chmod(managed.c_str(), shared_mode) == 0, "prepare owned permissive directory");
    telar::gui::system::prepareManagedDirectory(managed);
    struct stat state{};
    constexpr mode_t permissions = 0777;
    constexpr mode_t owner_only = 0700;

    check(::stat(managed.c_str(), &state) == 0 && (state.st_mode & permissions) == owner_only, "managed runtime directories must be restricted owner-only");
    const auto link = base / "link";

    std::filesystem::create_directory_symlink(managed, link);
    bool rejected = false;

    try {
      telar::gui::system::prepareManagedDirectory(link.string());
    } catch (const std::exception&) {
      rejected = true;
    }

    check(rejected, "managed directory preparation must never follow a final symlink");
    rejected = false;
    const auto missing = base / "absent";

    try {
      telar::gui::system::prepareManagedDirectory((missing / "telar").string());
    } catch (const std::exception&) {
      rejected = true;
    }

    check(rejected && !std::filesystem::exists(missing), "a missing environment base must fail without creating ancestors");
  }

  void peerCredentials() {
    telar::ds::Array<int, 2> descriptors{};

    check(::socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors.dataMut()) == 0, "create peer credential fixture");
    const auto valid = telar::gui::system::isCurrentUser(descriptors[0]);

    ::close(descriptors[0]);
    ::close(descriptors[1]);
    check(valid, "local peers must authenticate through kernel credentials");
    check(!telar::gui::system::isCurrentUser(-1), "invalid descriptors must fail authentication");
  }

  void temporaryDirectoryCleanup() {
    std::filesystem::path path;

    {
      const telar::runtime::TemporaryDirectory directory{(std::filesystem::temp_directory_path() / "telar-gui-cleanup-XXXXXX").string()};

      path = directory.path();
      std::filesystem::create_directories(path / ".hidden" / "...");
      std::filesystem::create_directories(path / "visible" / "nested");
    }

    check(!std::filesystem::exists(path), "shared temporary directories must remove hidden and nested entries on both platforms");
  }

  const telar::testing::Case case_window_lease{"platform.window_lease", windowLease};
  const telar::testing::Case case_peer_credentials{"platform.peer_credentials", peerCredentials};
  const telar::testing::Case case_managed_directory_safety{"platform.managed_directory_safety", managedDirectorySafety};
  const telar::testing::Case case_temporary_directory_cleanup{"platform.temporary_directory_cleanup", temporaryDirectoryCleanup};

}
