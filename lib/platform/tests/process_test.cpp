#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cerrno>
#include <limits.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.base.text;
import telar.platform.error;
import telar.platform.fs;
import telar.testing;
import telar.vocabulary;
import telar.platform.process;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  constexpr std::array<std::string_view, 5> pane_identity{"SSH_AUTH_SOCK", "TELAR_PANE_ID", "TELAR_PANE_GENERATION", "TELAR_WORKSPACE_ID", "TELAR_TAB_ID"};

  // A helper the runtime runs for itself reaches neither the user's ssh-agent nor the identity
  // of a pane, so an agent hook gated on TELAR_PANE_ID does not fire from it; a helper the
  // user configured keeps the environment it was given.
  void testAdministrationCommandDropsPaneIdentity() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;
    const std::array<std::string_view, 1> arguments{"/bin/sh"};
    const std::array<EnvironmentEntry, 6> environment{{
        {"SSH_AUTH_SOCK", "/tmp/agent.sock"},
        {"TELAR_PANE_ID", "7"},
        {"TELAR_PANE_GENERATION", "2"},
        {"TELAR_WORKSPACE_ID", "3"},
        {"TELAR_TAB_ID", "4"},
        {"PATH", "/usr/bin:/bin"},
    }};

    const Launch launch{.cwd = "/", .arguments = arguments, .environment_mode = EnvironmentMode::replace, .environment = environment};

    const Command administration{memory, launch, CommandPurpose::administration};

    for (const auto name : pane_identity) {
      check(!administration.environment(name).has_value());
    }

    check(administration.environment("PATH") == "/usr/bin:/bin");

    const Command helper{memory, launch, CommandPurpose::configured_helper};

    for (const auto& entry : environment) {
      check(helper.environment(entry.name) == entry.value);
    }
  }

  // A pane starts as telar's own terminal: it does not inherit another runtime's socket or
  // Ghostty's resources, and it advertises 256 colors, truecolor and this program's version.
  void testTerminalCommandEnvironment() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;
    const std::array<std::string_view, 1> arguments{"/bin/sh"};
    const std::array<EnvironmentEntry, 5> environment{{
        {"TELAR_SOCKET", "/other/runtime.sock"},
        {"GHOSTTY_RESOURCES_DIR", "/ghostty"},
        {"TERM", "dumb"},
        {"TERM_PROGRAM_VERSION", "old"},
        {"PATH", "/usr/bin:/bin"},
    }};

    const Command terminal{memory, Launch{.cwd = "/", .arguments = arguments, .environment_mode = EnvironmentMode::replace, .environment = environment}};

    check(!terminal.environment("TELAR_SOCKET").has_value());
    check(!terminal.environment("GHOSTTY_RESOURCES_DIR").has_value());
    check(terminal.environment("TERM") == "xterm-256color");
    check(terminal.environment("COLORTERM") == "truecolor");
    check(terminal.environment("TELAR_TERM_PROGRAM") == "telar");
    check(terminal.environment("TERM_PROGRAM_VERSION") == control::program_version);
  }

  void writeExecutable(const std::string& path) {
    std::filesystem::create_directories(std::filesystem::path{path}.parent_path());
    std::ofstream{path} << "#!/bin/sh\n";
    check(::chmod(path.c_str(), 0700) == 0);
  }

  // A bare program name is looked up along the PATH the launch gives, relative entries against
  // the launch's cwd, and a miss is ENOENT rather than a program from the runtime's own PATH.
  void testBareProgramUsesLaunchPath() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;
    TemporaryDirectory temporary{"/tmp/telar-launch-path-XXXXXX"};
    const std::string base{temporary.path()};
    const std::array<std::string_view, 1> arguments{"telar-launch-path-tool"};

    writeExecutable(base + "/bin/telar-launch-path-tool");
    const auto executable = [&](std::string_view path, std::string_view cwd) -> std::string {
      const std::array<EnvironmentEntry, 1> environment{{{"PATH", path}}};
      Command command{memory, Launch{.cwd = cwd, .arguments = arguments, .environment_mode = EnvironmentMode::replace, .environment = environment}};

      return command.specification({}).executable;
    };

    const auto absolute = base + "/bin";

    check(executable("/nonexistent:" + absolute, "/") == base + "/bin/telar-launch-path-tool");
    check(executable("bin", base) == base + "/bin/telar-launch-path-tool");

    int failure = 0;

    try {
      static_cast<void>(executable(base, "/"));
    } catch (const SystemError& error) {
      failure = error.code();
    }

    check(failure == ENOENT);
  }

  // `shell -c loginShellScript(shell) program args...` runs the program with exactly those
  // arguments, for each shell telar knows that this host has.
  void testLoginShellScriptExecsCommand() {
    TemporaryDirectory temporary{"/tmp/telar-login-script-XXXXXX"};
    const std::string base{temporary.path()};
    const auto program = base + "/show";

    std::ofstream{program} << "#!/bin/sh\nfor argument in \"$@\"; do printf '[%s]' \"$argument\"; done\n";
    check(::chmod(program.c_str(), 0700) == 0);
    std::size_t shells = 0;

    for (const std::string_view name : {"sh", "dash", "bash", "zsh", "fish"}) {
      std::array<char, PATH_MAX> shell{};
      const char* path = std::getenv("PATH");
      if (!findExecutable(path == nullptr ? "/usr/bin:/bin" : path, name, shell)) {
        continue;
      }

      const auto script = loginShellScript(shell.data());

      check(!script.empty(), name);
      const auto line = "'" + std::string{shell.data()} + "' -c '" + std::string{script} + "' '" + program + "' 'a b' -x";
      auto* output = ::popen(line.c_str(), "r");

      check(output != nullptr);
      std::array<char, 256> bytes{};
      const auto count = std::fread(bytes.data(), 1, bytes.size(), output);

      check(::pclose(output) == 0, name);
      check(std::string_view{bytes.data(), count} == "[a b][-x]", name);
      ++shells;
    }

    check(shells != 0);
    check(loginShellScript("/usr/bin/nu").empty());
  }

  const telar::testing::Case case_administration_environment{"process.administration_command_drops_pane_identity", testAdministrationCommandDropsPaneIdentity};
  const telar::testing::Case case_terminal_environment{"process.terminal_command_environment", testTerminalCommandEnvironment};
  const telar::testing::Case case_bare_program{"process.bare_program_uses_launch_path", testBareProgramUsesLaunchPath};
  const telar::testing::Case case_login_shell_script{"process.login_shell_script_execs_command", testLoginShellScriptExecsCommand};

}
