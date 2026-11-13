module;
#include "tbc/view.hpp"
#include <cinttypes>
#include <cstdio>

#include "telar_config/graphics/limits.hpp"

export module telar.config.core;

import std;
export import telar.lua;
export import telar.platform;
import telar.base.diagnostics;
import telar.wire.vocabulary;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::runtime {
  using telar::runtime::GraphicsLimits;
}

// Interface: telar_config/limit_notices.cppm
export {
  namespace telar::runtime::config {

    // The notices view the names of the limits they are told about, usually literals, in region `a`.
    class LimitNotices {
    public:
      inline void add(tbc::view<const LimitReach&, tbc::lt::a> reach) noexcept {
        for (auto& entry : std::span{entries_}.first(count_)) {
          if (entry.name == reach.name) {
            if (reach.requested) {
              entry.requested = std::max(entry.requested.value_or(0), *reach.requested);
            }

            return;
          }
        }

        if (count_ == entries_.size()) {
          return;
        }

        entries_[count_++] = reach;
      }

      inline std::span<const LimitReach> entries() const noexcept {
        return std::span{entries_}.first(count_);
      }

      inline void print() const noexcept {
        for (const auto& entry : entries()) {
          std::fprintf(stderr, "telar config: limit reached, the excess was left out: %.*s: ", static_cast<int>(entry.name.size()), entry.name.data());
          const auto* separator = entry.noun.empty() ? "" : " ";

          if (entry.requested) {
            std::fprintf(stderr, "%" PRIu64 "%s%.*s; limit %" PRIu64 "\n", *entry.requested, separator, static_cast<int>(entry.noun.size()), entry.noun.data(), entry.value);
          } else if (entry.value == 0) {
            std::fputs("limit reached\n", stderr);
          } else {
            std::fprintf(stderr, "limit %" PRIu64 "%s%.*s reached\n", entry.value, separator, static_cast<int>(entry.noun.size()), entry.noun.data());
          }
        }
      }

    private:
      tbc::view<std::array<LimitReach, 16>, tbc::lt::a> entries_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: telar_config/value_constraints.cppm
export {
  namespace telar::runtime::config {

    inline void optionalChoice(const lua::Value& value, std::initializer_list<std::string_view> choices) {
      if (!value.present()) {
        return;
      }

      const auto text = value.string();
      if (std::find(choices.begin(), choices.end(), text) == choices.end()) {
        value.fail("is not a supported value");
      }
    }

    inline void optionalWholeNumber(const lua::Value& value, double minimum, double maximum) {
      const auto number = value.boundedNumber(minimum, minimum, maximum);
      if (std::trunc(number) != number) {
        value.fail("must be a whole number");
      }
    }

    inline void optionalUtf8Text(const lua::Value& value, std::size_t maximum_bytes) {
      if (!value.present()) {
        return;
      }

      const auto text = value.string();

      validateUtf8(text);
      if (text.size() > maximum_bytes || text.contains('\0')) {
        value.fail("exceeds its text bounds or contains NUL");
      }
    }

    template <typename Number>
    struct Bounds {
      Number minimum;
      Number maximum;
    };

    // The value of `name` in `names` as an enum whose values follow the table.
    template <typename Enum, std::size_t Count>
    [[nodiscard]] inline std::optional<Enum> optionalChoice(const lua::Value& value, const std::array<std::string_view, Count>& names) {
      if (!value.present()) {
        return std::nullopt;
      }

      const auto found = std::ranges::find(names, value.string());
      if (found == names.end()) {
        value.fail("is not a supported value");
      }

      return static_cast<Enum>(found - names.begin());
    }

    [[nodiscard]] inline std::optional<double> optionalNumber(const lua::Value& value, Bounds<double> bounds) {
      return value.present() ? std::optional{value.boundedNumber(bounds.minimum, bounds.minimum, bounds.maximum)} : std::nullopt;
    }

    template <typename Integer>
    [[nodiscard]] inline std::optional<Integer> optionalWhole(const lua::Value& value, Bounds<double> bounds) {
      optionalWholeNumber(value, bounds.minimum, bounds.maximum);
      return value.present() ? std::optional{static_cast<Integer>(value.boundedNumber(bounds.minimum, bounds.minimum, bounds.maximum))} : std::nullopt;
    }

    [[nodiscard]] inline std::optional<bool> optionalBoolean(const lua::Value& value) {
      return value.present() ? std::optional{value.boolean(false)} : std::nullopt;
    }

  }
}

// Interface: telar_config/ui_value_constraints.cppm
export {
  namespace telar::runtime::config {

    inline void printableUiText(const lua::Value& source, std::string_view text, bool allow_tab = false) {
      validateUtf8(text);
      if (std::ranges::any_of(text, [allow_tab](unsigned char byte) {
            return (byte < 0x20 && !(allow_tab && byte == '\t')) || byte == 0x7f;
          })) {
        source.fail("must contain printable text");
      }
    }

    inline tbc::view<std::string_view, tbc::lt::a> fittedUiText(tbc::view<std::string_view, tbc::lt::a> text, tbc::view<LimitReach, tbc::lt::b> reach, tbc::view<LimitNotices&, tbc::lt::b> limits) {
      if (text.size() > reach.value) {
        reach.requested = text.size();
        limits.add(reach);
      }

      return utf8Prefix(text, reach.value);
    }

    inline bool equalUiName(std::string_view left, std::string_view right) noexcept {
      return left.size() == right.size() && std::equal(left.begin(), left.end(), right.begin(), [](char byte, char expected) {
        return (byte == '-' ? '_' : asciiLower(byte)) == expected;
      });
    }

    inline void uiIcon(const lua::Value& value) {
      constexpr std::string_view names[]{"sidebar_collapse", "sidebar_expand", "workspace_menu", "proxy_active", "cpu", "memory", "battery_empty", "battery_quarter", "battery_half", "battery_three_quarters", "battery_full", "provider_unknown", "provider_claude", "provider_codex", "provider_pi", "provider_cursor", "provider_opencode", "app_terminal", "app_editor", "app_git", "agent_unknown", "agent_working_0", "agent_working_1", "agent_working_2", "agent_working_3", "agent_blocked", "agent_ready", "agent_done", "agent_failed", "close", "pane_fullscreen", "telar_mark"};
      const auto text = value.string();
      if (!std::ranges::any_of(names, [text](std::string_view name) {
            return equalUiName(text, name);
          })) {
        value.fail("names an unknown icon");
      }
    }

    inline void uiMark(const lua::Value& value) {
      value.string();
      optionalChoice(value, {"claude", "codex", "pi", "telar"});
    }

    inline void hexadecimalColor(const lua::Value& value) {
      const auto text = value.string();
      if (text.size() != 7 || text.front() != '#' || !std::ranges::all_of(text.substr(1), [](char byte) {
            return (byte >= '0' && byte <= '9') || (asciiLower(byte) >= 'a' && asciiLower(byte) <= 'f');
          })) {
        value.fail("must be an RGB hexadecimal color");
      }
    }

  }
}

// Interface: telar_config/agents/provider.cppm
export {
  namespace telar::runtime {

    struct ProviderDescription {
      std::string_view name;
      std::string_view display_name;
      std::string_view placeholder;
      AgentAttachmentMarkers attachments;
      std::array<std::string_view, 2> process_names;
    };

    inline ProviderDescription describeProvider(AgentProvider provider) noexcept {
      switch (provider) {
      case AgentProvider::claude:
        return {.name = "claude", .display_name = "Claude Code", .placeholder = "New Claude Code session", .attachments = AgentAttachmentMarkers::stable_number, .process_names = {"claude", "claude-code"}};
      case AgentProvider::codex:
        return {.name = "codex", .display_name = "Codex", .placeholder = "New Codex session", .attachments = AgentAttachmentMarkers::ordered, .process_names = {"codex", {}}};
      case AgentProvider::pi:
        return {.name = "pi", .display_name = "Pi", .placeholder = "New Pi session", .attachments = AgentAttachmentMarkers::pasted_path, .process_names = {"pi", {}}};
      case AgentProvider::cursor:
        return {.name = "cursor", .display_name = "Cursor Agent", .placeholder = "New Cursor Agent session", .attachments = AgentAttachmentMarkers::none, .process_names = {"cursor-agent", {}}};
      case AgentProvider::opencode:
        return {.name = "opencode", .display_name = "OpenCode", .placeholder = "New OpenCode session", .attachments = AgentAttachmentMarkers::none, .process_names = {"opencode", {}}};
      default:
        return {.name = "", .display_name = "", .placeholder = "New agent session", .attachments = AgentAttachmentMarkers::none, .process_names = {}};
      }
    }

    inline AgentProvider builtinProviderFromExecutable(std::string_view name) noexcept {
      const auto stem = withoutExecutableSuffix(name);

      for (const auto provider : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
        for (const auto process : describeProvider(provider).process_names) {
          if (!process.empty() && asciiEqualIgnoreCase(stem, process)) {
            return provider;
          }
        }
      }

      return AgentProvider::unknown;
    }

    inline AgentProvider providerNamed(std::string_view name) noexcept {
      for (const auto provider : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
        if (describeProvider(provider).name == name) {
          return provider;
        }
      }

      return AgentProvider::unknown;
    }

  }
}

// Interface: telar_config/integration_provider.cppm
export {
  namespace telar::runtime::config {

    // Where an agent keeps the hook settings telar installs, which the CLI writes and the runtime
    // reads back to tell whether a shared agent server reports through them.
    struct IntegrationProvider {
      std::string_view name;
      const char* environment = nullptr;
      std::string_view home_directory;
      std::string_view environment_suffix{};
      std::string_view file;
      std::span<const std::string_view> events{};
      std::span<const std::string_view> worktree_events{};
      std::string_view timeout{};
      bool flat_hooks = false;
      std::string_view launch_note{};

      inline static IntegrationProvider describe(AgentProvider provider) {
        switch (provider) {
        case AgentProvider::claude:
          return {.name = "claude", .environment = "CLAUDE_CONFIG_DIR", .home_directory = ".claude", .file = "settings.json", .events = claude_events, .worktree_events = claude_worktree_events, .timeout = "5"};
        case AgentProvider::codex:
          return {.name = "codex", .environment = "CODEX_HOME", .home_directory = ".codex", .file = "hooks.json", .events = codex_events, .timeout = "3", .launch_note = "Codex runs its hooks in its shared daemon, outside any pane, unless it starts with --no-daemon; launch it that way, for instance with `alias codex='codex --no-daemon'`"};
        case AgentProvider::cursor:
          return {.name = "cursor", .home_directory = ".cursor", .file = "hooks.json", .events = cursor_events, .timeout = "5", .flat_hooks = true};
        case AgentProvider::pi:
          return {.name = "pi", .environment = "PI_CODING_AGENT_DIR", .home_directory = ".pi/agent", .file = "extensions/telar.ts"};
        case AgentProvider::opencode:
          return {.name = "opencode", .environment = "XDG_CONFIG_HOME", .home_directory = ".config/opencode", .environment_suffix = "/opencode", .file = "plugins/telar.ts"};
        default:
          throw std::invalid_argument{"Unknown integration provider"};
        }
      }

      template <Allocator Memory, EnvironmentLookup Environment>
      inline String<Memory> root(Memory& memory, const Environment& environment, bool legacy = false) const {
        String<Memory> result{AllocatorRef<char, Memory>{memory}};

        if (this->environment != nullptr && !legacy) {
          result = environment.lookup(this->environment);
          if (!result.empty()) {
            result += environment_suffix;
            return result;
          }
        }

        result = environment.lookup("HOME");
        if (result.empty()) {
          throw std::invalid_argument{"Home directory unavailable for integration"};
        }

        result += '/';
        result += home_directory;
        return result;
      }

    private:
      static constexpr auto claude_events = std::to_array<std::string_view>({"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification", "SessionEnd", "CwdChanged"});
      static constexpr auto claude_worktree_events = std::to_array<std::string_view>({"WorktreeCreate", "WorktreeRemove"});
      static constexpr auto codex_events = std::to_array<std::string_view>({"SessionStart", "UserPromptSubmit", "PermissionRequest", "PreToolUse", "PostToolUse", "Stop", "Interrupt", "SubagentStop", "SessionEnd"});
      static constexpr auto cursor_events = std::to_array<std::string_view>({"sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure", "stop", "sessionEnd"});
    };

  }
}

// Interface: telar_config/local_modules.cppm
export {
  namespace telar::runtime::config {

    using LocalModules = lua::LocalModules<lua::ModuleDomain::configuration>;

  }
}
