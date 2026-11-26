module;

export module telar.runtime.terminal.shell_integration;

import std;
import telar.tbc;

import telar.platform.process;
import telar.runtime.terminal.shell_integration.token;
import telar.base.text;
import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.base.ds;

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
  inline constexpr ds::Array<ScriptFile, 4> shells{
      {
          {.directory = "zsh", .name = ".zshenv", .content = shell_scripts::zsh_environment},
          {.directory = "zsh", .name = "telar.zsh", .content = shell_scripts::zsh},
          {.directory = "bash", .name = "telar.bash", .content = shell_scripts::bash},
          {.directory = "fish/fish/vendor_conf.d", .name = "telar.fish", .content = shell_scripts::fish},
      },
  };

  inline constexpr ScriptFile ssh{.directory = "ssh", .name = "ssh.sh", .content = shell_scripts::ssh};

  // FNV-1a over every script's place and content, computed at compile time.
  inline constexpr std::uint64_t digest = [] {
    std::uint64_t hash = fnv1a64_basis;

    for (const auto& file : shells) {
      hash = fnv1a64(file.directory, hash);
      hash = fnv1a64(file.name, hash);
      hash = fnv1a64(file.content, hash);
    }

    hash = fnv1a64(ssh.content, hash);
    return fnv1a64(shell_scripts::remote, hash);
  }();

  inline constexpr ds::Array<char, 16> digest_digits = [] {
    constexpr std::string_view digits = "0123456789abcdef";
    constexpr std::size_t digit_bits = 4;
    constexpr std::size_t last_digit_shift = 60;
    constexpr std::uint64_t digit_mask = 0x0F;
    ds::Array<char, 16> text{};

    for (std::size_t index = 0; index < text.size(); ++index) {
      text.atMut(index) = digits[(digest >> (last_digit_shift - (digit_bits * index))) & digit_mask];
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

  // Counts the text it is given, or copies it too once it has storage, so that one pass sizes a
  // compile-time text and another fills it.
  struct ScriptWriter {
    std::span<char> output;
    std::size_t size = 0;

    constexpr void put(std::string_view text) {
      if (!output.empty()) {
        std::ranges::copy(text, output.subspan(size).begin());
      }

      size += text.size();
    }
  };

  // What a remote host runs: the bootstrap, then the calls that write each shell's scripts and
  // start the login shell with them.
  constexpr void writeRemoteScript(ScriptWriter& script) {
    script.put(shell_scripts::remote);
    script.put("_telar_prepare ");
    script.put({digest_digits.data(), digest_digits.size()});
    script.put("\n");
    for (const auto& file : shells) {
      script.put("_telar_put '");
      script.put(file.directory);
      script.put("' '");
      script.put(file.name);
      script.put("' <<'");
      script.put(heredoc_end);
      script.put("'\n");
      script.put(file.content);
      if (!file.content.ends_with('\n')) {
        script.put("\n");
      }

      script.put(heredoc_end);
      script.put("\n");
    }

    script.put("_telar_start \"$1\" \"${2-}\"\n");
  }

  consteval std::size_t remoteScriptBytes() {
    ScriptWriter script;

    writeRemoteScript(script);
    return script.size;
  }

  inline constexpr auto remote_script = [] {
    ds::Array<std::uint8_t, remoteScriptBytes()> bytes{};
    ds::Array<char, remoteScriptBytes()> text{};
    ScriptWriter script{.output = text.viewMut()};

    writeRemoteScript(script);
    std::ranges::transform(text.view(), bytes.viewMut().begin(), [](char byte) {
      return static_cast<std::uint8_t>(byte);
    });

    return bytes;
  }();

  // The remote command `ssh` sends, the nonce left to append. Every login shell parses it alike
  // (sh, bash, zsh, fish, csh): it starts /bin/sh with one single-quoted argument holding no
  // quote, backslash or `!`, which runs the script carried in base64, and the login shell as
  // usual when the host cannot decode it.
  inline constexpr std::string_view remote_command_prefix = "exec /bin/sh -c 'p=";
  inline constexpr std::string_view remote_command_suffix = R"(;{ s=$(printf %s "$p" | base64 -d 2>/dev/null) || s=$(printf %s "$p" | base64 -D); } && eval "$s" || exec "${SHELL:-/bin/sh}" -l' telar)";
  inline constexpr std::size_t remote_script_encoded_bytes = (remote_script.size() + 2) / 3 * 4;

  inline constexpr auto remote_command = [] {
    ds::Array<char, remote_command_prefix.size() + remote_script_encoded_bytes + remote_command_suffix.size()> text{};
    // One mutable borrow of the text: the prefix, the encoded script and the suffix in turn.
    const auto output = text.viewMut();
    const auto encoded = output.subspan(remote_command_prefix.size(), remote_script_encoded_bytes);

    std::ranges::copy(remote_command_prefix, output.begin());
    static_cast<void>(base64::encode(remote_script.view(), encoded));
    std::ranges::copy(remote_command_suffix, encoded.end());
    return text;
  }();

  // Everything the runtime installs. The last one is the sentinel: written last, so its presence
  // means every one is there.
  inline constexpr ds::Array<ScriptFile, 6> installed{
      {
          shells[0],
          shells[1],
          shells[2],
          shells[3],
          ssh,
          {.directory = "ssh", .name = "remote", .content = {remote_command.data(), remote_command.size()}},
      },
  };

}

export namespace telar::runtime {

  // The shell `program` names, when telar can integrate with it.
  ds::Option<IntegratedShell> integrableShellProgram(std::string_view program) noexcept;

  // Whether a shell started with `option` still runs interactively, as the integration needs.
  bool integrableShellOption(std::string_view option) noexcept;

  // The shell these arguments start interactively, when telar can integrate with it: a shell it
  // knows, with no command, no script and no option but login and interactive. Anything else
  // keeps the startup the user asked for. A template over the caller's argument range, so only
  // the walk stays here.
  template <std::ranges::input_range Arguments>
  [[tbc::generic]] inline ds::Option<IntegratedShell> integrableShell(const Arguments& arguments) noexcept {
    auto argument = std::ranges::begin(arguments);
    if (argument == std::ranges::end(arguments)) {
      return ds::none;
    }

    auto shell = integrableShellProgram(std::string_view{*argument});

    for (++argument; shell && argument != std::ranges::end(arguments); ++argument) {
      if (!integrableShellOption(std::string_view{*argument})) {
        return ds::none;
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
    static tbc::val_a<ds::String<Memory>> install(tbc::mut_a<Memory> memory, std::string_view data_home);

    // Points an integrable shell at the scripts and returns the token its marks are signed
    // with. Leaves every other command untouched, and a shell too if the scripts are gone and
    // cannot be written again. `bare_prompt`: telar's editor stands in for the shell's prompt, so
    // the shell prints only its marks (TELAR_PROMPT_MODE=telar).
    ds::Option<ShellLaunch> apply(Command<Memory>& command, bool bare_prompt = false) const;

  private:
    static constexpr const auto& files = shell_files::installed;

    // Writes the scripts again if something removed them since the runtime started.
    [[nodiscard]] bool present() const noexcept;

    ds::String<Memory> directory_;
    ds::String<Memory> sentinel_;
    ds::String<Memory> ssh_;
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
