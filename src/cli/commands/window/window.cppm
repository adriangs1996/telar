module;
#include "tbc/annotations.hpp"

export module telar.cli.commands.window;

import std;

import telar.cli.console.output;

import telar.cli.commands.plugin;

import telar.base.text.json;

import telar.plugins;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;

// Interface: machines/setup_report.cppm
export {
  namespace telar::runtime::cli::machine {

    enum class Step : std::uint8_t {
      gateway,
      platform,
      telar,
      runtime,
      profile,
      agents,
      integrations,
      configuration,
      logins,
      check,
      count,
    };
    enum class Status : std::uint8_t {
      ok,
      changed,
      skipped,
      failed,
      pending,
    };

    // The machine a setup report speaks of: the name it goes by and where it is reached.
    struct SetupTarget {
      std::string_view label;
      std::string_view destination;
    };

    // What a machine setup did, step by step, with notes, for a person or as JSON. Remote hosts
    // supply much of its text: each line reaches the terminal without its control bytes, trimmed,
    // and cut at max_text_bytes.
    struct SetupReport {
      static constexpr std::size_t max_text_bytes = 512;
      static constexpr std::size_t max_notes = 96;
      static constexpr auto titles = ds::Array<const char*, 10>{"SSH access", "Platform", "telar", "Runtime", "Profile", "Agents", "Integrations", "Configuration", "Logins", "Check"};
      static constexpr auto steps = ds::Array<const char*, 10>{"gateway", "platform", "telar", "runtime", "profile", "agents", "integrations", "configuration", "logins", "check"};
      static constexpr auto statuses = ds::Array<const char*, 5>{"ok", "changed", "skipped", "failed", "pending"};

      using Line = FixedText<max_text_bytes>;

      struct Result {
        ds::Option<Status> status;
        Line detail;
      };

      struct Note {
        Step step;
        Line text;
      };

      SetupReport(Memory& memory, bool json_output);

      bool json;
      ds::Array<Result, static_cast<std::size_t>(Step::count)> results{};
      ds::Vec<Note, Memory> notes;
      std::size_t omitted_notes = 0;

      static Line bounded(std::string_view text);

      template <typename... Arguments>
      TBC_GENERIC void end(Step step, Status status, std::format_string<Arguments...> format, Arguments&&... arguments) {
        endLine(step, status, formatted(format, std::forward<Arguments>(arguments)...));
      }

      template <typename... Arguments>
      TBC_GENERIC void note(Step step, std::format_string<Arguments...> format, Arguments&&... arguments) {
        noteLine(step, formatted(format, std::forward<Arguments>(arguments)...));
      }

      template <typename... Arguments>
      TBC_GENERIC void progress(std::format_string<Arguments...> format, Arguments&&... arguments) const {
        progressLine(formatted(format, std::forward<Arguments>(arguments)...));
      }

      [[nodiscard]] bool has(Status status) const;

      int refuse(Memory& memory, SetupTarget target, std::string_view reason) const;

      int finish(Memory& memory, SetupTarget target) const;

    private:
      template <typename... Arguments>
      TBC_GENERIC static Line formatted(std::format_string<Arguments...> format, Arguments&&... arguments) {
        ds::Array<char, max_text_bytes> buffer{};
        const auto written = std::format_to_n(buffer.dataMut(), buffer.size(), format, std::forward<Arguments>(arguments)...);

        return bounded({buffer.data(), std::min(static_cast<std::size_t>(written.size), buffer.size())});
      }

      void endLine(Step step, Status status, const Line& detail);

      void noteLine(Step step, const Line& text);

      void progressLine(const Line& text) const;

      void printNotes(Step step) const;
    };

  }
}

// Interface: window.cppm
export {
  namespace telar::runtime::cli {

    int runWindow(Family family, std::span<char* const> words);

    // Sends one window command to the client it names.
    int runRouted(const RoutedOptions& options);

  }
}

// Interface: window_json.cppm
export {
  namespace telar::runtime::cli::window {

    // Re-encode parsed JSON with the standard string escapes and two-space indentation.
    void appendJson(ds::String<Memory>& output, const JsonValue& value, bool pretty, unsigned depth = 0);

  }
}

// Interface: window_options.cppm
export {
  namespace telar::runtime::cli::window {

    struct ClientOptions {
      enum class Action : std::uint8_t {
        list,
        get,
        detach,
      };
      Action action = Action::list;
      std::uint64_t target = 0;
      bool json = false;
      const char* socket = nullptr;

      static ClientOptions parse(std::span<char* const> words);
    };

    struct SuggestionOptions {
      std::uint64_t pane = 0;
      bool current = false;
      std::string_view text;
      bool json = false;
      const char* socket = nullptr;

      static SuggestionOptions parse(std::span<char* const> words);
    };

  }

  namespace telar::runtime::cli::window {

    struct NotificationOptions {
      NotificationBody notification;
      const char* socket = nullptr;

      static NotificationOptions parse(std::span<char* const> words);
    };

    struct ConfigCheckOptions {
      const char* path = nullptr;
      std::string_view profile;

      static ConfigCheckOptions parse(std::span<char* const> words);
    };

  }
}
