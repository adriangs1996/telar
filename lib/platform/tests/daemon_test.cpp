#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.platform.daemon;
import telar.platform.fs;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // `telar server --background` truncates `<socket>.runtime.start.log`; a link planted at that
  // path must not let it truncate or append to the file the link names.
  void testStartLogRefusesLinks() {
    TemporaryDirectory temporary{"/tmp/telar-start-log-XXXXXX"};
    const std::string base{temporary.path()};
    const auto target = base + "/target";
    const auto write = [](const std::string& path, std::string_view bytes) {
      std::ofstream output{path, std::ios::binary};

      output.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
      check(output.good());
    };

    // Separate targets, so the hard link's count does not refuse the symbolic one.
    const auto linked = base + "/linked";

    write(target, "keep");
    write(linked, "keep");
    check(::symlink(target.c_str(), (base + "/symbolic.log").c_str()) == 0);
    check(::link(linked.c_str(), (base + "/hard.log").c_str()) == 0);
    check(!cli::openStartLog((base + "/symbolic.log").c_str()));
    check(!cli::openStartLog((base + "/hard.log").c_str()));
    check(std::filesystem::file_size(target) == 4);
    check(std::filesystem::file_size(linked) == 4);

    const auto log = base + "/runtime.start.log";

    write(log, "previous start");
    check(::chmod(log.c_str(), 0644) == 0);
    const auto file = cli::openStartLog(log.c_str());
    struct stat status{};

    check(static_cast<bool>(file));
    check(::stat(log.c_str(), &status) == 0);
    check(status.st_size == 0 && (status.st_mode & 0777) == 0600);
  }

  const telar::testing::Case case_start_log{"daemon.start_log_refuses_links", testStartLogRefusesLinks};

}
