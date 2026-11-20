#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <mach-o/dyld.h>
#include <sys/syslimits.h>
#include <unistd.h>

import std;
import telar.platform.process;
import telar.base.ds;
import telar.base.memory.allocators;

namespace {

  using Text = telar::ds::String<telar::SystemAllocator>;

  bool adoptHome(telar::SystemAllocator& memory, const char* const* environment) {
    constexpr std::string_view prefix = "HOME=";

    // The C runtime's environment is an array that ends at a null entry, with no length to bound it.
#pragma clang unsafe_buffer_usage begin
    for (const auto* entry = environment; *entry != nullptr; ++entry) {
      const std::string_view value{*entry};
      if (value.starts_with(prefix)) {
        const Text home{memory, value.substr(prefix.size())};

        return ::chdir(home.data()) == 0;
      }
    }
#pragma clang unsafe_buffer_usage end

    return true;
  }

  int launch(telar::SystemAllocator& memory, std::span<char*> input, const char* const* environment) {
    telar::ds::Array<char, PATH_MAX> path{};
    auto size = static_cast<std::uint32_t>(path.size());
    if (_NSGetExecutablePath(path.dataMut(), &size) != 0) {
      std::cerr << "Telar C++: cannot locate application bundle\n";

      return EXIT_FAILURE;
    }

    const auto gui = (std::filesystem::path{path.data()}.parent_path() / "telar-gui").lexically_normal();
    const std::string_view program{gui.native()};
    const auto login = telar::runtime::loginShell();
    const auto shell = login.view();

    if (input.size() == 1 && !adoptHome(memory, environment)) {
      std::perror("Telar C++: cannot open home directory");

      return EXIT_FAILURE;
    }

    const auto script = telar::runtime::loginShellScript(shell);
    // Each argument NUL-terminated, as execv reads it.
    telar::ds::Vec<Text, telar::SystemAllocator> arguments{memory};

    if (!script.empty()) {
      for (const auto word : {shell, std::string_view{"-l"}, std::string_view{"-c"}, script}) {
        arguments.emplace(memory, word);
      }
    }

    arguments.emplace(memory, program);
    for (std::size_t index = 1; index < input.size(); ++index) {
      arguments.emplace(memory, std::string_view{input[index]});
    }

    telar::ds::Vec<char*, telar::SystemAllocator> command{memory};

    command.reserve(arguments.size() + 1);
    for (const auto& argument : arguments) {
      // execv takes char* const[] for C's sake and writes none of it.
      command.push(const_cast<char*>(argument.data())); // NOLINT(cppcoreguidelines-pro-type-const-cast): execv's C signature.
    }

    command.push(nullptr);
    ::execv(command[0], command.data());
    std::perror("Telar C++: cannot start login shell or GUI");

    return EXIT_FAILURE;
  }

}

int main(int argc, char** argv, char* const* environment) {
  try {
    telar::SystemAllocator memory;

    // main receives its arguments as the C array and count the C runtime gives it.
#pragma clang unsafe_buffer_usage begin
    const std::span<char*> input{argv, static_cast<std::size_t>(argc)};
#pragma clang unsafe_buffer_usage end

    return launch(memory, input, environment);
  } catch (const std::exception& error) {
    std::cerr << "Telar C++: " << error.what() << '\n';

    return EXIT_FAILURE;
  }
}
