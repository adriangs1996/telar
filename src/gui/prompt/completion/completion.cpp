module telar.gui.prompt.completion;

import std;

namespace telar::gui::prompt {

  std::optional<CompletionContext> completionContext(std::string_view text, std::size_t cursor, shell::Syntax syntax) {
    std::vector<shell::Token> tokens(text.size() + 1);
    const auto lexed = shell::lex(text, syntax, tokens, cursor);
    if (!lexed.cursor_completable) {
      return std::nullopt;
    }

    std::vector<shell::Word> words(text.size() + 1);
    std::vector<char> unquoted(2 * text.size() + 2);
    const auto at = shell::commandAt(text, syntax, std::span{tokens}.first(lexed.tokens), lexed, words, unquoted);
    if (at.overflow || at.current == shell::no_word) {
      return std::nullopt;
    }

    CompletionContext context;

    context.partial.assign(at.prefix);
    context.replace_begin = at.replace.begin;
    context.replace_end = at.replace.end;
    context.command_position = at.command_word == shell::no_word || at.current <= at.command_word;
    if (!context.command_position) {
      auto name = words[at.command_word].text;

      context.command.assign(name.substr(name.rfind('/') + 1));
      for (auto index = at.command_word + 1; index < at.current && index < at.words; ++index) {
        context.words.emplace_back(words[index].text);
      }
    }

    return context;
  }

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

  Completion complete(const CompletionContext& context, const ebnf::command_spec* spec, ebnf::match_scratch& scratch, std::span<const std::string> history) {
    Completion result;
    const auto add = [&](std::string_view text, std::string_view description) {
      if (text.starts_with(context.partial) && std::ranges::none_of(result.choices, [&](const Choice& choice) {
            return choice.text == text;
          })) {
        result.choices.push_back({std::string{text}, std::string{description}});
      }
    };

    if (context.command_position) {
      for (auto entry = history.rbegin(); entry != history.rend() && result.choices.size() < 64; ++entry) {
        const auto line = std::string_view{*entry};
        const auto end = line.find_first_of(" \t\n|;&");

        add(line.substr(0, end), {});
      }

      return result;
    }

    if (spec == nullptr) {
      result.providers.emplace_back("file");
      return result;
    }

    std::vector<std::string_view> words{context.words.begin(), context.words.end()};
    std::array<ebnf::candidate, 128> candidates{};
    const auto matched = spec->complete(words, context.partial, scratch, candidates);
    if (matched.status != ebnf::match_status::valid) {
      return result;
    }

    for (const auto& candidate : std::span{candidates}.first(matched.count)) {
      if (candidate.kind == ebnf::candidate_kind::literal) {
        std::string text{candidate.prefix};

        text.append(candidate.text);
        add(text, candidate.description);
      } else if (std::ranges::find(result.providers, candidate.text) == result.providers.end()) {
        result.providers.emplace_back(candidate.text);
        result.provider_prefix.assign(candidate.prefix);
      }
    }

    return result;
  }

  std::string quoteWord(std::string_view text, shell::Dialect dialect) {
    constexpr std::string_view special = " \t\n'\"\\$`;&|<>()[]{}*?!#";
    std::string result;

    for (const auto byte : text) {
      if (special.find(byte) != std::string_view::npos && !(dialect == shell::Dialect::fish && (byte == '!' || byte == '#'))) {
        result.push_back('\\');
      }

      result.push_back(byte);
    }

    return result;
  }

}
