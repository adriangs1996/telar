module;
#include "tbc/annotations.hpp"

export module telar.cli.hooks.command;

import std;
import telar.tbc;

export import telar.base.text.json;
import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.wire.agents;
import telar.base.text;
import telar.base.text.utf8;
import telar.config.runtime;

// Interface: hook_options.cppm
export {
  namespace telar::runtime::cli {

    struct HookOptions {
      AgentProvider provider;
      std::string_view socket;

      static HookOptions parse(std::span<char* const> arguments);
    };

  }
}

// Interface: hooks/object.cppm
export {
  namespace telar::runtime::cli::hooks {

    // The hook reads every agent event through this class.
    template <Allocator Memory>
    class Object {
    public:
      explicit Object(Memory& memory, JsonValue value, bool reject_duplicates = false);

      std::optional<JsonValue> value(std::string_view name) const;
      std::optional<std::string_view> optionalText(std::string_view name);
      std::string_view text(std::string_view name);
      std::optional<std::string_view> stringField(std::string_view name);
      std::optional<bool> boolean(std::string_view name) const;

      // Generic over the caller's integer type, so it stays here and reads the field through text.
      template <typename Integer>
      TBC_HOT_PATH inline std::optional<Integer> integer(std::string_view name) {
        const auto field = value(name);
        if (!field || field->encoded() == "null") {
          return std::nullopt;
        }

        const auto input = field->encoded().starts_with('"') ? text(name) : field->encoded();
        const auto parsed = parseExact<Integer>(input);
        if (!parsed) {
          throw std::invalid_argument{"Expected hook integer"};
        }

        return *parsed;
      }

      void requireUnique() const;

      template <typename Consumer>
      void eachValue(Consumer&& consume) const;

    private:
      struct Member {
        String<Memory> name;
        JsonValue value;
        std::optional<String<Memory>> text;
        std::size_t position;
        bool duplicate = false;
      };

      Member* find(std::string_view name) noexcept;
      const Member* find(std::string_view name) const noexcept;
      void indexMembers();
      tbc::view<std::string_view, tbc::lt::a> decode(tbc::view<Member&, tbc::lt::a> member);
      void checkUnique(const Member& member) const;

      Memory& memory_;
      Vector<Member, Memory> members_;
      bool reject_duplicates_;
    };

    template <Allocator Memory>
    Object(Memory& memory, JsonValue value, bool reject_duplicates = false) -> Object<Memory>;

    extern template class Object<Memory>;

  }
}

// Interface: hooks/validation.cppm
export {
  namespace telar::runtime::cli::hooks {

    template <Allocator Memory>
    void validateUnicodeEscapes(Memory& memory, std::string_view input);
    extern template void validateUnicodeEscapes<Memory>(Memory& memory, std::string_view input);

    template <Allocator Memory>
    void validateDynamicValue(Memory& memory, JsonValue value);
    extern template void validateDynamicValue<Memory>(Memory& memory, JsonValue value);

  }
}

// Interface: hooks/payload.cppm
export {
  namespace telar::runtime::cli::hooks {

    // The hook reads every agent event through this class.
    template <Allocator Memory>
    class Payload {
    public:
      explicit Payload(Memory& memory, AgentProvider provider, JsonValue input);

      // Its tools view its own fields, so it stays where it is built.
      explicit Payload(Memory& memory, AgentProvider provider, Object<Memory> input);

      Payload(const Payload&) = delete;
      Payload& operator=(const Payload&) = delete;

      std::string_view event();
      std::string_view session();
      bool subagent();
      std::string_view workspace() const noexcept;
      std::string_view toolEvent();
      AgentBlockedReason blockedReason();

      Memory& memory;
      AgentProvider provider;
      Object<Memory> fields;
      tbc::view<Object<Memory>, tbc::lt::self> tools;
      std::size_t running_subagents = 0;

    private:
      void strictBoolean(std::string_view name);
      static JsonValue toolObject(const Object<Memory>& fields);

      std::optional<String<Memory>> workspace_;
    };

    template <Allocator Memory>
    Payload(Memory& memory, AgentProvider provider, JsonValue input) -> Payload<Memory>;

    template <Allocator Memory>
    Payload(Memory& memory, AgentProvider provider, Object<Memory> input) -> Payload<Memory>;

    extern template class Payload<Memory>;

  }
}

// Interface: hooks/text.cppm
export {
  namespace telar::runtime::cli::hooks {

    std::string_view sessionReference(std::string_view text) noexcept;

    void eventLine(FixedText<96>& output, std::string_view text);

    std::string_view validPrefix(std::string_view text) noexcept;

    // Writes only `output`.
    template <std::size_t Capacity>
    void displayText(FixedText<Capacity>& output, std::string_view text, bool multiline);
    extern template void displayText<96>(FixedText<96>& output, std::string_view text, bool multiline);
    extern template void displayText<2048>(FixedText<2048>& output, std::string_view text, bool multiline);

    bool defaultOpenCodeTitle(std::string_view title) noexcept;

  }
}

// Interface: hooks/command.cppm
export {
  namespace telar::runtime::cli::hooks {

    template <Allocator Memory>
    std::optional<ReportAgentCommand> commandReport(Payload<Memory>& input);
    extern template std::optional<ReportAgentCommand> commandReport<Memory>(Payload<Memory>& input);

  }
}

// Interface: hooks/event.cppm
export {
  namespace telar::runtime::cli::hooks {

    template <Allocator Memory>
    void toolEvent(FixedText<96>& output, Payload<Memory>& input);
    extern template void toolEvent<Memory>(FixedText<96>& output, Payload<Memory>& input);

    template <Allocator Memory>
    bool questionEvent(FixedText<96>& output, Payload<Memory>& input);
    extern template bool questionEvent<Memory>(FixedText<96>& output, Payload<Memory>& input);

    void backgroundEvent(FixedText<96>& output, std::size_t count);

  }
}
