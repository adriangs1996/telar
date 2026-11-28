export module telar.cli.commands.history.output;

import std;
import telar.cli.console.command_limit;
import telar.wire.vocabulary;
import telar.base.ds;

// How `telar history` prints the entries it reads: one line each, as text a person reads, as a
// JSON object a program parses, as a template the caller writes, or as the histfile of a shell.
export namespace telar::runtime::cli::history {

  enum class EntryStyle : std::uint8_t {
    text,
    json,
    // The caller's template: {id} {time} {timestamp} {duration} {exit} {status} {author}
    // {provider} {cwd} {workspace} {command}, and \t and \n.
    format,
    zsh,
    bash,
    fish,
  };

  // Throws std::invalid_argument("UnknownHistoryField") for a template naming a field that is not
  // one of those, or an unclosed brace.
  void checkTemplate(std::string_view text);

  // Prints one entry as `style` says; a field a terminal would act on, a command's newline among
  // them, prints escaped in the text and the template styles.
  void printEntry(DescriptorWriter& output, const HistoryEntry& entry, EntryStyle style, std::string_view format = {});

}
