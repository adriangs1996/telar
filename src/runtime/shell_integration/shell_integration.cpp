module telar.runtime.shell_integration;

import std;
import telar.sys.posix;
import telar.platform.error;
import telar.platform.fs;

namespace telar::runtime {

  namespace {

    // Writes the files that are missing. A file that exists is complete, since each one is
    // written to a temporary name and renamed into place.
    void writeScripts(std::string_view root) {
      for (const auto& file : shell_files::installed) {
        std::array<char, PATH_MAX> path{};
        const auto length = root.size() + 1 + file.directory.size();
        if (length >= path.size()) {
          throw SystemError{"Shell integration path is too long", ENAMETOOLONG};
        }

        std::ranges::copy(root, path.begin());
        path[root.size()] = '/';
        std::ranges::copy(file.directory, path.begin() + root.size() + 1);
        createPrivateDirectory({path.data(), length});

        FileDescriptor directory{::open(path.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
        if (!directory) {
          throw SystemError{"Open shell integration directory"};
        }

        std::array<char, NAME_MAX + 1> name{};

        std::ranges::copy(file.name, name.begin());
        struct stat state{};
        if (::fstatat(directory.get(), name.data(), &state, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(state.st_mode)) {
          continue;
        }

        const auto bytes = std::span{reinterpret_cast<const std::uint8_t*>(file.content.data()), file.content.size()};
        if (const int failure = writePrivateFile(directory.get(), file.name, bytes, PrivateFileMode::replace); failure != 0) {
          throw SystemError{"Write shell integration script", failure};
        }
      }
    }

  }

  std::optional<IntegratedShell> integrableShellProgram(std::string_view program) noexcept {
    program = program.substr(program.rfind('/') + 1);
    if (program == "zsh") {
      return IntegratedShell::zsh;
    }

    if (program == "bash") {
      return IntegratedShell::bash;
    }

    if (program == "fish") {
      return IntegratedShell::fish;
    }

    return std::nullopt;
  }

  bool integrableShellOption(std::string_view option) noexcept {
    return option == "-l" || option == "-i" || option == "-il" || option == "-li" || option == "--login";
  }

  template <Allocator Memory>
  ShellIntegration<Memory>::ShellIntegration(Memory& memory, std::string_view directory, bool ssh)
      : directory_(directory, AllocatorRef<char, Memory>{memory}),
        sentinel_(AllocatorRef<char, Memory>{memory}),
        ssh_(AllocatorRef<char, Memory>{memory}),
        memory_(memory) {
    if (!directory_.empty()) {
      sentinel_.assign(directory_);
      sentinel_ += '/';
      sentinel_ += files.back().directory;
      sentinel_ += '/';
      sentinel_ += files.back().name;
    }

    if (!directory_.empty() && ssh) {
      ssh_.assign(directory_);
      ssh_ += '/';
      ssh_ += shell_files::ssh.directory;
      ssh_ += '/';
      ssh_ += shell_files::ssh.name;
    }
  }

  template <Allocator Memory>
  String<Memory> ShellIntegration<Memory>::install(Memory& memory, std::string_view data_home) {
    String<Memory> directory{data_home, AllocatorRef<char, Memory>{memory}};

    directory += "/telar/shell-integration/";
    directory.append(shell_files::digest_digits.data(), shell_files::digest_digits.size());
    writeScripts(directory);
    return directory;
  }

  template <Allocator Memory>
  std::optional<ShellLaunch> ShellIntegration<Memory>::apply(Command<Memory>& command, bool bare_prompt) const {
    for (const auto name : {"TELAR_SHELL_TOKEN", "TELAR_SHELL_SSH", "TELAR_PROMPT_MODE", "TELAR_ZSH_ZDOTDIR", "TELAR_BASH_LOGIN", "TELAR_FISH_XDG_DATA_DIRS"}) {
      command.removeEnvironment(name);
    }

    const auto shell = integrableShell(command.arguments());
    if (directory_.empty() || !shell || !present()) {
      return std::nullopt;
    }

    const auto token = ShellToken::generate();

    command.setEnvironment("TELAR_SHELL_TOKEN", token.text());
    if (!ssh_.empty()) {
      command.setEnvironment("TELAR_SHELL_SSH", ssh_);
    }

    if (bare_prompt) {
      command.setEnvironment("TELAR_PROMPT_MODE", "telar");
    }

    String<Memory> path{directory_, AllocatorRef<char, Memory>{memory_}};

    switch (*shell) {
    case IntegratedShell::none:
      break;
    case IntegratedShell::zsh:
      // Copy before setting: setting a variable can move the one a view points into.
      if (const auto previous = command.environment("ZDOTDIR")) {
        const String<Memory> saved{*previous, AllocatorRef<char, Memory>{memory_}};

        command.setEnvironment("TELAR_ZSH_ZDOTDIR", saved);
      }

      path += "/zsh";
      command.setEnvironment("ZDOTDIR", path);
      break;
    case IntegratedShell::bash: {
      // A login shell ignores --rcfile, so the script reads the login files itself.
      if (std::ranges::any_of(command.arguments() | std::views::drop(1), [](std::string_view option) {
            return option == "-l" || option == "-il" || option == "-li" || option == "--login";
          })) {
        command.setEnvironment("TELAR_BASH_LOGIN", "1");
      }

      path += "/bash/telar.bash";
      const std::array<std::string_view, 3> arguments{"--rcfile", path, "-i"};

      command.replaceSpawnArguments(arguments);
      break;
    }
    case IntegratedShell::fish: {
      // XDG's default when the variable is unset, so fish keeps finding the system's files.
      String<Memory> saved{"/usr/local/share:/usr/share", AllocatorRef<char, Memory>{memory_}};
      const auto previous = command.environment("XDG_DATA_DIRS");
      if (previous) {
        saved.assign(*previous);
      }

      path += "/fish:";
      path += saved;
      if (previous) {
        command.setEnvironment("TELAR_FISH_XDG_DATA_DIRS", saved);
      }

      command.setEnvironment("XDG_DATA_DIRS", path);
      break;
    }
    }

    return ShellLaunch{*shell, token};
  }

  template <Allocator Memory>
  bool ShellIntegration<Memory>::present() const noexcept {
    if (::access(sentinel_.c_str(), R_OK) == 0) {
      return true;
    }

    try {
      writeScripts(directory_);
      return true;
    } catch (const SystemError&) {
      return false;
    }
  }

  template class ShellIntegration<Memory>;
  template class ShellIntegration<ConcurrentMemory>;
  template class ShellIntegration<SystemAllocator>;
  template class ShellIntegration<BudgetAllocator<SystemAllocator>>;
  template class ShellIntegration<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

}
