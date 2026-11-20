module;
#include "tbc/annotations.hpp"

#include "telar_config/graphics/limits.hpp"

export module telar.config.core;

import std;
import telar.tbc;
import telar.lua;
import telar.platform.paths;
import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.ds;

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
      void add(tbc::ref_a<LimitReach> reach) noexcept;
      std::span<const LimitReach> entries() const noexcept;
      void print() const noexcept;

    private:
      tbc::val_a<ds::Array<LimitReach, 16>> entries_{};
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
    [[nodiscard]] ds::Option<std::size_t> optionalChoiceIndex(const lua::Value& value, std::span<const std::string_view> names);

    // The value of `name` in `names` as an enum whose values follow the table. Stays in the
    // interface because it is a template over the caller's enum; the lookup is out of line.
    template <typename Enum, std::size_t Count>
    [[nodiscard]] TBC_GENERIC ds::Option<Enum> optionalChoice(const lua::Value& value, const ds::Array<std::string_view, Count>& names) {
      const auto index = optionalChoiceIndex(value, names);

      return index ? ds::Option{static_cast<Enum>(*index)} : ds::none;
    }

    [[nodiscard]] ds::Option<double> optionalNumber(const lua::Value& value, Bounds<double> bounds);

    // A whole number within the bounds, if the value is present.
    [[nodiscard]] ds::Option<double> optionalWholeValue(const lua::Value& value, Bounds<double> bounds);

    // Stays in the interface because it is a template over the caller's integer type.
    template <typename Integer>
    [[nodiscard]] TBC_GENERIC ds::Option<Integer> optionalWhole(const lua::Value& value, Bounds<double> bounds) {
      const auto number = optionalWholeValue(value, bounds);

      return number ? ds::Option{static_cast<Integer>(*number)} : ds::none;
    }

    [[nodiscard]] ds::Option<bool> optionalBoolean(const lua::Value& value);

  }
}

// Interface: telar_config/ui_value_constraints.cppm
export {
  namespace telar::runtime::config {

    void printableUiText(const lua::Value& source, std::string_view text, bool allow_tab = false);
    tbc::val_a<std::string_view> fittedUiText(tbc::val_a<std::string_view> text, tbc::val_b<LimitReach> reach, tbc::mut_b<LimitNotices> limits);
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
      ds::Array<std::string_view, 2> process_names;
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

      // The path lives in the memory it is written to, region `a`.
      tbc::val_a<ds::String<Memory>> root(tbc::mut_a<Memory> memory, const EnvironmentSource& environment, bool legacy = false) const;

    private:
      static constexpr auto claude_events = ds::Array<std::string_view, 8>{"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification", "SessionEnd", "CwdChanged"};
      static constexpr auto claude_worktree_events = ds::Array<std::string_view, 2>{"WorktreeCreate", "WorktreeRemove"};
      static constexpr auto codex_events = ds::Array<std::string_view, 9>{"SessionStart", "UserPromptSubmit", "PermissionRequest", "PreToolUse", "PostToolUse", "Stop", "Interrupt", "SubagentStop", "SessionEnd"};
      static constexpr auto cursor_events = ds::Array<std::string_view, 7>{"sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure", "stop", "sessionEnd"};
    };

  }
}

// The allocator IntegrationProvider::root is built for, in core.cpp.
namespace telar::runtime::config {

}

// Interface: telar_config/local_modules.cppm
export {
  namespace telar::runtime::config {

    using LocalModules = lua::LocalModules<lua::ModuleDomain::configuration>;

  }
}
