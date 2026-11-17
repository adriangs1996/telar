module telar.gui.features.prompt;

import std;

import telar.ebnf.matcher;

namespace telar::gui::features::prompt {

  const ebnf::command_spec* Specs::find(std::string_view command) const {
    const auto found = entries_.find(command);

    return found == entries_.end() ? nullptr : found->second.spec.get();
  }

  std::uint64_t Specs::digest(std::string_view command) const {
    const auto found = entries_.find(command);

    return found == entries_.end() ? 0 : found->second.digest;
  }

  bool Specs::install(std::string_view command, std::uint64_t digest, std::string_view source) {
    std::unique_ptr<ebnf::command_spec> spec;

    try {
      spec = std::make_unique<ebnf::command_spec>(ebnf::command_spec::compile(source));
    } catch (const std::exception&) {
      entries_.erase(std::string{command});
      return false;
    }

    if (entries_.size() >= capacity && !entries_.contains(command)) {
      entries_.clear();
    }

    entries_.insert_or_assign(std::string{command}, Entry{digest, std::move(spec)});
    return true;
  }

  ebnf::match_scratch& Specs::scratch() {
    if (!scratch_) {
      scratch_ = std::make_unique<ebnf::match_scratch>();
    }

    return *scratch_;
  }

  std::size_t Specs::Hash::operator()(std::string_view text) const noexcept {
    return std::hash<std::string_view>{}(text);
  }

}
