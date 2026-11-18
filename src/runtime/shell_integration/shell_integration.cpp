module telar.runtime.shell_integration;

import telar.tbc;
import std;
import telar.sys.posix;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // Writes the files that are missing. A file that exists is complete, since each one is
    // written to a temporary name and renamed into place.
    void writeScripts(std::string_view root) {
      for (const auto& file : shell_files::installed) {
        ds::Array<char, PATH_MAX> path{};
        const auto length = root.size() + 1 + file.directory.size();
        if (length >= path.size()) {
          throw SystemError{"Shell integration path is too long", ENAMETOOLONG};
        }

        std::ranges::copy(root, path.viewMut().begin());
        path.atMut(root.size()) = '/';
        std::ranges::copy(file.directory, path.viewMut().begin() + root.size() + 1);
        createPrivateDirectory({path.data(), length});

        FileDescriptor directory{::open(path.data(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
        if (!directory) {
          throw SystemError{"Open shell integration directory"};
        }

        ds::Array<char, NAME_MAX + 1> name{};

        std::ranges::copy(file.name, name.viewMut().begin());
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

  ds::Option<IntegratedShell> integrableShellProgram(std::string_view program) noexcept {
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

    return ds::none;
  }

  bool integrableShellOption(std::string_view option) noexcept {
    return option == "-l" || option == "-i" || option == "-il" || option == "-li" || option == "--login";
  }

  template <Allocator Memory>
  ShellIntegration<Memory>::ShellIntegration(Memory& memory, std::string_view directory, bool ssh)
      : directory_(memory, directory),
        sentinel_(memory),
        ssh_(memory),
        memory_(memory) {
    if (!directory_.empty()) {
      sentinel_.assign(directory_);
      sentinel_.push('/');
      sentinel_.append(files.back().directory);
      sentinel_.push('/');
      sentinel_.append(files.back().name);
    }

    if (!directory_.empty() && ssh) {
      ssh_.assign(directory_);
      ssh_.push('/');
      ssh_.append(shell_files::ssh.directory);
      ssh_.push('/');
      ssh_.append(shell_files::ssh.name);
    }
  }

  template <Allocator Memory>
  tbc::view<ds::String<Memory>, tbc::lt::a> ShellIntegration<Memory>::install(tbc::view<Memory&, tbc::lt::a> memory, std::string_view data_home) {
    ds::String<Memory> directory{memory, data_home};

    directory.append("/telar/shell-integration/");
    directory.append(std::string_view{shell_files::digest_digits.data(), shell_files::digest_digits.size()});
    writeScripts(directory);
    return directory;
  }

  template <Allocator Memory>
  ds::Option<ShellLaunch> ShellIntegration<Memory>::apply(Command<Memory>& command, bool bare_prompt) const {
    for (const auto name : {"TELAR_SHELL_TOKEN", "TELAR_SHELL_SSH", "TELAR_PROMPT_MODE", "TELAR_ZSH_ZDOTDIR", "TELAR_BASH_LOGIN", "TELAR_FISH_XDG_DATA_DIRS"}) {
      command.removeEnvironment(name);
    }

    const auto shell = integrableShell(command.arguments());
    if (directory_.empty() || !shell || !present()) {
      return ds::none;
    }

    const auto token = ShellToken::generate();

    command.setEnvironment("TELAR_SHELL_TOKEN", token.text());
    if (!ssh_.empty()) {
      command.setEnvironment("TELAR_SHELL_SSH", ssh_);
    }

    if (bare_prompt) {
      command.setEnvironment("TELAR_PROMPT_MODE", "telar");
    }

    ds::String<Memory> path{memory_, directory_};

    switch (*shell) {
    case IntegratedShell::none:
      break;
    case IntegratedShell::zsh:
      // Copy before setting: setting a variable can move the one a view points into.
      if (const auto previous = command.environment("ZDOTDIR")) {
        const ds::String<Memory> saved{memory_, *previous};

        command.setEnvironment("TELAR_ZSH_ZDOTDIR", saved);
      }

      path.append("/zsh");
      command.setEnvironment("ZDOTDIR", path);
      break;
    case IntegratedShell::bash: {
      // A login shell ignores --rcfile, so the script reads the login files itself.
      if (std::ranges::any_of(command.arguments() | std::views::drop(1), [](std::string_view option) {
            return option == "-l" || option == "-il" || option == "-li" || option == "--login";
          })) {
        command.setEnvironment("TELAR_BASH_LOGIN", "1");
      }

      path.append("/bash/telar.bash");
      const ds::Array<std::string_view, 3> arguments{"--rcfile", path, "-i"};

      command.replaceSpawnArguments(arguments);
      break;
    }
    case IntegratedShell::fish: {
      // XDG's default when the variable is unset, so fish keeps finding the system's files.
      ds::String<Memory> saved{memory_, "/usr/local/share:/usr/share"};
      const auto previous = command.environment("XDG_DATA_DIRS");
      if (previous) {
        saved.assign(*previous);
      }

      path.append("/fish:");
      path.append(saved);
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
    if (::access(sentinel_.data(), R_OK) == 0) {
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
