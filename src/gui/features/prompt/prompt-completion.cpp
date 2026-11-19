module telar.gui.features.prompt;

import telar.tbc;
import std;

import telar.ebnf.matcher;
import telar.shell.syntax;
import telar.base.ds;
import telar.base.memory.allocators;

namespace telar::gui::features::prompt {

  CompletionContext::CompletionContext(Memory& memory)
      : command(memory),
        words(memory),
        partial(memory) {}

  Completion::Completion(Memory& memory)
      : choices(memory),
        providers(memory),
        provider_prefix(memory) {}

  tbc::view<ds::Option<CompletionContext>, tbc::lt::a> completionContext(tbc::view<Memory&, tbc::lt::a> memory, std::string_view text, std::size_t cursor, shell::Syntax syntax) {
    ds::Vec<shell::Token, Memory> tokens{memory};

    tokens.resize(text.size() + 1);
    const auto lexed = shell::lex(text, syntax, tokens.viewMut(), cursor);
    if (!lexed.cursor_completable) {
      return ds::none;
    }

    ds::Vec<shell::Word, Memory> words{memory};
    ds::Vec<char, Memory> unquoted{memory};

    words.resize(text.size() + 1);
    unquoted.resize((2 * text.size()) + 2);
    const auto at = shell::commandAt(text, syntax, tokens.view().first(lexed.tokens), lexed, words.viewMut(), unquoted.viewMut());
    if (at.overflow || at.current == shell::no_word) {
      return ds::none;
    }

    CompletionContext context{memory};

    context.partial.assign(at.prefix);
    context.replace_begin = at.replace.begin;
    context.replace_end = at.replace.end;
    context.command_position = at.command_word == shell::no_word || at.current <= at.command_word;
    if (!context.command_position) {
      auto name = words[at.command_word].text;

      context.command.assign(name.substr(name.rfind('/') + 1));
      for (auto index = at.command_word + 1; index < at.current && index < at.words; ++index) {
        context.words.emplace(memory, words[index].text);
      }
    }

    return std::move(context);
  }

  tbc::view<Completion, tbc::lt::a> complete(tbc::view<Memory&, tbc::lt::a> memory, const CompletionContext& context, const ebnf::command_spec* spec, ebnf::match_scratch& scratch, History history) {
    Completion result{memory};
    const auto add = [&](std::string_view text, std::string_view description) {
      if (text.starts_with(context.partial.view()) && std::ranges::none_of(result.choices, [&](const Choice& choice) {
            return choice.text == text;
          })) {
        result.choices.push(Choice{ds::String<Memory>{memory, text}, ds::String<Memory>{memory, description}});
      }
    };

    if (context.command_position) {
      for (auto entry = history.rbegin(); entry != history.rend() && result.choices.size() < 64; ++entry) {
        const auto line = entry->view();
        const auto end = line.find_first_of(" \t\n|;&");

        add(line.substr(0, end), {});
      }

      return result;
    }

    if (spec == nullptr) {
      result.providers.emplace(memory, "file");
      return result;
    }

    ds::Vec<std::string_view, Memory> words{memory};

    words.reserve(context.words.size());
    for (const auto& word : context.words) {
      words.push(word.view());
    }

    ds::Array<ebnf::candidate, 128> candidates{};
    const auto matched = spec->complete(words.view(), context.partial, scratch, candidates.viewMut());
    if (matched.status != ebnf::match_status::valid) {
      return result;
    }

    for (const auto& candidate : std::span{candidates}.first(matched.count)) {
      if (candidate.kind == ebnf::candidate_kind::literal) {
        add(ds::format(memory, "{}{}", candidate.prefix, candidate.text), candidate.description);
      } else if (std::ranges::find(result.providers, candidate.text) == result.providers.end()) {
        result.providers.emplace(memory, candidate.text);
        result.provider_prefix.assign(candidate.prefix);
      }
    }

    return result;
  }

  tbc::view<ds::String<Memory>, tbc::lt::a> quoteWord(tbc::view<Memory&, tbc::lt::a> memory, std::string_view text, shell::Dialect dialect) {
    constexpr std::string_view special = " \t\n'\"\\$`;&|<>()[]{}*?!#";
    ds::String<Memory> result{memory};

    for (const auto byte : text) {
      if (special.contains(byte) && (dialect != shell::Dialect::fish || (byte != '!' && byte != '#'))) {
        result.push('\\');
      }

      result.push(byte);
    }

    return result;
  }

}
