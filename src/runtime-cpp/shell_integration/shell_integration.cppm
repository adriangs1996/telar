module;
#include "shell_scripts.hpp"
#include <cerrno>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

export module telar.runtime.shell_integration;

import std;

export import telar.platform;
export import telar.runtime.shell_integration.token;
import telar.platform.primitives;
import telar.base.text;

namespace telar::runtime::shell_files {

struct ScriptFile {
  std::string_view directory;
  std::string_view name;
  std::string_view content;
};

// Each shell's scripts, installed here and sent to the hosts `ssh` reaches.
inline constexpr std::array<ScriptFile, 4> shells{{
    {"zsh", ".zshenv", shell_scripts::zsh_environment},
    {"zsh", "telar.zsh", shell_scripts::zsh},
    {"bash", "telar.bash", shell_scripts::bash},
    {"fish/fish/vendor_conf.d", "telar.fish", shell_scripts::fish},
}};

inline constexpr ScriptFile ssh{"ssh", "ssh.sh", shell_scripts::ssh};

// FNV-1a over every script's place and content, computed at compile time.
inline constexpr std::uint64_t digest = [] {
  std::uint64_t hash = 14695981039346656037ULL;
  const auto mix = [&](std::string_view part) {
    for (const auto byte : part) {
      hash = (hash ^ static_cast<unsigned char>(byte)) * 1099511628211ULL;
    }
  };
  for (const auto &file : shells) {
    mix(file.directory);
    mix(file.name);
    mix(file.content);
  }
  mix(ssh.content);
  mix(shell_scripts::remote);
  return hash;
}();

inline constexpr std::array<char, 16> digest_digits = [] {
  constexpr std::string_view digits = "0123456789abcdef";
  std::array<char, 16> text{};
  for (std::size_t index = 0; index < text.size(); ++index) {
    text[index] = digits[(digest >> (60 - 4 * index)) & 0x0f];
  }
  return text;
}();

inline constexpr std::string_view heredoc_end = "TELAR_EOF";

// A heredoc ends at the first line that is its delimiter: no script may hold one.
inline constexpr bool heredocSafe(std::string_view content) {
  for (std::size_t start = 0; start < content.size();) {
    const auto end = std::min(content.find('\n', start), content.size());
    if (content.substr(start, end - start) == heredoc_end) {
      return false;
    }
    start = end + 1;
  }
  return true;
}
static_assert(std::ranges::all_of(shells, [](const ScriptFile &file) { return heredocSafe(file.content); }));

// What a remote host runs: the bootstrap, then the calls that write each shell's scripts and
// start the login shell with them.
inline constexpr std::string remoteScript() {
  std::string script{shell_scripts::remote};
  script += "_telar_prepare ";
  script.append(digest_digits.data(), digest_digits.size());
  script += '\n';
  for (const auto &file : shells) {
    script += "_telar_put '";
    script += file.directory;
    script += "' '";
    script += file.name;
    script += "' <<'";
    script += heredoc_end;
    script += "'\n";
    script += file.content;
    if (!file.content.ends_with('\n')) {
      script += '\n';
    }
    script += heredoc_end;
    script += '\n';
  }
  script += "_telar_start \"$1\"\n";
  return script;
}

// The remote command `ssh` sends, the nonce left to append. Every login shell parses it alike
// (sh, bash, zsh, fish, csh): it starts /bin/sh with one single-quoted argument holding no
// quote, backslash or `!`, which runs the script carried in base64, and the login shell as
// usual when the host cannot decode it.
inline constexpr std::string remoteCommand() {
  const auto script = remoteScript();
  std::vector<std::uint8_t> bytes(script.size());
  std::ranges::transform(script, bytes.begin(), [](char byte) { return static_cast<std::uint8_t>(byte); });
  std::string encoded((bytes.size() + 2) / 3 * 4, '=');
  static_cast<void>(base64::encode(bytes, encoded));
  std::string command{"exec /bin/sh -c 'p="};
  command += encoded;
  command += ";{ s=$(printf %s \"$p\" | base64 -d 2>/dev/null) || s=$(printf %s \"$p\" | base64 -D); } && eval \"$s\" || exec \"${SHELL:-/bin/sh}\" -l' telar";
  return command;
}

inline constexpr auto remote_command = [] {
  std::array<char, remoteCommand().size()> text{};
  std::ranges::copy(remoteCommand(), text.begin());
  return text;
}();

// Everything the runtime installs. The last one is the sentinel: written last, so its presence
// means every one is there.
inline constexpr std::array<ScriptFile, 6> installed{{
    shells[0],
    shells[1],
    shells[2],
    shells[3],
    ssh,
    {"ssh", "remote", {remote_command.data(), remote_command.size()}},
}};

}

export namespace telar::runtime {

// The shell these arguments start interactively, when telar can integrate with it: a shell it
// knows, with no command, no script and no option but login and interactive. Anything else
// keeps the startup the user asked for.
template <std::ranges::input_range Arguments>
inline std::optional<IntegratedShell> integrableShell(const Arguments &arguments) noexcept {
  auto argument = std::ranges::begin(arguments);
  if (argument == std::ranges::end(arguments)) {
    return std::nullopt;
  }

  auto program = std::string_view{*argument};
  program = program.substr(program.rfind('/') + 1);
  std::optional<IntegratedShell> shell;
  if (program == "zsh") {
    shell = IntegratedShell::zsh;
  } else if (program == "bash") {
    shell = IntegratedShell::bash;
  } else if (program == "fish") {
    shell = IntegratedShell::fish;
  }

  for (++argument; shell && argument != std::ranges::end(arguments); ++argument) {
    const auto option = std::string_view{*argument};
    if (option != "-l" && option != "-i" && option != "-il" && option != "-li" && option != "--login") {
      return std::nullopt;
    }
  }
  return shell;
}

template <Allocator Memory>
class ShellIntegration {
public:
  // `directory` holds the installed scripts; an empty one turns the integration off. With
  // `ssh`, an integrated shell's `ssh` brings the integration to the hosts it reaches.
  inline ShellIntegration(Memory &memory, std::string_view directory, bool ssh = false)
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

  // Writes the scripts beneath `data_home` and returns their directory. It is named after
  // their content, so runtimes of different versions never overwrite each other's.
  inline static String<Memory> install(Memory &memory, std::string_view data_home) {
    String<Memory> directory{data_home, AllocatorRef<char, Memory>{memory}};
    directory += "/telar/shell-integration/";
    directory.append(shell_files::digest_digits.data(), shell_files::digest_digits.size());
    writeScripts(directory);
    return directory;
  }

  // Points an integrable shell at the scripts and returns the token its marks are signed
  // with. Leaves every other command untouched, and a shell too if the scripts are gone and
  // cannot be written again.
  inline std::optional<ShellLaunch> apply(Command<Memory> &command) const {
    for (const auto name : {"TELAR_SHELL_TOKEN", "TELAR_SHELL_SSH", "TELAR_ZSH_ZDOTDIR", "TELAR_BASH_LOGIN", "TELAR_FISH_XDG_DATA_DIRS"}) {
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
      if (std::ranges::any_of(command.arguments() | std::views::drop(1), [](std::string_view option) { return option == "-l" || option == "-il" || option == "-li" || option == "--login"; })) {
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

private:
  static constexpr const auto &files = shell_files::installed;

  // Writes the files that are missing. A file that exists is complete, since each one is
  // written to a temporary name and renamed into place.
  inline static void writeScripts(std::string_view root) {
    for (const auto &file : files) {
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

      const auto bytes = std::span{reinterpret_cast<const std::uint8_t *>(file.content.data()), file.content.size()};
      if (const int failure = writePrivateFile(directory.get(), file.name, bytes, PrivateFileMode::replace); failure != 0) {
        throw SystemError{"Write shell integration script", failure};
      }
    }
  }

  // Writes the scripts again if something removed them since the runtime started.
  inline bool present() const noexcept {
    if (::access(sentinel_.c_str(), R_OK) == 0) {
      return true;
    }

    try {
      writeScripts(directory_);
      return true;
    } catch (const SystemError &) {
      return false;
    }
  }

  String<Memory> directory_;
  String<Memory> sentinel_;
  String<Memory> ssh_;
  Memory &memory_;
};

}
