#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.base.memory.allocators;
import telar.platform.fs;
import telar.platform.process;
import telar.runtime.shell_integration;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  std::string text(std::string_view value) {
    return std::string{value};
  }

  std::string readFile(const std::string& path) {
    std::ifstream file{path};

    return {std::istreambuf_iterator<char>{file}, {}};
  }

  // A program named like the shell, so a command resolves without that shell installed.
  std::string standIn(std::string_view directory, std::string_view name) {
    const auto path = text(directory) + "/" + text(name);

    check(::symlink("/bin/sh", path.c_str()) == 0);
    return path;
  }

  void testReplacesPlantedSymlink() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory home{"/tmp/telar-scripts-XXXXXX"};
    TemporaryDirectory reference{"/tmp/telar-scripts-XXXXXX"};
    const auto directory = text(ShellIntegration<ConcurrentMemory>::install(memory, home.path()));
    const auto shipped = readFile(text(ShellIntegration<ConcurrentMemory>::install(memory, reference.path())) + "/zsh/.zshenv");
    const auto script = directory + "/zsh/.zshenv";
    const auto victim = text(home.path()) + "/victim";

    // The file zsh sources first now links to another file.
    std::ofstream{victim} << "victim";
    check(::unlink(script.c_str()) == 0 && ::symlink(victim.c_str(), script.c_str()) == 0);
    ShellIntegration<ConcurrentMemory>::install(memory, home.path());
    struct stat state{};

    check(::lstat(script.c_str(), &state) == 0 && S_ISREG(state.st_mode), "the planted link is still what zsh sources");
    check(!shipped.empty() && readFile(script) == shipped);
    check(readFile(victim) == "victim", "telar wrote through the planted link");
  }

  void testUnwritableDirectoryLaunchesPlain() {
    if (::geteuid() == 0) {
      telar::testing::skip("root writes into any directory");
    }

    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory home{"/tmp/telar-scripts-XXXXXX"};
    const auto directory = text(ShellIntegration<ConcurrentMemory>::install(memory, home.path()));
    const ShellIntegration<ConcurrentMemory> integration{memory, directory};

    // Some scripts are gone, and the data home turned read-only, so they cannot be written again.
    std::filesystem::remove_all(directory + "/ssh");
    check(::chmod(directory.c_str(), 0500) == 0);
    const auto zsh = standIn(home.path(), "zsh");
    const std::array<std::string_view, 2> arguments{zsh, "-l"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};

    command.removeEnvironment("ZDOTDIR");
    const auto launch = integration.apply(command);

    check(::chmod(directory.c_str(), 0700) == 0);
    check(!launch, "a shell was integrated with scripts that are missing");
    check(!command.environment("ZDOTDIR") && !command.environment("TELAR_SHELL_TOKEN"), "the shell starts pointed at missing scripts");
    check(command.arguments().size() == 2 && std::string_view{command.arguments()[0]} == zsh && command.arguments()[1] == "-l");
  }

  void testBashLoginVariants() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory home{"/tmp/telar-scripts-XXXXXX"};
    const auto directory = ShellIntegration<ConcurrentMemory>::install(memory, home.path());
    const ShellIntegration<ConcurrentMemory> integration{memory, directory};
    const auto bash = standIn(home.path(), "bash");

    // A login bash ignores --rcfile, so telar's script reads the login files when told to.
    for (const std::string_view option : {"-l", "--login", "-il", "-li"}) {
      const std::array<std::string_view, 2> arguments{bash, option};
      Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};

      check(integration.apply(command).hasValue(), option);
      check(command.environment("TELAR_BASH_LOGIN") == "1", option);
    }

    const std::array<std::string_view, 2> interactive{bash, "-i"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = interactive}};

    check(integration.apply(command).hasValue() && !command.environment("TELAR_BASH_LOGIN"));
  }

  const telar::testing::Case case_replaces_planted_symlink{"shell_integration.replaces_planted_symlink", testReplacesPlantedSymlink};
  const telar::testing::Case case_unwritable_directory_launches_plain{"shell_integration.unwritable_directory_launches_plain", testUnwritableDirectoryLaunchesPlain};
  const telar::testing::Case case_bash_login_variants{"shell_integration.bash_login_variants", testBashLoginVariants};

}
