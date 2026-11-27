// telar's command editor as ui drives it: who has a pane's keyboard, the keys and text its line
// takes, what the line shows and suggests, and whether its shell runs the command being typed.
export module telar.gui.application:prompt;

import std;

import :session;
import telar.gui.features.prompt;
import telar.wire.editor;
import telar.wire.pane_io;
import telar.base.ds;

export namespace telar::gui::application::prompt {

  using features::prompt::Action;
  using features::prompt::CellRange;
  using features::prompt::Choice;
  using features::prompt::classify;
  using features::prompt::CommandPresence;
  using features::prompt::hiddenMarks;
  using features::prompt::HistoryMatchRanges;
  using features::prompt::Key;
  using features::prompt::Keymap;
  using features::prompt::KeyPress;
  using features::prompt::Layout;
  using features::prompt::layout;
  using features::prompt::LineView;
  using features::prompt::Menu;
  using features::prompt::menuMatch;
  using features::prompt::Mode;
  using features::prompt::Modifiers;
  using features::prompt::offsetAt;
  using features::prompt::Outcome;
  using features::prompt::Recalled;
  using features::prompt::Run;
  using features::prompt::Style;
  using features::prompt::Surface;
  using features::prompt::Surrounding;
  using features::prompt::surrounding;

  // Who has pane `pane_id`'s keyboard: the terminal, or telar's editor at the shell's prompt, the
  // queue while a command runs, or the program behind a secret prompt.
  [[nodiscard]] Surface surface(const Session& session, std::uint64_t pane_id) noexcept;

  // Whether text meant for the pane belongs in telar's editor instead. While a program runs, the
  // editor still decides, key by key, which of them answer it (key, toProgram).
  [[nodiscard]] bool edits(const Session& session, std::uint64_t pane_id) noexcept;

  // Whether text an input method committed or a paste, meant for the editor, goes to the running
  // program instead, as its keys would: it answers the question the program seems to ask.
  [[nodiscard]] bool toProgram(Session& session, std::uint64_t pane_id, std::string_view text);

  // Whether the terminal's cursor marks a place no key reaches, so it is not drawn: at the prompt
  // telar's editor has the keys; while a command runs, typing queues the next one unless the
  // program seems to ask for input (its cursor past a line's start, as routing judges); and
  // between a command's end and the next prompt the editor is about to take its row. Drawing it
  // there flashes a block for a frame or two under every quick command's output.
  [[nodiscard]] bool hidesTerminalCursor(const Session& session, std::uint64_t pane_id) noexcept;

  [[nodiscard]] ds::Option<LineView> line(const Session& session, std::uint64_t pane_id) noexcept;

  // The rest of a command the pane's line starts, from what it sent and the history.
  [[nodiscard]] std::string_view suggestion(const Session& session, std::uint64_t pane_id) noexcept;

  // The commands people typed, most recent first and each once, which the suggestions read.
  [[nodiscard]] features::prompt::Recalled history(const Session& session) noexcept;

  // A key for the pane's editor or queue. `terminal` hands it back to the terminal.
  Outcome key(Session& session, std::uint64_t pane_id, const KeyPress& key);

  // Text an input method committed or a paste, into the editor. Controls other than newline and
  // tab are dropped: they would act on the shell instead of being written. Text the line cannot
  // hold is refused whole, with a notice of the limit.
  void text(Session& session, std::uint64_t pane_id, std::string_view text);

  // Edits macOS's Command keys make that no keymap has a key for.
  enum class TextCommand : std::uint8_t {
    // Command+A: the whole command selected.
    select_all,
    // Command+Shift+Z: a change undone, done again.
    redo,
    // Command+X, once the selection is copied: the selection erased.
    erase_selection,
  };

  void textCommand(Session& session, std::uint64_t pane_id, TextCommand command);

  // A click in the editor: the cursor at byte `offset` of the command.
  void placeCursor(Session& session, std::uint64_t pane_id, std::size_t offset);

  // An input method reconverted bytes [begin, end) of the command into `text`, as a paste
  // writes it there; the caret after it.
  void reconvert(Session& session, std::uint64_t pane_id, Surrounding replaced, std::string_view text);

  // The text selected in the pane's editor, for Command+C and Command+X; empty without one.
  [[nodiscard]] std::string_view selectedText(const Session& session, std::uint64_t pane_id) noexcept;

  // Whether the pane's shell runs `word`, for the editor to mark a command that does not exist.
  // Asks the runtime the first time and answers pending until it replies; a remote shell's
  // commands are unknown. Forgotten after each command and change of directory.
  CommandPresence commandPresence(Session& session, std::uint64_t pane_id, std::string_view word);

  // The bytes [first, second) of the first option the pane's command does not accept, as a spec
  // that lists them all says (features::prompt::rejectedOption); none to mark.
  [[nodiscard]] ds::Option<std::pair<std::size_t, std::size_t>> rejectedOption(Session& session, std::uint64_t pane_id);

  // The pane whose editor took text from outside the keyboard (a paste, a history entry, a
  // suggestion, a path) since the last call, for its view to show it.
  [[nodiscard]] ds::Option<std::uint64_t> takeWrite(Session& session) noexcept;

}

// What the session's routing and the other use cases reach of the prompt; ui never calls these.
namespace telar::gui::application::prompt {

  // Pane `pane_id`'s line, made on first use in the configured keymap; a line made before the
  // history arrived asks for it, for the suggestions.
  features::prompt::PaneLine& open(Session& session, std::uint64_t pane_id);

  // `command` replaces the line of pane `pane_id`, the caret at its end, as a history entry
  // pasted does.
  void write(Session& session, std::uint64_t pane_id, std::string_view command);

  // A key typed into the program behind a secret prompt, `byte` the first it sends.
  void typeSecret(Session& session, std::uint64_t pane_id, char byte);

  // The shell of pane `pane_id` went from `previous` to `current`.
  void follow(Session& session, std::uint64_t pane_id, const PaneShell& previous, const PaneShell& current);

  // The session connected again: a history its lines never got is asked for.
  void connected(Session& session);

  // The runtime reports what the shell's own line editor held when a command cleared it: the
  // pane's line takes it at the shell's next prompt, before what was typed there since.
  Change receive(Session& session, const PaneTypeahead& message);

  // The runtime's history changed: the commands Up walks are asked for again, and each line's
  // ranked suggestion too.
  Change receive(Session& session, const HistoryChanged& message);

  // A line's ranked suggestion, or the commands the suggestions and Up read; none when the
  // answer is neither, for the history browser.
  ds::Option<Change> receive(Session& session, const HistoryResults& message);

  // Tells the runtime whether telar's editor stands in for the shell's prompt: the shells of the
  // panes it opens from now on print no prompt of their own. A cqp00002 runtime cannot hear it.
  void configureShell(Session& session);

  Change receive(Session& session, const CommandSpec& message);

  Change receive(Session& session, const CompletionWords& message);

  // None when the paths are not the line's.
  ds::Option<Change> receive(Session& session, const PathResults& message);

  // The runtime typed a command a line sent: true when it was one.
  bool completed(Session& session, std::uint64_t request_id);

  // A request of the prompt failed: a command the pane refused comes back into its line, with a
  // notice of why.
  ds::Option<Change> fail(Session& session, const RequestFailed& message);

}
