module;
#include "tbc/hot_path.hpp"

#include "telar_config/graphics/limits.hpp"

export module telar.config.core;

import std;
import telar.tbc;
export import telar.lua;
export import telar.platform.paths;
import telar.base.diagnostics;
import telar.base.text;
import telar.base.text.utf8;
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
      void add(tbc::view<const LimitReach&, tbc::lt::a> reach) noexcept;
      std::span<const LimitReach> entries() const noexcept;
      void print() const noexcept;

    private:
      tbc::view<std::array<LimitReach, 16>, tbc::lt::a> entries_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: telar_config/value_constraints.cppm
export {
  namespace telar::runtime::config {

    void optionalChoice(const lua::Value& value, std::initializer_list<std::string_view> choices);
    void optionalWholeNumber(const lua::Value& value, double minimum, double maximum);
    void optionalUtf8Text(const lua::Value& value, std::size_t maximum_bytes);

    template <typename Number>
    struct Bounds {
      Number minimum;
      Number maximum;
    };

    // The position of the value in `names`, if the value is present.
    [[nodiscard]] std::optional<std::size_t> optionalChoiceIndex(const lua::Value& value, std::span<const std::string_view> names);

    // The value of `name` in `names` as an enum whose values follow the table. Stays in the
    // interface because it is a template over the caller's enum; the lookup is out of line.
    template <typename Enum, std::size_t Count>
    [[nodiscard]] TBC_HOT_PATH std::optional<Enum> optionalChoice(const lua::Value& value, const std::array<std::string_view, Count>& names) {
      const auto index = optionalChoiceIndex(value, names);

      return index ? std::optional{static_cast<Enum>(*index)} : std::nullopt;
    }

    [[nodiscard]] std::optional<double> optionalNumber(const lua::Value& value, Bounds<double> bounds);

    // A whole number within the bounds, if the value is present.
    [[nodiscard]] std::optional<double> optionalWholeValue(const lua::Value& value, Bounds<double> bounds);

    // Stays in the interface because it is a template over the caller's integer type.
    template <typename Integer>
    [[nodiscard]] TBC_HOT_PATH std::optional<Integer> optionalWhole(const lua::Value& value, Bounds<double> bounds) {
      const auto number = optionalWholeValue(value, bounds);

      return number ? std::optional{static_cast<Integer>(*number)} : std::nullopt;
    }

    [[nodiscard]] std::optional<bool> optionalBoolean(const lua::Value& value);

  }
}

// Interface: telar_config/ui_value_constraints.cppm
export {
  namespace telar::runtime::config {

    void printableUiText(const lua::Value& source, std::string_view text, bool allow_tab = false);
    tbc::view<std::string_view, tbc::lt::a> fittedUiText(tbc::view<std::string_view, tbc::lt::a> text, tbc::view<LimitReach, tbc::lt::b> reach, tbc::view<LimitNotices&, tbc::lt::b> limits);
    bool equalUiName(std::string_view left, std::string_view right) noexcept;
    void uiIcon(const lua::Value& value);
    void uiMark(const lua::Value& value);
    void hexadecimalColor(const lua::Value& value);

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

    ProviderDescription describeProvider(AgentProvider provider) noexcept;
    AgentProvider builtinProviderFromExecutable(std::string_view name) noexcept;
    AgentProvider providerNamed(std::string_view name) noexcept;

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

      static IntegrationProvider describe(AgentProvider provider);

      template <Allocator Memory>
      String<Memory> root(Memory& memory, const EnvironmentSource& environment, bool legacy = false) const;

    private:
      static constexpr auto claude_events = std::to_array<std::string_view>({"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification", "SessionEnd", "CwdChanged"});
      static constexpr auto claude_worktree_events = std::to_array<std::string_view>({"WorktreeCreate", "WorktreeRemove"});
      static constexpr auto codex_events = std::to_array<std::string_view>({"SessionStart", "UserPromptSubmit", "PermissionRequest", "PreToolUse", "PostToolUse", "Stop", "Interrupt", "SubagentStop", "SessionEnd"});
      static constexpr auto cursor_events = std::to_array<std::string_view>({"sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure", "stop", "sessionEnd"});
    };

  }
}

// The allocator IntegrationProvider::root is built for, in core.cpp.
namespace telar::runtime::config {

  extern template String<Memory> IntegrationProvider::root<Memory>(Memory& memory, const EnvironmentSource& environment, bool legacy) const;

}

// Interface: telar_config/local_modules.cppm
export {
  namespace telar::runtime::config {

    using LocalModules = lua::LocalModules<lua::ModuleDomain::configuration>;

  }
}
