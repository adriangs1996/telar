module;
#include "tbc/annotations.hpp"

export module telar.cli.hooks.command;

import std;
import telar.tbc;

import telar.base.text.json;
import telar.wire.vocabulary;
import telar.wire.agents;
import telar.base.text;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;

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
    class Object {
    public:
      explicit Object(Memory& memory, JsonValue value, bool reject_duplicates = false);

      ds::Option<JsonValue> value(std::string_view name) const;
      ds::Option<std::string_view> optionalText(std::string_view name) const;
      std::string_view text(std::string_view name) const;
      ds::Option<std::string_view> stringField(std::string_view name) const;
      ds::Option<bool> boolean(std::string_view name) const;

      // Generic over the caller's integer type, so it stays here and reads the field through text.
      template <typename Integer>
      TBC_GENERIC inline ds::Option<Integer> integer(std::string_view name) const {
        const auto field = value(name);
        if (!field || field->encoded() == "null") {
          return ds::none;
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
        ds::String<Memory> name;
        JsonValue value;
        ds::Option<ds::String<Memory>> text;
        std::size_t position;
        bool duplicate = false;
      };

      const Member* find(std::string_view name) const noexcept;
      void indexMembers();
      // Each string member is decoded once, as the object is built, so reading one reads nothing new.
      void decodeStrings();
      tbc::view<std::string_view, tbc::lt::a> decoded(tbc::view<const Member&, tbc::lt::a> member) const;
      void checkUnique(const Member& member) const;

      Memory& memory_;
      ds::Vec<Member, Memory> members_;
      bool reject_duplicates_;
    };

  }
}

// Interface: hooks/validation.cppm
export {
  namespace telar::runtime::cli::hooks {

    void validateUnicodeEscapes(Memory& memory, std::string_view input);

    void validateDynamicValue(Memory& memory, JsonValue value);

  }
}

// Interface: hooks/payload.cppm
export {
  namespace telar::runtime::cli::hooks {

    // The hook reads every agent event through this class.
    class Payload {
    public:
      explicit Payload(Memory& memory, AgentProvider provider, JsonValue input);

      // Its tools view its own fields, so it stays where it is built.
      explicit Payload(Memory& memory, AgentProvider provider, Object input);

      Payload(const Payload&) = delete;
      Payload& operator=(const Payload&) = delete;

      std::string_view event() const;
      std::string_view session() const;
      bool subagent() const;
      std::string_view workspace() const noexcept;
      std::string_view toolEvent() const;
      AgentBlockedReason blockedReason() const;

      Memory& memory;
      AgentProvider provider;
      Object fields;
      tbc::view<Object, tbc::lt::self> tools;
      std::size_t running_subagents = 0;

    private:
      void strictBoolean(std::string_view name);
      static JsonValue toolObject(const Object& fields);

      ds::Option<ds::String<Memory>> workspace_;
    };

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

    ds::Option<ReportAgentCommand> commandReport(const Payload& input);

  }
}

// Interface: hooks/event.cppm
export {
  namespace telar::runtime::cli::hooks {

    void toolEvent(FixedText<96>& output, const Payload& input);

    bool questionEvent(FixedText<96>& output, const Payload& input);

    void backgroundEvent(FixedText<96>& output, std::size_t count);

  }
}
