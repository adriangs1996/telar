export module telar.cli.window;

import std;

import telar.cli.output;

import telar.cli.plugin;

import telar.base.text.json;

import telar.plugins;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;

// Interface: machines/setup_report.cppm
export {
  namespace telar::runtime::cli::machine {

    enum class Step {
      ssh,
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
    enum class Status {
      ok,
      changed,
      skipped,
      failed,
      pending,
    };

    // What a machine setup did, step by step, with notes, for a person or as JSON. Remote hosts
    // supply much of its text: each line reaches the terminal without its control bytes, trimmed,
    // and cut at max_text_bytes.
    struct SetupReport {
      static constexpr std::size_t max_text_bytes = 512;
      static constexpr std::size_t max_notes = 96;
      static constexpr auto titles = ds::Array<const char*, 10>{"SSH access", "Platform", "telar", "Runtime", "Profile", "Agents", "Integrations", "Configuration", "Logins", "Check"};
      static constexpr auto steps = ds::Array<const char*, 10>{"ssh", "platform", "telar", "runtime", "profile", "agents", "integrations", "configuration", "logins", "check"};
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

      SetupReport(Memory& memory, bool json);

      bool json;
      ds::Array<Result, static_cast<std::size_t>(Step::count)> results{};
      ds::Vec<Note, Memory> notes;
      std::size_t omitted_notes = 0;

      static Line bounded(std::string_view text);

      template <typename... Arguments>
      void end(Step step, Status status, std::format_string<Arguments...> format, Arguments&&... arguments) {
        endLine(step, status, formatted(format, std::forward<Arguments>(arguments)...));
      }

      template <typename... Arguments>
      void note(Step step, std::format_string<Arguments...> format, Arguments&&... arguments) {
        noteLine(step, formatted(format, std::forward<Arguments>(arguments)...));
      }

      template <typename... Arguments>
      void progress(std::format_string<Arguments...> format, Arguments&&... arguments) const {
        progressLine(formatted(format, std::forward<Arguments>(arguments)...));
      }

      bool has(Status status) const;

      int refuse(Memory& memory, std::string_view label, std::string_view destination, std::string_view reason) const;

      int finish(Memory& memory, std::string_view label, std::string_view destination) const;

    private:
      template <typename... Arguments>
      static Line formatted(std::format_string<Arguments...> format, Arguments&&... arguments) {
        ds::Array<char, max_text_bytes> buffer;
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
      enum class Action {
        list,
        get,
        detach,
      };
      Action action;
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
