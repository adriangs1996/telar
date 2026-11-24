export module telar.gui.features.prompt:completion;

import std;
import telar.tbc;

import telar.shell.syntax;
import telar.ebnf.matcher;
import telar.base.ds;
import telar.base.memory.allocators;

// Tab completion for telar's command editor: the shell lexer finds the command and the word
// under the cursor, and the command's EBNF spec says what may come there. Literal choices are
// known at once; the ones a spec leaves to a provider, files and directories, the session
// asks the runtime for, since the files live where the shell runs.
export namespace telar::gui::features::prompt {

  struct Choice {
    tbc::val_a<ds::String<Memory>> text;
    tbc::val_a<ds::String<Memory>> description;
    bool directory = false;
    // An option whose value follows in the same word, as `--color=`: no space after it.
    bool joined = false;

    // The copy lives in the strings' memory, region `a`, and borrows nothing else of this choice.
    [[nodiscard]] tbc::val_a<Choice> clone() const;
  };

  using Choices = ds::Vec<Choice, Memory>;

  // The commands people typed, oldest first, which the suggestions and completion read.
  using History = std::span<const ds::String<Memory>>;

  struct CompletionContext {
    explicit CompletionContext(Memory& memory);

    // The command's name, without its directory, as specs are named.
    ds::String<Memory> command;
    // The arguments before the word being completed, unquoted.
    ds::Vec<ds::String<Memory>, Memory> words;
    // The unquoted text of that word before the cursor.
    ds::String<Memory> partial;
    std::size_t replace_begin = 0;
    std::size_t replace_end = 0;
    bool command_position = false;
  };

  tbc::val_a<ds::Option<CompletionContext>> completionContext(tbc::mut_a<Memory> memory, std::string_view text, std::size_t cursor, shell::Syntax syntax);

  struct Completion {
    explicit Completion(Memory& memory);

    Choices choices;
    // Providers the spec expects at the cursor, by name, for the caller to resolve.
    ds::Vec<ds::String<Memory>, Memory> providers;
    // What a provider's values are written after, as `--git-dir=` before a directory.
    ds::String<Memory> provider_prefix;
  };

  // The literal choices and the providers for `context`, from the command's `spec` when the
  // runtime has one for it. At a command's position, the commands in `history` whose names start
  // with the partial word; the runtime adds the ones the shell runs.
  tbc::val_a<Completion> complete(tbc::mut_a<Memory> memory, const CompletionContext& context, const ebnf::command_spec* spec, ebnf::match_scratch& scratch, History history);

  // Writes `text` as one shell word: characters the shell would read specially are escaped.
  tbc::val_a<ds::String<Memory>> quoteWord(tbc::mut_a<Memory> memory, std::string_view text, shell::Dialect dialect);

}
