#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.platform.daemon;
import telar.platform.fs;
import telar.platform.paths;
import telar.platform.process;
import telar.base.ds;

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

  // The options as one line per field, the same for the launcher and the daemon it starts.
  std::string describe(const cli::ServerOptions& options) {
    std::string text;
    const auto line = [&](std::string_view name, std::string_view value) {
      text += std::string{name} + '=' + std::string{value} + '\n';
    };

    line("mode", options.mode == cli::ServerMode::daemonized ? "daemonized" : "other");
    line("socket", options.socket);
    line("history", options.history);
    line("session", options.session);
    line("trace", options.trace);
    line("config", options.config);
    line("profile", options.profile);
    for (const auto argument : std::span{options.engine_arguments}.first(options.engine_argument_count)) {
      line("engine", argument);
    }

    line("flags", std::string{options.no_config ? "no_config " : ""} + (options.fresh ? "fresh " : "") + (options.persist_session ? "" : "no_session ") + (options.resume_agents ? "" : "no_resume"));
    return text;
  }

  // The daemon the next case launches is this program again: it reads its command line as
  // `telar server` does and writes what it read to stderr, which launchDaemon sends to the
  // start log.
  int reportServerOptions(int argc, char** argv) {
    const auto options = cli::ServerOptions::parse(std::span{argv + 1, static_cast<std::size_t>(argc - 1)});
    const auto text = describe(options);

    std::fwrite(text.data(), 1, text.size(), stderr);
    return 0;
  }

  const telar::testing::Mode mode_server{"server", reportServerOptions};

  struct NoEnvironment final : EnvironmentSource {
    std::string_view lookup(const char*) const noexcept override {
      return {};
    }
  };

  // `telar server --background` hands the daemon every option it was given, with the
  // configuration made absolute: the daemon runs from `/`, where a relative one names another file.
  void testLaunchForwardsOptions() {
    TemporaryDirectory temporary{"/tmp/telar-daemon-launch-XXXXXX"};
    const std::string base{temporary.path()};

    std::ofstream{base + "/config.lua"} << "return {api_version = 2}\n";
    check(::chdir(base.c_str()) == 0);
    ds::Array<char, PATH_MAX> canonical{};

    check(::realpath("config.lua", canonical.dataMut()) != nullptr);
    const auto socket = base + "/runtime.sock";
    cli::ServerOptions options;

    options.socket = socket;
    options.history = "/state/history.db";
    options.session = "/state/session.ckpt";
    options.trace = "/state/trace.json";
    options.config = "config.lua";
    options.profile = "work";
    options.engine_arguments.atMut(0) = "--one";
    options.engine_arguments.atMut(1) = "two words";
    options.engine_argument_count = 2;
    options.persist_session = false;
    options.resume_agents = false;
    SystemAllocator memory;
    const cli::RuntimePaths paths{memory, options, NoEnvironment{}};
    const auto child = cli::launchDaemon(memory, options, paths, ExecutablePath{});
    int status = 0;

    check(::waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    std::ifstream log{socket + ".runtime.start.log"};
    const std::string reported{std::istreambuf_iterator<char>{log}, {}};
    auto expected = options;

    expected.mode = cli::ServerMode::daemonized;
    expected.config = canonical.data();
    check(reported == describe(expected), reported);
  }

  const telar::testing::Case case_start_log{"daemon.start_log_refuses_links", testStartLogRefusesLinks};
  const telar::testing::Case case_launch_forwards{"daemon.launch_forwards_options", testLaunchForwardsOptions};

}
