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

    // The specs and the matcher's scratch live in `memory`.
    explicit Specs(Memory& memory);

    const ebnf::command_spec* find(std::string_view command) const;

    // The digest of the spec held for `command`, or 0.
    std::uint64_t digest(std::string_view command) const;

    // Compiles and keeps `source`; a spec that does not compile is dropped.
    bool install(std::string_view command, std::uint64_t digest, std::string_view source);

    ebnf::match_scratch& scratch();

  private:
    struct Entry {
      std::uint64_t digest = 0;
      Owned<ebnf::command_spec, Memory> spec;
    };

    Memory& memory_;
    ds::Map<ds::String<Memory>, Entry, Memory> entries_;
    ds::Option<Owned<ebnf::match_scratch, Memory>> scratch_;
  };

}
