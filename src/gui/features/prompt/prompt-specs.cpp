module telar.gui.features.prompt;

import std;

import telar.ebnf.matcher;
import telar.base.ds;
import telar.base.memory.allocators;

namespace telar::gui::features::prompt {

  Specs::Specs(Memory& memory)
      : memory_(memory),
        entries_(memory) {}

  const ebnf::command_spec* Specs::find(std::string_view command) const {
    const auto* found = entries_.find(command);

    return found == nullptr ? nullptr : &found->spec.get();
  }

  std::uint64_t Specs::digest(std::string_view command) const {
    const auto* found = entries_.find(command);

    return found == nullptr ? 0 : found->digest;
  }

  bool Specs::install(std::string_view command, std::uint64_t digest, std::string_view source) {
    ds::Option<ds::Box<ebnf::command_spec, Memory>> spec;

    try {
      spec = ds::makeBox<ebnf::command_spec>(memory_, ebnf::command_spec::compile(source));
    } catch (const std::exception&) {
      static_cast<void>(entries_.remove(command));
      return false;
    }

    if (entries_.size() >= capacity && !entries_.contains(command)) {
      entries_.clear();
    }

    static_cast<void>(entries_.assign(ds::String<Memory>{memory_, command}, Entry{.digest = digest, .spec = std::move(spec.getMut()), .complete = source.contains(complete_marker)}));
    ++revision_;
    return true;
  }

  bool Specs::complete(std::string_view command) const {
    const auto* found = entries_.find(command);

    return found != nullptr && found->complete;
  }

  std::uint64_t Specs::revision() const noexcept {
    return revision_;
  }

  MatchScratch::MatchScratch(Memory& memory)
      : memory_(memory) {}

  ebnf::match_scratch& MatchScratch::lend() {
    if (!scratch_) {
      scratch_ = ds::makeBox<ebnf::match_scratch>(memory_);
    }

    return scratch_.getMut().getMut();
  }

}
