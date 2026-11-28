module telar.runtime.terminal.shell_completion.remote;

import std;
import telar.sys.posix;
import telar.sys.socket;

import telar.wire.vocabulary;
import telar.base.text;
import telar.base.ds;

namespace telar::runtime::remote_completion {

  namespace scripts {

#include "shell_completion_scripts.inc"

  }

  namespace {

    constexpr std::string_view heredoc_end = "TELAR_EOF";

    // A heredoc ends at the first line that is its delimiter: no script may hold one.
    constexpr bool heredocSafe(std::string_view content) {
      for (std::size_t start = 0; start < content.size();) {
        const auto end = std::min(content.find('\n', start), content.size());
        if (content.substr(start, end - start) == heredoc_end) {
          return false;
        }

        start = end + 1;
      }

      return true;
    }

    static_assert(heredocSafe(scripts::zsh) && heredocSafe(scripts::bash) && heredocSafe(scripts::fish));

    // Counts the text it is given, or copies it too once it has storage, so that one pass sizes a
    // compile-time text and another fills it.
    struct Writer {
      std::span<char> output;
      std::size_t size = 0;

      constexpr void put(std::string_view text) {
        if (!output.empty()) {
          std::ranges::copy(text, output.subspan(size).begin());
        }

        size += text.size();
      }
    };

    // What the host runs: remote.sh, the shell's script as _telar_script, and the call.
    constexpr void writePayload(Writer& payload, std::string_view script) {
      payload.put(scripts::remote);
      if (!script.empty()) {
        payload.put("_telar_script=$(cat <<'");
        payload.put(heredoc_end);
        payload.put("'\n");
        payload.put(script);
        if (!script.ends_with('\n')) {
          payload.put("\n");
        }

        payload.put(heredoc_end);
        payload.put("\n)\n");
      }

      payload.put("_telar_complete \"$@\"\n");
    }

    consteval std::size_t payloadBytes(std::string_view script) {
      Writer payload;

      writePayload(payload, script);
      return payload.size;
    }

    // Every login shell parses the command alike (sh, bash, zsh, fish, csh): it starts /bin/sh
    // with one single-quoted argument holding no quote, backslash or `!`, which runs the payload
    // carried in base64. A host that cannot decode it answers nothing.
    constexpr std::string_view prefix = "exec /bin/sh -c 'p=";
    constexpr std::string_view suffix = R"(;{ s=$(printf %s "$p" | base64 -d 2>/dev/null) || s=$(printf %s "$p" | base64 -D 2>/dev/null); } && eval "$s"' telar)";

    template <std::size_t Bytes>
    consteval auto encodedCommand(std::string_view script) {
      constexpr std::size_t encoded_bytes = (Bytes + 2) / 3 * 4;
      ds::Array<char, Bytes> text{};
      ds::Array<std::uint8_t, Bytes> bytes{};
      ds::Array<char, prefix.size() + encoded_bytes + suffix.size()> command{};
      Writer payload{.output = text.viewMut()};

      writePayload(payload, script);
      std::ranges::transform(text.view(), bytes.viewMut().begin(), [](char byte) {
        return static_cast<std::uint8_t>(byte);
      });

      // One mutable borrow of the command: the prefix, the encoded payload and the suffix in turn.
      const auto output = command.viewMut();
      const auto encoded = output.subspan(prefix.size(), encoded_bytes);

      std::ranges::copy(prefix, output.begin());
      static_cast<void>(base64::encode(bytes.view(), encoded));
      std::ranges::copy(suffix, encoded.end());
      return command; // NOLINT(clang-diagnostic-nrvo): evaluated by the compiler, where a copy costs nothing at run time
    }

    constexpr auto listing_command = encodedCommand<payloadBytes({})>({});
    constexpr auto zsh_command = encodedCommand<payloadBytes(scripts::zsh)>(scripts::zsh);
    constexpr auto bash_command = encodedCommand<payloadBytes(scripts::bash)>(scripts::bash);
    constexpr auto fish_command = encodedCommand<payloadBytes(scripts::fish)>(scripts::fish);

    template <std::size_t Size>
    constexpr std::string_view textOf(const ds::Array<char, Size>& text) noexcept {
      return {text.data(), text.size()};
    }

  }

  std::string_view command(IntegratedShell shell) noexcept {
    switch (shell) {
    case IntegratedShell::zsh:
      return textOf(zsh_command);
    case IntegratedShell::bash:
      return textOf(bash_command);
    case IntegratedShell::fish:
      return textOf(fish_command);
    case IntegratedShell::none:
      break;
    }

    return textOf(listing_command);
  }

  std::string_view question(IntegratedShell shell) noexcept {
    switch (shell) {
    case IntegratedShell::zsh:
      return "zsh";
    case IntegratedShell::bash:
      return "bash";
    case IntegratedShell::fish:
      return "fish";
    case IntegratedShell::none:
      break;
    }

    return {};
  }

  bool acceptedControl(std::string_view socket, std::string_view private_directory) noexcept {
    ds::Array<char, sizeof(sockaddr_un::sun_path)> path{};
    const auto slash = socket.rfind('/');
    if (socket.size() >= path.size() || !socket.starts_with('/') || slash == 0 || socket.contains('\0')) {
      return false;
    }

    std::ranges::copy(socket, path.viewMut().begin());
    struct stat status{};

    if (::lstat(path.data(), &status) != 0 || !S_ISSOCK(status.st_mode) || status.st_uid != ::geteuid()) {
      return false;
    }

    // The private directory was made the runtime's alone when it started.
    if (!private_directory.empty() && std::string_view{socket.data(), slash} == private_directory) {
      return true;
    }

    constexpr mode_t group_or_others_write = 0022;

    path.atMut(slash) = '\0';
    return ::stat(path.data(), &status) == 0 && S_ISDIR(status.st_mode) && status.st_uid == ::geteuid() && (status.st_mode & group_or_others_write) == 0;
  }

}
