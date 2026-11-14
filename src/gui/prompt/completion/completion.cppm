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

  std::optional<CompletionContext> completionContext(std::string_view text, std::size_t cursor, shell::Syntax syntax);

  // The specs the runtime sent, compiled, by the command they describe: the runtime holds
  // the catalogue and answers for the commands a pane's shell runs.
  class Specs {
  public:
    static constexpr std::size_t capacity = 256;

    const ebnf::command_spec* find(std::string_view command) const;

    // The digest of the spec held for `command`, or 0.
    std::uint64_t digest(std::string_view command) const;

    // Compiles and keeps `source`; a spec that does not compile is dropped.
    bool install(std::string_view command, std::uint64_t digest, std::string_view source);

    ebnf::match_scratch& scratch();

  private:
    struct Entry {
      std::uint64_t digest = 0;
      std::unique_ptr<ebnf::command_spec> spec;
    };

    struct Hash {
      using is_transparent = void;

      std::size_t operator()(std::string_view text) const noexcept;
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
  Completion complete(const CompletionContext& context, const ebnf::command_spec* spec, ebnf::match_scratch& scratch, std::span<const std::string> history);

  // Writes `text` as one shell word: characters the shell would read specially are escaped.
  std::string quoteWord(std::string_view text, shell::Dialect dialect);

}
