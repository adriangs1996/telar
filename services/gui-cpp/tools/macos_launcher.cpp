#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdio>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <mach-o/dyld.h>
#include <sys/syslimits.h>
#include <unistd.h>

import std;
import telar.gui.platform.login_shell;

namespace {

bool adoptHome(const char *const *environment) {
  constexpr std::string_view prefix = "HOME=";
  for (const auto *entry = environment; *entry != nullptr; ++entry) {
    const std::string_view value{*entry};
    if (value.starts_with(prefix)) {
      const std::string home{value.substr(prefix.size())};

      return ::chdir(home.c_str()) == 0;
    }
  }

  return true;
}

int launch(std::span<char *> input, const char *const *environment) {
  std::array<char, PATH_MAX> path{};
  auto size = static_cast<std::uint32_t>(path.size());
  if (_NSGetExecutablePath(path.data(), &size) != 0) {
    static_cast<void>(std::fputs("Telar C++: cannot locate application bundle\n", stderr));

    return EXIT_FAILURE;
  }

  const auto program = (std::filesystem::path{path.data()}.parent_path() / "telar-gui").lexically_normal().string();
  auto shell = telar::gui::platform::login_shell::path();
  if (shell.empty() || shell.front() != '/') {
    shell = "/bin/sh";
  }

  if (input.size() == 1 && !adoptHome(environment)) {
    std::perror("Telar C++: cannot open home directory");

    return EXIT_FAILURE;
  }

  const auto *script = telar::gui::platform::login_shell::script(shell);
  std::vector<std::string> arguments;
  if (script != nullptr) {
    arguments = {shell, "-l", "-c", script, program};
  } else {
    arguments = {program};
  }

  for (std::size_t index = 1; index < input.size(); ++index) {
    arguments.emplace_back(input[index]);
  }

  std::vector<char *> command;
  command.reserve(arguments.size() + 1);
  for (auto &argument : arguments) {
    command.push_back(argument.data());
  }

  command.push_back(nullptr);
  ::execv(command.front(), command.data());
  std::perror("Telar C++: cannot start login shell or GUI");

  return EXIT_FAILURE;
}

}

int main(int argc, char **argv, char *const *environment) {
  try {
    return launch({argv, static_cast<std::size_t>(argc)}, environment);
  } catch (const std::exception &error) {
    std::cerr << "Telar C++: " << error.what() << '\n';

    return EXIT_FAILURE;
  }
}
