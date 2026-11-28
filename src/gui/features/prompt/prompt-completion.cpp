module telar.gui.features.prompt;

import telar.tbc;
import std;

import telar.ebnf.matcher;
import telar.shell.syntax;
import telar.base.ds;
import telar.base.memory.allocators;

namespace telar::gui::features::prompt {

  namespace {

    // Commands that run the command after them: completion reads that one.
    constexpr ds::Array<std::string_view, 7> wrappers{"sudo", "env", "time", "nohup", "nice", "exec", "command"};

    // The command a simple command runs, past the wrappers before it and their options (and the
    // assignments env takes), but never past `limit`, the word being completed.
    std::size_t wrappedCommand(std::span<const shell::Word> words, std::size_t command_word, std::size_t limit) noexcept {
      while (command_word < limit && std::ranges::contains(wrappers, words[command_word].text)) {
        const bool env = words[command_word].text == "env";
        auto next = command_word + 1;

        while (next < limit && (words[next].text.starts_with('-') || (env && words[next].text.contains('=')))) {
          ++next;
        }

        command_word = next;
      }

      return command_word;
    }

    // Lexes lines into buffers that grow to the longest one, for the command each runs.
    class CommandReader {
    public:
      explicit CommandReader(tbc::mut_a<Memory> memory)
          : tokens_(memory),
            words_(memory),
            unquoted_(memory) {}

      // The command `line`'s first simple command runs, as the shell reads it; empty when none.
      [[nodiscard]] std::string_view first(std::string_view line, shell::Syntax syntax) {
        tokens_.resize(line.size() + 1);
        words_.resize(line.size() + 1);
        unquoted_.resize((2 * line.size()) + 2);
        const auto lexed = shell::lex(line, syntax, tokens_.viewMut(), 0);
        if (!lexed.cursor_completable) {
          return {};
        }

        const auto located = shell::commandAt(line, syntax, tokens_.view().first(lexed.tokens), lexed, words_.viewMut(), unquoted_.viewMut());
        if (located.overflow || located.command_word == shell::no_word) {
          return {};
        }

        const auto command = wrappedCommand(words_.view(), located.command_word, located.words);

        return command < located.words ? words_[command].text : std::string_view{};
      }

    private:
      ds::Vec<shell::Token, Memory> tokens_;
      ds::Vec<shell::Word, Memory> words_;
      ds::Vec<char, Memory> unquoted_;
    };

  }

  tbc::val_a<Choice> Choice::clone() const {
    return {.text = text.clone(), .description = description.clone(), .directory = directory, .joined = joined};
  }

  CompletionContext::CompletionContext(Memory& memory)
      : command(memory),
        words(memory),
        partial(memory) {}

  Completion::Completion(Memory& memory)
      : choices(memory),
        providers(memory),
        provider_prefix(memory) {}

  tbc::val_a<ds::Option<CompletionContext>> completionContext(tbc::mut_a<Memory> memory, std::string_view text, std::size_t cursor, shell::Syntax syntax) {
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
    const auto located = shell::commandAt(text, syntax, tokens.view().first(lexed.tokens), lexed, words.viewMut(), unquoted.viewMut());
    if (located.overflow || located.current == shell::no_word) {
      return ds::none;
    }

    CompletionContext context{memory};
    // The command after a wrapper (sudo, env…) is the one completed.
    const auto command_word = located.command_word == shell::no_word ? shell::no_word : wrappedCommand(words.view(), located.command_word, std::min(located.current, located.words));

    context.partial.assign(located.prefix);
    context.replace_begin = located.replace.begin;
    context.replace_end = located.replace.end;
    context.command_position = command_word == shell::no_word || located.current <= command_word;
    if (!context.command_position) {
      auto name = words[command_word].text;

      context.command.assign(name.substr(name.rfind('/') + 1));
      for (auto index = command_word + 1; index < located.current && index < located.words; ++index) {
        context.words.emplace(memory, words[index].text);
      }
    }

    return std::move(context);
  }

  // NOLINTNEXTLINE(readability-function-size): the spec's matcher needs its scratch, and the words their shell's syntax
  tbc::val_a<Completion> complete(tbc::mut_a<Memory> memory, const CompletionContext& context, const ebnf::command_spec* spec, ebnf::match_scratch& scratch, History history, shell::Syntax syntax) {
    Completion result{memory};
    const auto add = [&](std::string_view text, std::string_view description, bool joined = false) {
      if (text.starts_with(context.partial.view()) && std::ranges::none_of(result.choices, [&](const Choice& choice) {
            return choice.text == text;
          })) {
        result.choices.push(Choice{
            .text = ds::String<Memory>{memory, text},
            .description = ds::String<Memory>{memory, description},
            .joined = joined,
        });
      }
    };

    if (context.command_position) {
      constexpr std::size_t max_history_choices = 64;
      CommandReader reader{memory};

      for (auto entry = history.rbegin(); entry != history.rend() && result.choices.size() < max_history_choices; ++entry) {
        // Only a line that holds the word typed can run a command that starts with it.
        if (const auto line = entry->view(); line.contains(context.partial.view())) {
          add(reader.first(line, syntax), {});
        }
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

    constexpr std::size_t max_candidates = 128;
    ds::Array<ebnf::candidate, max_candidates> candidates{};
    // A line the spec does not accept, or cannot tell, completes files, as zsh and fish fall back
    // to theirs.
    const auto matched = spec->complete(words.view(), context.partial, scratch, candidates.viewMut());
    if (matched.status != ebnf::match_status::valid) {
      result.providers.emplace(memory, "file");
      return result;
    }

    for (const auto& candidate : std::span{candidates}.first(matched.count)) {
      if (candidate.kind == ebnf::candidate_kind::literal) {
        add(ds::format(memory, "{}{}", candidate.prefix, candidate.text), candidate.description, candidate.glued);
      } else if (std::ranges::find(result.providers, candidate.text) == result.providers.end()) {
        result.providers.emplace(memory, candidate.text);
        result.provider_prefix.assign(candidate.prefix);
      }
    }

    return result;
  }

  tbc::val_a<ds::String<Memory>> quoteWord(tbc::mut_a<Memory> memory, std::string_view text, shell::Dialect dialect) {
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

  bool startsFolded(std::string_view text, std::string_view start) noexcept {
    constexpr auto fold = [](char byte) {
      return byte >= 'A' && byte <= 'Z' ? static_cast<char>(byte - 'A' + 'a') : byte;
    };

    return text.size() >= start.size() && std::ranges::equal(std::string_view{text.data(), start.size()}, start, {}, fold, fold);
  }

  namespace {

    using OptionRange = std::pair<std::size_t, std::size_t>;

    // A line longer than this is no command to check as it is typed.
    constexpr std::size_t longest_checked_command = 4096;

    // Which of `arguments` the spec refuses first, when it is an option; none when they hold
    // nothing it refuses, or what it refuses is no option, or a long option's prefix that
    // getopt_long takes.
    ds::Option<std::size_t> refusedArgument(const ebnf::command_spec& spec, std::span<const std::string_view> arguments, ebnf::match_scratch& scratch) noexcept { // NOLINT(bugprone-exception-escape): substr is given an offset within the option, which cannot throw
      const auto result = spec.check(arguments, scratch);
      if (result.status != ebnf::match_status::invalid || result.word >= arguments.size() || !arguments[result.word].starts_with('-')) {
        return ds::none;
      }

      // getopt_long takes a long option by any prefix that names it alone (`--col` for
      // `--color`), which a spec does not model: a word that starts an option offered there is
      // one the command may take.
      const auto option = arguments[result.word];
      if (option.starts_with("--")) {
        ds::Array<ebnf::candidate, 1> offered{};
        const auto before = arguments.first(result.word);
        const auto named = option.substr(0, option.find('='));

        if (spec.complete(before, named, scratch, offered.viewMut()).count != 0) {
          return ds::none;
        }
      }

      return std::size_t{result.word};
    }

    // The bytes of the first option `text`'s command refuses, as rejectedOption reads it.
    ds::Option<OptionRange> findRejected(State& state, std::uint64_t pane_id, std::string_view text, shell::Dialect dialect) {
      using Range = OptionRange;

      if (text.size() > longest_checked_command || text.find_first_of("$|;&`'\"\\()<>{}#\n") != std::string_view::npos) {
        return ds::none;
      }

      auto& memory = state.memory;
      const shell::Syntax syntax{.dialect = dialect};
      ds::Vec<shell::Token, Memory> tokens{memory};

      tokens.resize(text.size() + 1);
      const auto lexed = shell::lex(text, syntax, tokens.viewMut(), text.size());
      if (!lexed.cursor_completable || lexed.commands != 1 || lexed.completeness != shell::Completeness::complete) {
        return ds::none;
      }

      ds::Vec<shell::Word, Memory> words{memory};
      ds::Vec<char, Memory> unquoted{memory};

      words.resize(text.size() + 1);
      unquoted.resize((2 * text.size()) + 2);
      const auto located = shell::commandAt(text, syntax, tokens.view().first(lexed.tokens), lexed, words.viewMut(), unquoted.viewMut());
      if (located.overflow || located.command_word == shell::no_word) {
        return ds::none;
      }

      const auto command_word = wrappedCommand(words.view(), located.command_word, located.words);
      if (command_word >= located.words) {
        return ds::none;
      }

      const auto name = words[command_word].text;
      const auto* checks = state.command_checks.find(pane_id);
      const auto* spec = state.specs.find(name);
      // An alias reads as the command it stands for, which may take what the name does not.
      if (spec == nullptr || !state.specs.complete(name) || (checks != nullptr && checks->aliases.contains(name))) {
        return ds::none;
      }

      // The word at the line's end is still being typed, until a blank ends it.
      const bool ended = text.ends_with(' ') || text.ends_with('\t');
      const auto last = ended ? located.words : located.words - 1;
      ds::Vec<std::string_view, Memory> arguments{memory};

      for (auto index = command_word + 1; index < last; ++index) {
        arguments.push(words[index].text);
      }

      const auto refused = refusedArgument(*spec, arguments.view(), state.scratch.lend());
      if (!refused) {
        return ds::none;
      }

      const auto source = words[command_word + 1 + *refused].source;

      return Range{source.begin, source.end};
    }

  }

  ds::Option<std::pair<std::size_t, std::size_t>> rejectedOption(State& state, PaneLine& line, shell::Dialect dialect) {
    const auto revision = line.line.revision();
    const auto specs_revision = state.specs.revision();
    if (line.rejected && line.rejected->line == revision && line.rejected->specs == specs_revision) {
      return line.rejected->option;
    }

    const auto found = findRejected(state, line.pane_id, line.line.editor().text().view(), dialect);

    line.rejected = PaneLine::Rejected{.line = revision, .specs = specs_revision, .option = found};
    return found;
  }

}
