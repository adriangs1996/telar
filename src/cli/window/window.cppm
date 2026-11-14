export module telar.cli.window;

import std;

export import telar.cli.output;

export import telar.cli.plugin;

export import telar.base.text.json;

import telar.base.diagnostics;
import telar.base.text.utf8;
import telar.cli.command_limit;
import telar.plugins;
import telar.wire.vocabulary;

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

    struct SetupReport {
      static constexpr std::size_t max_text_bytes = 512;
      static constexpr std::size_t max_notes = 96;
      static constexpr auto titles = std::to_array<const char*>({"SSH access", "Platform", "telar", "Runtime", "Profile", "Agents", "Integrations", "Configuration", "Logins", "Check"});
      static constexpr auto steps = std::to_array<const char*>({"ssh", "platform", "telar", "runtime", "profile", "agents", "integrations", "configuration", "logins", "check"});
      static constexpr auto statuses = std::to_array<const char*>({"ok", "changed", "skipped", "failed", "pending"});

      struct Result {
        std::optional<Status> status;
        std::string detail;
        std::vector<std::string> notes;
      };

      bool json;
      std::array<Result, static_cast<std::size_t>(Step::count)> results;
      std::size_t note_count = 0;
      std::size_t omitted_notes = 0;

      static std::string bounded(std::string text);

      void end(Step step, Status status, std::string detail);

      void note(Step step, std::string detail);

      void progress(const std::string& text) const;

      bool has(Status status) const;

      template <Allocator Memory>
      int refuse(Memory& memory, const std::string& label, const std::string& destination, std::string_view reason) const;

      template <Allocator Memory>
      int finish(Memory& memory, const std::string& label, const std::string& destination) const;
    };

    extern template int SetupReport::refuse<Memory>(Memory& memory, const std::string& label, const std::string& destination, std::string_view reason) const;
    extern template int SetupReport::finish<Memory>(Memory& memory, const std::string& label, const std::string& destination) const;

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
    template <Allocator Memory>
    void appendJson(String<Memory>& output, const JsonValue& value, bool pretty, unsigned depth = 0);
    extern template void appendJson<Memory>(String<Memory>& output, const JsonValue& value, bool pretty, unsigned depth);

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
