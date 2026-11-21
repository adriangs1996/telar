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
import telar.testing.test_memory;
import telar.vocabulary;
import telar.platform.process;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  constexpr ds::Array<std::string_view, 5> pane_identity{"SSH_AUTH_SOCK", "TELAR_PANE_ID", "TELAR_PANE_GENERATION", "TELAR_WORKSPACE_ID", "TELAR_TAB_ID"};

  // A helper the runtime runs for itself reaches neither the user's ssh-agent nor the identity
  // of a pane, so an agent hook gated on TELAR_PANE_ID does not fire from it; a helper the
  // user configured keeps the environment it was given.
  void testAdministrationCommandDropsPaneIdentity() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    const ds::Array<std::string_view, 1> arguments{"/bin/sh"};
    const ds::Array<EnvironmentEntry, 6> environment{{
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
      check(!administration.environment(name).hasValue());
    }

    check(administration.environment("PATH") == "/usr/bin:/bin");

    const Command helper{memory, launch, CommandPurpose::configured_helper};

    for (const auto& entry : environment) {
      check(helper.environment(entry.name) == entry.value);
    }
  }

  // Input and output are pumped together: a program that echoes a large input as it reads
  // it finishes, instead of both ends blocking on full pipes.
  void testLargeInputDoesNotDeadlock() {
    std::atomic<bool> finished{false};
    std::thread watchdog{[&] {
      for (int tick = 0; tick < 300 && !finished.load(); ++tick) {
        std::this_thread::sleep_for(std::chrono::milliseconds{100});
      }

      check(finished.load(), "a large input to cat did not finish");
    }};

    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    std::string input(std::size_t{4} << 20, '\0');

    for (std::size_t index = 0; index < input.size(); ++index) {
      input[index] = static_cast<char>(index * 31 % 251);
    }

    const ds::Array<std::string_view, 1> arguments{"/bin/cat"};
    const ds::Array<std::string_view, 1> pieces{input};
    Command command{memory, Launch{.arguments = arguments}, CommandPurpose::configured_helper};
    CommandOutput<Memory> process{memory, 0};
    std::string output;
    const auto status = process.streamWithInput(
        command,
        std::chrono::steady_clock::now() + std::chrono::seconds{5},
        pieces,
        [&](std::span<const Byte> bytes) {
          output.append(reinterpret_cast<const char*>(bytes.data()), bytes.size());
          return true;
        },
        [](std::span<const Byte>) {}
    );

    finished = true;
    watchdog.join();
    check(status == 0);
    check(output == input);
  }

  // A pane starts as telar's own terminal: it does not inherit another runtime's socket or
  // Ghostty's resources, and it advertises 256 colors, truecolor and this program's version.
  void testTerminalCommandEnvironment() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    const ds::Array<std::string_view, 1> arguments{"/bin/sh"};
    const ds::Array<EnvironmentEntry, 5> environment{{
        {"TELAR_SOCKET", "/other/runtime.sock"},
        {"GHOSTTY_RESOURCES_DIR", "/ghostty"},
        {"TERM", "dumb"},
        {"TERM_PROGRAM_VERSION", "old"},
        {"PATH", "/usr/bin:/bin"},
    }};

    const Command terminal{memory, Launch{.cwd = "/", .arguments = arguments, .environment_mode = EnvironmentMode::replace, .environment = environment}};

    check(!terminal.environment("TELAR_SOCKET").hasValue());
    check(!terminal.environment("GHOSTTY_RESOURCES_DIR").hasValue());
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
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    TemporaryDirectory temporary{"/tmp/telar-launch-path-XXXXXX"};
    const std::string base{temporary.path()};
    const ds::Array<std::string_view, 1> arguments{"telar-launch-path-tool"};

    writeExecutable(base + "/bin/telar-launch-path-tool");
    const auto executable = [&](std::string_view path, std::string_view cwd) -> std::string {
      const ds::Array<EnvironmentEntry, 1> environment{{{"PATH", path}}};
      Command command{memory, Launch{.cwd = cwd, .arguments = arguments, .environment_mode = EnvironmentMode::replace, .environment = environment}};

      return command.specification({}).executable;
    };

    const auto absolute = base + "/bin";

    check(executable("/nonexistent:" + absolute, "/") == base + "/bin/telar-launch-path-tool");
    check(executable("bin", base) == base + "/bin/telar-launch-path-tool");

    // A directory named as the program is not the program: the search goes on past it.
    std::filesystem::create_directories(base + "/shadow/telar-launch-path-tool");
    check(executable(base + "/shadow:" + absolute, "/") == base + "/bin/telar-launch-path-tool");

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
      ds::Array<char, PATH_MAX> shell{};
      const char* path = std::getenv("PATH");
      if (!findExecutable({.path = path == nullptr ? "/usr/bin:/bin" : path, .program = name}, shell.viewMut())) {
        continue;
      }

      const auto script = loginShellScript(shell.data());

      check(!script.empty(), name);
      const auto line = "'" + std::string{shell.data()} + "' -c '" + std::string{script} + "' '" + program + "' 'a b' -x";
      auto* output = ::popen(line.c_str(), "r");

      check(output != nullptr);
      ds::Array<char, 256> bytes{};
      const auto count = std::fread(bytes.dataMut(), 1, bytes.size(), output);

      check(::pclose(output) == 0, name);
      check(std::string_view{bytes.data(), count} == "[a b][-x]", name);
      ++shells;
    }

    check(shells != 0);
    check(loginShellScript("/usr/bin/nu").empty());
  }

  const telar::testing::Case case_administration_environment{"process.administration_command_drops_pane_identity", testAdministrationCommandDropsPaneIdentity};
  const telar::testing::Case case_large_input{"process.large_input_does_not_deadlock", testLargeInputDoesNotDeadlock};
  const telar::testing::Case case_terminal_environment{"process.terminal_command_environment", testTerminalCommandEnvironment};
  const telar::testing::Case case_bare_program{"process.bare_program_uses_launch_path", testBareProgramUsesLaunchPath};
  const telar::testing::Case case_login_shell_script{"process.login_shell_script_execs_command", testLoginShellScriptExecsCommand};

}
