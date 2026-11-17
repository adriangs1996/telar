#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstring>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.platform.error;
import telar.platform.fs;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  void testPrivateDirectory() {
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

  const telar::testing::Case case_private_directory{"fs.private_directory", testPrivateDirectory};

}
