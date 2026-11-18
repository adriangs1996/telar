module telar.gui.features.prompt;

import std;

import telar.ebnf.matcher;
import telar.shell.syntax;
import telar.base.ds;

namespace telar::gui::features::prompt {

  ds::Option<CompletionContext> completionContext(std::string_view text, std::size_t cursor, shell::Syntax syntax) {
    std::vector<shell::Token> tokens(text.size() + 1);
    const auto lexed = shell::lex(text, syntax, tokens, cursor);
    if (!lexed.cursor_completable) {
      return ds::none;
    }

    std::vector<shell::Word> words(text.size() + 1);
    std::vector<char> unquoted(2 * text.size() + 2);
    const auto at = shell::commandAt(text, syntax, std::span{tokens}.first(lexed.tokens), lexed, words, unquoted);
    if (at.overflow || at.current == shell::no_word) {
      return ds::none;
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
    ds::Array<ebnf::candidate, 128> candidates{};
    const auto matched = spec->complete(words, context.partial, scratch, candidates.viewMut());
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
