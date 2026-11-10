module;
#include <cstddef>
#include <cstdint>

export module telar.gui.prompt.completion;

import std;

export import telar.shell.syntax;
export import telar.ebnf.matcher;

// Tab completion for telar's command editor: the shell lexer finds the command and the word
// under the cursor, and the command's EBNF spec says what may come there. Literal choices are
// known at once; the ones a spec leaves to a provider, files and directories, the session
// asks the runtime for, since the files live where the shell runs.
export namespace telar::gui::prompt {

struct Choice {
  std::string text;
  std::string description;
  bool directory = false;
};

struct CompletionContext {
  // The command's name, without its directory, as specs are named.
  std::string command;
  // The arguments before the word being completed, unquoted.
  std::vector<std::string> words;
  // The unquoted text of that word before the cursor.
  std::string partial;
  std::size_t replace_begin = 0;
  std::size_t replace_end = 0;
  bool command_position = false;
};

inline std::optional<CompletionContext> completionContext(std::string_view text, std::size_t cursor, shell::Syntax syntax) {
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

// The specs the runtime sent, compiled, by the command they describe: the runtime holds
// the catalogue and answers for the commands a pane's shell runs.
class Specs {
public:
  static constexpr std::size_t capacity = 256;

  inline const ebnf::command_spec *find(std::string_view command) const {
    const auto found = entries_.find(command);
    return found == entries_.end() ? nullptr : found->second.spec.get();
  }

  // The digest of the spec held for `command`, or 0.
  inline std::uint64_t digest(std::string_view command) const {
    const auto found = entries_.find(command);
    return found == entries_.end() ? 0 : found->second.digest;
  }

  // Compiles and keeps `source`; a spec that does not compile is dropped.
  inline bool install(std::string_view command, std::uint64_t digest, std::string_view source) {
    std::unique_ptr<ebnf::command_spec> spec;
    try {
      spec = std::make_unique<ebnf::command_spec>(ebnf::command_spec::compile(source));
    } catch (const std::exception &) {
      entries_.erase(std::string{command});
      return false;
    }
    if (entries_.size() >= capacity && !entries_.contains(command)) {
      entries_.clear();
    }
    entries_.insert_or_assign(std::string{command}, Entry{digest, std::move(spec)});
    return true;
  }

  inline ebnf::match_scratch &scratch() {
    if (!scratch_) {
      scratch_ = std::make_unique<ebnf::match_scratch>();
    }
    return *scratch_;
  }

private:
  struct Entry {
    std::uint64_t digest = 0;
    std::unique_ptr<ebnf::command_spec> spec;
  };

  struct Hash {
    using is_transparent = void;

    inline std::size_t operator()(std::string_view text) const noexcept {
      return std::hash<std::string_view>{}(text);
    }
  };

  std::unordered_map<std::string, Entry, Hash, std::equal_to<>> entries_;
  std::unique_ptr<ebnf::match_scratch> scratch_;
};

struct Completion {
  std::vector<Choice> choices;
  // Providers the spec expects at the cursor, by name, for the caller to resolve.
  std::vector<std::string> providers;
  // What a provider's values are written after, as `--git-dir=` before a directory.
  std::string provider_prefix;
};

// The literal choices and the providers for `context`, from the command's `spec` when the
// runtime has one for it. At a command's position, the commands in `history` whose names start
// with the partial word; the runtime adds the ones the shell runs.
inline Completion complete(const CompletionContext &context, const ebnf::command_spec *spec, ebnf::match_scratch &scratch, std::span<const std::string> history) {
  Completion result;
  const auto add = [&](std::string_view text, std::string_view description) {
    if (text.starts_with(context.partial) && std::ranges::none_of(result.choices, [&](const Choice &choice) { return choice.text == text; })) {
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
  for (const auto &candidate : std::span{candidates}.first(matched.count)) {
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

// Writes `text` as one shell word: characters the shell would read specially are escaped.
inline std::string quoteWord(std::string_view text, shell::Dialect dialect) {
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
