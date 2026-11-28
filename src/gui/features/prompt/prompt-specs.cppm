// The specs Tab completes from. Nothing here is exported: only the feature's own units name it,
// through State.
export module telar.gui.features.prompt:specs;

import std;

import telar.ebnf.matcher;
import telar.base.ds;
import telar.base.memory.allocators;

namespace telar::gui::features::prompt {

  // The specs the runtime sent, compiled, by the command they describe: the runtime holds
  // the catalogue and answers for the commands a pane's shell runs.
  class Specs {
  public:
    static constexpr std::size_t capacity = 256;

    // The specs live in `memory`.
    explicit Specs(Memory& memory);

    [[nodiscard]] const ebnf::command_spec* find(std::string_view command) const;

    // The digest of the spec held for `command`, or 0.
    [[nodiscard]] std::uint64_t digest(std::string_view command) const;

    // Compiles and keeps `source`; a spec that does not compile is dropped.
    bool install(std::string_view command, std::uint64_t digest, std::string_view source);

    // Whether the spec held for `command` says it lists every option the command accepts, with
    // the comment `(* telar: complete *)`: only then is an option it does not name one the
    // command refuses.
    [[nodiscard]] bool complete(std::string_view command) const;

    // Moves with every spec installed.
    [[nodiscard]] std::uint64_t revision() const noexcept;

    // The comment that marks a spec complete.
    static constexpr std::string_view complete_marker = "(* telar: complete *)";

  private:
    struct Entry {
      std::uint64_t digest = 0;
      ds::Box<ebnf::command_spec, Memory> spec;
      bool complete = false;
    };

    Memory& memory_;
    ds::Map<ds::String<Memory>, Entry, Memory> entries_;
    std::uint64_t revision_ = 0;
  };

  // The matcher's working space, made in `memory` the first time a spec completes.
  class MatchScratch {
  public:
    explicit MatchScratch(Memory& memory);

    ebnf::match_scratch& lend();

  private:
    Memory& memory_;
    ds::Option<ds::Box<ebnf::match_scratch, Memory>> scratch_;
  };

}
