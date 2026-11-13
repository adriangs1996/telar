module;
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <new>

#include <cstdint>

#include <cstdio>

export module telar.cli.output;

import std;

import telar.base.diagnostics;
import telar.base.memory;
import telar.base.text;
import telar.vocabulary;

// Interface: failure.cppm
export {
  namespace telar::runtime::cli {

    // A command that failed after its arguments parsed: `what()` is the text after
    // the family's prefix on stderr, `status` the exit status (2 for a missing
    // target, 3 for a timeout), and `code` the runtime's refusal, if any.
    class Failure : public std::runtime_error {
    public:
      inline explicit Failure(std::string_view message, int status = 1, std::optional<FailureCode> code = std::nullopt)
          : std::runtime_error{std::string{message}},
            status_(status),
            code_(code) {}

      [[nodiscard]] inline int status() const noexcept {
        return status_;
      }

      [[nodiscard]] inline std::optional<FailureCode> code() const noexcept {
        return code_;
      }

    private:
      int status_;
      std::optional<FailureCode> code_;
    };

  }
}

// Interface: family.cppm
export {
  namespace telar::runtime::cli {

    // The first word of a command line that names a group of commands, as `worktree`
    // in `telar worktree create`. A word that is no family is a program to run in a
    // pane of a window.
    enum class Family : std::uint8_t {
      workspace,
      tab,
      pane,
      worktree,
      agent,
      exec,
      repository,
      project,
      file,
      machine,
      client,
      sidebar,
      workspace_list,
      layout,
      notification,
      command,
      config,
      completions,
      plugin,
      integration,
      hook,
      cli,
      gui,
      server,
      runtime,
      diagnostics,
      history,
      proxy,
      api,
      clipboard,
      render,
      count,
    };

    // Each family as it is typed, in the order of `Family`.
    inline constexpr std::array<std::string_view, static_cast<std::size_t>(Family::count)> family_names{
        "workspace",
        "tab",
        "pane",
        "worktree",
        "agent",
        "exec",
        "repository",
        "project",
        "file",
        "machine",
        "client",
        "sidebar",
        "workspace-list",
        "layout",
        "notification",
        "command",
        "config",
        "completions",
        "plugin",
        "integration",
        "hook",
        "cli",
        "gui",
        "server",
        "runtime",
        "diagnostics",
        "history",
        "proxy",
        "api",
        "clipboard",
        "render"
    };

    inline std::string_view familyName(Family family) noexcept {
      return family_names.at(static_cast<std::size_t>(family));
    }

    inline std::optional<Family> parseFamily(std::string_view word) noexcept {
      for (std::size_t index = 0; index < family_names.size(); ++index) {
        if (family_names.at(index) == word) {
          return static_cast<Family>(index);
        }
      }

      return std::nullopt;
    }

  }
}

// Interface: output.cppm
export {
  namespace telar::runtime::cli {

    // A command's stdout, built in memory and written once, so a failure halfway
    // prints nothing of the result.
    template <Allocator Memory>
    class Output {
    public:
      inline explicit Output(Memory& memory)
          : data(AllocatorRef<char, Memory>{memory}) {}

      inline Output& text(std::string_view value) {
        data.append(value);
        return *this;
      }

      template <typename Integer>
      inline Output& number(Integer value) {
        std::array<char, 32> buffer;
        const auto end = std::to_chars(buffer.data(), buffer.data() + buffer.size(), value).ptr;

        data.append(buffer.data(), end);
        return *this;
      }

      inline Output& boolean(bool value) {
        return text(value ? "true" : "false");
      }

      inline Output& json(std::string_view value, JsonEscapes escapes = JsonEscapes::standard) {
        appendJsonText(data, value, escapes);
        return *this;
      }

      inline void flush() {
        std::fwrite(data.data(), 1, data.size(), stdout);
        std::fflush(stdout);
        data.clear();
      }

      String<Memory> data;
    };

  }
}
