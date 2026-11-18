export module telar.gui.features.prompt:completion;

import std;

import telar.shell.syntax;
import telar.ebnf.matcher;
import telar.base.ds;

// Tab completion for telar's command editor: the shell lexer finds the command and the word
// under the cursor, and the command's EBNF spec says what may come there. Literal choices are
// known at once; the ones a spec leaves to a provider, files and directories, the session
// asks the runtime for, since the files live where the shell runs.
export namespace telar::gui::features::prompt {

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

  ds::Option<CompletionContext> completionContext(std::string_view text, std::size_t cursor, shell::Syntax syntax);

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
