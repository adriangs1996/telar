export module telar.cli.commands.hooks.command;

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

      [[nodiscard]] ds::Option<JsonValue> value(std::string_view name) const;
      [[nodiscard]] ds::Option<std::string_view> optionalText(std::string_view name) const;
      [[nodiscard]] std::string_view text(std::string_view name) const;
      [[nodiscard]] ds::Option<std::string_view> stringField(std::string_view name) const;
      [[nodiscard]] ds::Option<bool> boolean(std::string_view name) const;

      // Generic over the caller's integer type, so it stays here and reads the field through text.
      template <typename Integer>
      [[tbc::generic]] inline ds::Option<Integer> integer(std::string_view name) const {
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
      void eachValue(const Consumer& consume) const;

    private:
      struct Member {
        ds::String<Memory> name;
        JsonValue value;
        ds::Option<ds::String<Memory>> text;
        std::size_t position;
        bool duplicate = false;
      };

      [[nodiscard]] const Member* find(std::string_view name) const noexcept;
      void indexMembers();
      // Each string member is decoded once, as the object is built, so reading one reads nothing new.
      void decodeStrings();
      [[nodiscard]] tbc::val_a<std::string_view> decoded(tbc::ref_a<Member> member) const;
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
      Payload(Payload&&) = delete;
      Payload& operator=(Payload&&) = delete;
      ~Payload() = default;

      [[nodiscard]] std::string_view event() const;
      [[nodiscard]] std::string_view session() const;
      [[nodiscard]] bool subagent() const;
      [[nodiscard]] std::string_view workspace() const noexcept;
      [[nodiscard]] std::string_view toolEvent() const;
      [[nodiscard]] std::string_view toolName() const;
      [[nodiscard]] std::string_view toolCallId() const;
      [[nodiscard]] AgentBlockedReason blockedReason() const;

      [[nodiscard]] Memory& memory() const noexcept;
      [[nodiscard]] AgentProvider provider() const noexcept;
      [[nodiscard]] const Object& fields() const noexcept;
      [[nodiscard]] const Object& tools() const noexcept;
      // The background work that wakes the agent again when it ends: Codex's subagents, and
      // Claude's background tasks of every kind.
      [[nodiscard]] std::size_t backgroundWork() const noexcept;
      void setBackgroundWork(std::size_t count) noexcept;

    private:
      void validateTools();
      // The fields Pi and OpenCode send, and those of the agents that send hook events.
      void readEventFields();
      void readHookFields();
      void readCursorFields();
      void readClaudeFields();
      void readAntigravityFields();
      void strictBoolean(std::string_view name);
      // The arguments of the tool the event names, which Antigravity nests in its toolCall.
      [[nodiscard]] ds::Option<JsonValue> toolInput() const;
      static JsonValue objectOrEmpty(ds::Option<JsonValue> value);

      Memory& memory_;
      AgentProvider provider_;
      Object fields_;
      // Antigravity's toolCall: the tool's name, id and arguments. Empty for the other agents.
      tbc::val_self<Object> call_;
      tbc::val_self<Object> tools_;
      std::size_t background_work_ = 0;
      ds::Option<ds::String<Memory>> workspace_;
    };

  }
}

// Interface: hooks/text.cppm
export {
  namespace telar::runtime::cli::hooks {

    // The bytes the runtime shows of an event, a plan step or a title, and of an agent's message.
    inline constexpr std::size_t display_line_bytes = 96;
    inline constexpr std::size_t display_message_bytes = 2048;

    std::string_view sessionReference(std::string_view text) noexcept;

    void eventLine(FixedText<display_line_bytes>& output, std::string_view text);

    std::string_view validPrefix(std::string_view text) noexcept;

    // Writes only `output`.
    template <std::size_t Capacity>
    void displayText(FixedText<Capacity>& output, std::string_view text, bool multiline);
    extern template void displayText<display_line_bytes>(FixedText<display_line_bytes>& output, std::string_view text, bool multiline);
    extern template void displayText<display_message_bytes>(FixedText<display_message_bytes>& output, std::string_view text, bool multiline);

    bool defaultOpenCodeTitle(std::string_view title) noexcept;

  }
}

// Not exported. displayText, a template its importers instantiate, calls it, so it keeps module linkage.
namespace telar::runtime::cli::hooks {

  bool printable(unsigned char byte) noexcept;

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

    void toolEvent(FixedText<display_line_bytes>& output, const Payload& input);

    bool questionEvent(FixedText<display_line_bytes>& output, const Payload& input);

    // "waiting for N background NOUNs", the noun singular.
    void backgroundEvent(FixedText<display_line_bytes>& output, std::size_t count, std::string_view noun);

  }
}
