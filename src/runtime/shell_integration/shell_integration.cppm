module;
#include "tbc/annotations.hpp"

export module telar.runtime.shell_integration;

import std;

import telar.platform.process;
import telar.runtime.shell_integration.token;
import telar.platform.primitives;
import telar.base.text;
import telar.base.memory.allocators;
import telar.wire.vocabulary;

// The scripts of shell_integration/, which the build compiles in.
namespace telar::runtime::shell_scripts {

#include "shell_scripts.inc"

}

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
    std::uint64_t hash = fnv1a64_basis;
    const auto mix = [&](std::string_view part) {
      hash = fnv1a64(part, hash);
    };

    for (const auto& file : shells) {
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

  static_assert(std::ranges::all_of(shells, [](const ScriptFile& file) {
    return heredocSafe(file.content);
  }));

  // What a remote host runs: the bootstrap, then the calls that write each shell's scripts and
  // start the login shell with them.
  inline constexpr std::string remoteScript() {
    std::string script{shell_scripts::remote};

    script += "_telar_prepare ";
    script.append(digest_digits.data(), digest_digits.size());
    script += '\n';
    for (const auto& file : shells) {
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

    script += "_telar_start \"$1\" \"${2-}\"\n";
    return script;
  }

  // The remote command `ssh` sends, the nonce left to append. Every login shell parses it alike
  // (sh, bash, zsh, fish, csh): it starts /bin/sh with one single-quoted argument holding no
  // quote, backslash or `!`, which runs the script carried in base64, and the login shell as
  // usual when the host cannot decode it.
  inline constexpr std::string remoteCommand() {
    const auto script = remoteScript();
    std::vector<std::uint8_t> bytes(script.size());

    std::ranges::transform(script, bytes.begin(), [](char byte) {
      return static_cast<std::uint8_t>(byte);
    });

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

  // The shell `program` names, when telar can integrate with it.
  std::optional<IntegratedShell> integrableShellProgram(std::string_view program) noexcept;

  // Whether a shell started with `option` still runs interactively, as the integration needs.
  bool integrableShellOption(std::string_view option) noexcept;

  // The shell these arguments start interactively, when telar can integrate with it: a shell it
  // knows, with no command, no script and no option but login and interactive. Anything else
  // keeps the startup the user asked for. A template over the caller's argument range, so only
  // the walk stays here.
  template <std::ranges::input_range Arguments>
  TBC_GENERIC inline std::optional<IntegratedShell> integrableShell(const Arguments& arguments) noexcept {
    auto argument = std::ranges::begin(arguments);
    if (argument == std::ranges::end(arguments)) {
      return std::nullopt;
    }

    auto shell = integrableShellProgram(std::string_view{*argument});

    for (++argument; shell && argument != std::ranges::end(arguments); ++argument) {
      if (!integrableShellOption(std::string_view{*argument})) {
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
    ShellIntegration(Memory& memory, std::string_view directory, bool ssh = false);

    // Writes the scripts beneath `data_home` and returns their directory. It is named after
    // their content, so runtimes of different versions never overwrite each other's.
    static String<Memory> install(Memory& memory, std::string_view data_home);

    // Points an integrable shell at the scripts and returns the token its marks are signed
    // with. Leaves every other command untouched, and a shell too if the scripts are gone and
    // cannot be written again. `bare_prompt`: telar's editor stands in for the shell's prompt, so
    // the shell prints only its marks (TELAR_PROMPT_MODE=telar).
    std::optional<ShellLaunch> apply(Command<Memory>& command, bool bare_prompt = false) const;

  private:
    static constexpr const auto& files = shell_files::installed;

    // Writes the scripts again if something removed them since the runtime started.
    bool present() const noexcept;

    String<Memory> directory_;
    String<Memory> sentinel_;
    String<Memory> ssh_;
    Memory& memory_;
  };

  // The allocators Command is instantiated for, which the runtime's services and their tests
  // still start panes with.
  extern template class ShellIntegration<Memory>;
  extern template class ShellIntegration<ConcurrentMemory>;
  extern template class ShellIntegration<SystemAllocator>;
  extern template class ShellIntegration<BudgetAllocator<SystemAllocator>>;
  extern template class ShellIntegration<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

}
