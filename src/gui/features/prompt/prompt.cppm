module;
#include "tbc/annotations.hpp"

// telar's command editor in each pane: the line being written or queued and the keys that edit
// it, Tab's completion, whether the shell runs the command being typed, the commands the
// suggestions read, and the command block selected from the line.
export module telar.gui.features.prompt;

export import :keys;
export import :routing;
export import :layout;
export import :completion;
export import :menu;
// Exported as every interface partition must be; they export nothing.
export import :text;
export import :editor;
export import :specs;
export import :line;

import std;
import telar.tbc;

import telar.gui.foundation.core;
import telar.shell.syntax;
import telar.wire.editor;
import telar.wire.history;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.ds;

export namespace telar::gui::features::prompt {

  // Whether the shell runs a command word: asked of the runtime, pending until it answers,
  // unknown where it cannot tell (a remote shell, names it never reported).
  enum class CommandPresence : std::uint8_t {
    unknown,
    pending,
    found,
    missing,
  };

  // Whether the runtime has a completion spec for a command: asked, held, or not to be had.
  enum class SpecState : std::uint8_t {
    pending,
    available,
    unavailable,
  };

  // What decides which commands a pane's shell runs: the commands it ran and the directory it is
  // in. What the pane learned of its commands is forgotten when either changes.
  struct Commands {
    std::uint64_t pane_id = 0;
    std::uint32_t commands = 0;
    std::string_view directory;
  };

}

namespace telar::gui::features::prompt {

  // What State keeps for each question in flight and each pane's commands.
  using Name = ds::String<Memory>;

  struct PathCompletion {
    std::uint64_t pane_id;
    Name base;
    Name query;
  };

  struct CommandRequest {
    std::uint64_t pane_id;
    Name word;
  };

  struct CommandChecks {
    explicit CommandChecks(Memory& memory);

    std::uint32_t commands = 0;
    Name directory;
    ds::Map<Name, CommandPresence, Memory> words;
    // Every command that starts with a prefix, from an answer that listed them all: a longer
    // word typed under it is found or missing at once, without asking again.
    ds::Map<Name, ds::Vec<Name, Memory>, Memory> listed;
    // Commands seen running, kept across commands; a set, so each maps to nothing.
    ds::Map<Name, bool, Memory> learned;
    // Whether the runtime has a spec for each command asked about, and what each alias
    // among them stands for.
    ds::Map<Name, SpecState, Memory> specs;
    ds::Map<Name, Name, Memory> aliases;
    // The command each alias last stood for, kept across commands for the digest it asks with.
    ds::Map<Name, Name, Memory> alias_targets;
  };

}

export namespace telar::gui::features::prompt {

  // A pane's line: the editor, the queue, when the pane last printed, and the command block
  // selected from it. Opaque: only the use cases below reach it. It stays where it is until its
  // pane is forgotten.
  struct PaneLine {
    PaneLine(Memory& memory, std::uint64_t pane_id, Keymap keymap)
        : line(memory, keymap),
          pane_id(pane_id),
          jumps(memory) {}

    Line line;
    std::uint64_t pane_id;
    std::int64_t output = 0;
    // The command block selected from the editor's normal mode, by its index among the pane's
    // blocks, and the row the live prompt started on when the selection began.
    ds::Option<std::size_t> block;
    ds::Option<std::uint32_t> live_prompt;
    // The first half of `[[`, `]]`, `[f`, `]f`, `gg`, `z.` or `yc`.
    char chord = 0;
    // Where jumps left from, by stable row at the view's top, oldest first, and which of them
    // Ctrl-O went back to: the list's end while it has not.
    ds::Vec<std::uint64_t, Memory> jumps;
    std::size_t jump = 0;
  };

  // What ui reads of a pane's line: a view of it and of the commands its suggestions read, valid
  // until a use case changes them. Inline, as a line's view reads it whenever it draws.
  class LineView {
  public:
    LineView(tbc::view<const Line&, tbc::lt::a> line, tbc::view<History, tbc::lt::a> history) noexcept
        : line_(&line),
          history_(history) {}

    [[nodiscard]] TBC_HOT_PATH tbc::view<std::string_view, tbc::lt::a> text() const noexcept {
      return line_->editor().text().view();
    }

    [[nodiscard]] TBC_HOT_PATH std::size_t cursor() const noexcept {
      return line_->editor().text().cursor();
    }

    // The other end of the selection; the cursor without one.
    [[nodiscard]] TBC_HOT_PATH std::size_t anchor() const noexcept {
      return line_->editor().text().anchor();
    }

    [[nodiscard]] TBC_HOT_PATH Keymap keymap() const noexcept {
      return line_->editor().keymap();
    }

    [[nodiscard]] TBC_HOT_PATH Mode mode() const noexcept {
      return line_->editor().mode();
    }

    // An operator or count of vim's waits for the rest of its command.
    [[nodiscard]] TBC_HOT_PATH bool commandPending() const noexcept {
      return line_->editor().pending();
    }

    // The command typed while another runs waits for it; Enter arms it to run when that one
    // succeeds.
    [[nodiscard]] TBC_HOT_PATH bool queued() const noexcept {
      return line_->queued();
    }

    // While a program runs, typed lines go to it instead of the queue.
    [[nodiscard]] TBC_HOT_PATH bool answering() const noexcept {
      return line_->answering();
    }

    [[nodiscard]] TBC_HOT_PATH std::uint32_t secretKeys() const noexcept {
      return line_->secretKeys();
    }

    [[nodiscard]] TBC_HOT_PATH tbc::view<const ds::Option<Menu>&, tbc::lt::a> menu() const noexcept {
      return line_->menu();
    }

    // Moves with every change to what the line shows.
    [[nodiscard]] TBC_HOT_PATH std::uint64_t revision() const noexcept {
      return line_->revision();
    }

    // The commands sent from this line, oldest first.
    [[nodiscard]] TBC_HOT_PATH tbc::view<History, tbc::lt::a> recent() const noexcept {
      return line_->recent();
    }

    // Whether the menu still waits for the answer to request `request`.
    [[nodiscard]] TBC_HOT_PATH bool pending(std::uint64_t request) const noexcept {
      return line_->pending(request);
    }

    // The rest of a command this one starts: from what this line sent, then from the history.
    // Only while typing at the end of a line of two characters or more.
    [[nodiscard]] TBC_HOT_PATH tbc::view<std::string_view, tbc::lt::a> suggestion() const noexcept {
      return line_->suggestion(history_);
    }

    // The same for every view of one line, for a view to tell when the line it shows changed: an
    // address compared, never followed, as Rust's `*const ()`.
    [[nodiscard]] TBC_HOT_PATH TBC_RAW const void* identity() const noexcept {
      return line_;
    }

  private:
    tbc::view<const Line*, tbc::lt::a> line_;
    tbc::view<History, tbc::lt::a> history_;
  };

  // The questions Tab asks the runtime, and the choices known at once. Opaque: application asks
  // each question under an id of its own (request, sent), then offers the plan to the line.
  struct CompletionPlan {
    // Files or directories under the directory typed, then each provider the spec names.
    static constexpr std::size_t maximum_questions = 11;

    explicit CompletionPlan(Memory& memory);

    struct Question {
      explicit Question(Memory& memory)
          : root(memory),
            query(memory),
            base(memory) {}

      bool paths = false;
      PathKindFilter kind = PathKindFilter::any;
      CompletionProvider provider = CompletionProvider::command;
      // The directory a path search reads, or the prefix a provider's words start with.
      Name root;
      Name query;
      // What the answers are written after: the word's text before the part searched for.
      Name base;
      std::uint64_t request_id = 0;
    };

    CompletionContext context;
    Completion completion;
    Name label;
    shell::Dialect dialect = shell::Dialect::posix;
    // At most maximum_questions.
    ds::Vec<Question, Memory> questions;
  };

  // A pane's line, and whether it was made while no history arrived: the history is to be asked
  // for then, for the suggestions to read.
  struct Opened {
    PaneLine& line;
    bool wants_history = false;
  };

  // What an answer about a command the line marks found, once its question is settled.
  struct Settled {
    std::uint64_t pane_id = 0;
    Name word;
    CommandPresence presence = CommandPresence::unknown;
  };

  // Every pane's line and what they asked the runtime for. Its fields are the use cases' own, which
  // take the ones they need apart, as Rust borrows a struct's fields; ui goes through the use cases
  // below.
  struct State {
    // The suggestions read the whole history on every refresh: commands run since it loaded
    // replace the oldest instead of growing it for as long as the client lives.
    static constexpr std::uint16_t history_limit = 1000;

    // Every line and what it asks for live in `memory`.
    explicit State(tbc::view<Memory&, tbc::lt::a> memory);

    // Everything below lives in memory's region.
    tbc::view<Memory&, tbc::lt::a> memory;
    tbc::view<Specs, tbc::lt::a> specs;
    // Apart from the specs, so a spec read from them is matched with it.
    tbc::view<MatchScratch, tbc::lt::a> scratch;
    tbc::view<ds::Vec<Name, Memory>, tbc::lt::a> history;
    std::uint64_t history_request = 0;
    tbc::view<ds::Map<std::uint64_t, PathCompletion, Memory>, tbc::lt::a> completions;
    tbc::view<ds::Map<std::uint64_t, CommandRequest, Memory>, tbc::lt::a> command_requests;
    tbc::view<ds::Map<std::uint64_t, CommandChecks, Memory>, tbc::lt::a> command_checks;
    tbc::view<ds::Map<std::uint64_t, CommandRequest, Memory>, tbc::lt::a> spec_requests;
    // Tab pressed while a pane waited for a spec: the line it completes, by pane.
    tbc::view<ds::Map<std::uint64_t, Name, Memory>, tbc::lt::a> spec_completions;
    // The directory a question about a command named by its path reads, while it is sent.
    tbc::view<Name, tbc::lt::a> command_root;
    std::uint64_t written = 0;
  };

  // Each pane's line in an allocation of its own, so it stays where it is as others come and go.
  // Apart from the State, so a use case edits a line while it reads the editor's history or asks
  // for completions.
  using Lines = ds::Map<std::uint64_t, ds::Box<PaneLine, Memory>, Memory>;

  // ---- lines ------------------------------------------------------------------------------------

  // Pane `pane_id`'s line, made on first use, in `keymap`.
  [[nodiscard]] tbc::view<Opened, tbc::lt::a> open(State& state, tbc::view<Lines&, tbc::lt::a> lines, std::uint64_t pane_id, Keymap keymap);

  [[nodiscard]] TBC_HOT_PATH inline PaneLine* find(Lines& lines, std::uint64_t pane_id) noexcept;

  [[nodiscard]] TBC_HOT_PATH inline tbc::view<ds::Option<LineView>, tbc::lt::a> line(tbc::view<const State&, tbc::lt::a> state, tbc::view<const Lines&, tbc::lt::a> lines, std::uint64_t pane_id) noexcept;

  [[nodiscard]] TBC_HOT_PATH inline tbc::view<LineView, tbc::lt::a> view(tbc::view<const State&, tbc::lt::a> state, tbc::view<const PaneLine&, tbc::lt::a> line) noexcept;

  // The commands people typed, most recent first and each once, which the suggestions read.
  [[nodiscard]] TBC_HOT_PATH inline History history(const State& state) noexcept;

  // Pane `pane_id` printed now, as `now` reads the clock, only for a pane with a line: a program
  // quiet since may be asking a question.
  template <typename Now>
  TBC_GENERIC void output(Lines& lines, std::uint64_t pane_id, Now&& now) noexcept;

  // Pane `pane_id` is gone: its line and what it asked for go with it.
  void forget(State& state, Lines& lines, std::uint64_t pane_id) noexcept;

  // ---- keys and text ----------------------------------------------------------------------------

  // Whether a key typed while a program runs reaches the program instead of the queue: the signal
  // and end-of-file keys of `shell`'s line discipline, and any key while the program seems to ask
  // a question, its cursor at `cursor_column` and quiet since its last output. `now` reads the
  // clock, only when the line is empty.
  template <typename Now>
  [[nodiscard]] TBC_GENERIC bool toProgram(const PaneLine& line, const KeyPress& key, const PaneShell& shell, std::uint32_t cursor_column, Now&& now);

  // A key in the line: the action `configuration` binds to it in the editor's mode, or the
  // editor's own. Enter continues a command the `dialect`'s shell would read more of.
  [[nodiscard]] TBC_HOT_PATH inline Outcome press(const State& state, PaneLine& line, Surface surface, const KeyPress& key, const PromptConfiguration& configuration, shell::Dialect dialect);

  // What the line hands its owner with `run`, `answer` or `bytes`: the command, the answer or the
  // keys. Valid until the line's next key.
  [[nodiscard]] TBC_HOT_PATH inline std::string_view delivery(const PaneLine& line) noexcept;

  // `command` ran from a line: every pane's suggestions know it at once, without asking the
  // history again.
  void remember(State& state, std::string_view command);

  // Text an input method committed or a paste, into the line. Controls other than newline and tab
  // are dropped: they would act on the shell instead of being written.
  void insert(State& state, PaneLine& line, std::string_view text);

  // `command` replaces the line, the caret at its end, as a history entry pasted does.
  void write(State& state, PaneLine& line, std::string_view command);

  // `text` over `word`, which starts at `begin` of pane `pane_id`'s line, while the caret is right
  // after it; false when the line no longer holds it there.
  bool replace(State& state, Lines& lines, std::uint64_t pane_id, std::size_t begin, std::string_view word, std::string_view text);

  // The pane whose line took text from outside the keyboard (a paste, a history entry, a
  // suggestion, a path) since the last call, for its view to show it.
  [[nodiscard]] ds::Option<std::uint64_t> takeWrite(State& state) noexcept;

  // A key at a secret prompt, `byte` the first it sends: one more dot, or none after an erase.
  TBC_HOT_PATH inline void typeSecret(PaneLine& line, char byte) noexcept;

  // The pane's shell went from `previous` to `current`: a secret prompt ends once it echoes again,
  // and back at its prompt the command queued runs if the last one succeeded. What the line
  // hands its owner then; none while the shell was not back.
  [[nodiscard]] ds::Option<Outcome> follow(PaneLine& line, const PaneShell& previous, const PaneShell& current);

  // The system clipboard behind vim's "+ and "* registers.
  void useClipboard(tbc::view<PaneLine&, tbc::lt::a> line, tbc::view<Clipboard, tbc::lt::a> clipboard);

  // ---- the commands the shell runs --------------------------------------------------------------

  // What the shell of `commands`' pane is known to run of `word`; none when only the runtime can
  // tell.
  [[nodiscard]] ds::Option<CommandPresence> presence(State& state, const Commands& commands, std::string_view word);

  using CommandQuery = std::variant<CompleteWords, FindPaths>;

  // The question about `word` under `request_id`: the commands that start with it, or for a
  // command named by its path, the files in its directory. None when the path names nothing to
  // look for. It views `word`, and for a path the directory it writes in `root`, the state's
  // command_root.
  [[nodiscard]] tbc::view<ds::Option<CommandQuery>, tbc::lt::b> ask(tbc::view<Name&, tbc::lt::b> root, const Commands& commands, tbc::view<std::string_view, tbc::lt::b> word, std::uint64_t request_id);

  // The question `request_id` about `word` went out, `sent`, and `word` waits for its answer; or
  // it could not, and `word` stays unknown.
  void asked(State& state, std::uint64_t pane_id, std::string_view word, std::uint64_t request_id, bool sent);

  // A command ran in pane `pane_id` without the shell finding it missing: it exists, as the
  // `dialect`'s shell reads the first command of `command`.
  void learn(State& state, std::uint64_t pane_id, std::string_view command, shell::Dialect dialect);

  // What an answer to a question about a command found; none when the answer is not one.
  [[nodiscard]] tbc::view<ds::Option<Settled>, tbc::lt::a> settles(State& state, const CompletionWords& message);

  [[nodiscard]] tbc::view<ds::Option<Settled>, tbc::lt::a> settles(State& state, const PathResults& message);

  // The word `settled` names is marked; true when its pane's line shows the change.
  bool settle(State& state, const Settled& settled);

  // ---- completion specs -------------------------------------------------------------------------

  // Whether the runtime has a spec for `command` in `commands`' pane; none when it must be asked:
  // once per command until the shell's next command.
  [[nodiscard]] ds::Option<SpecState> spec(State& state, const Commands& commands, std::string_view command);

  // The question for `command`'s spec under `request_id`, with the digest of the spec held
  // already. It views `command` and the state until the next use case.
  [[nodiscard]] tbc::view<RequestCommandSpec, tbc::lt::b> askSpec(const State& state, std::uint64_t pane_id, tbc::view<std::string_view, tbc::lt::b> command, std::uint64_t request_id) noexcept;

  // The question `request_id` for `command`'s spec went out, `sent`, and waits; or it could not,
  // and no spec is to be had.
  void askedSpec(State& state, std::uint64_t pane_id, std::string_view command, std::uint64_t request_id, bool sent);

  // A spec arrived: the pane it was asked for, whose Tab may complete now (resume); none when it
  // was not asked for.
  [[nodiscard]] ds::Option<std::uint64_t> receive(State& state, const CommandSpec& message);

  // Whether a Tab pressed while pane `pane_id` waited for a spec completes now: the line is still
  // the one it was pressed on.
  [[nodiscard]] bool resume(State& state, Lines& lines, std::uint64_t pane_id);

  // ---- completion -------------------------------------------------------------------------------

  // Tab in the line: the word under the caret and the command it belongs to, as the `dialect`'s
  // shell reads them; none where nothing completes.
  [[nodiscard]] tbc::view<ds::Option<CompletionContext>, tbc::lt::a> completing(State& state, const PaneLine& line, shell::Dialect dialect);

  // Tab waits for the spec of the line's command, and completes once it arrives (resume).
  void awaitSpec(State& state, const PaneLine& line);

  // The choices for `context`: from the spec held for its command when `specified`, and, when
  // `asks`, what only the runtime knows (files under `directory`, commands, branches…).
  [[nodiscard]] tbc::view<CompletionPlan, tbc::lt::a> plan(State& state, const PaneLine& line, tbc::view<CompletionContext, tbc::lt::a> context, bool specified, bool asks, std::string_view directory, shell::Dialect dialect);

  [[nodiscard]] std::size_t questions(const CompletionPlan& plan) noexcept;

  // The `index`th question of the plan for pane `pane_id`, under `request_id`; it views the plan.
  [[nodiscard]] std::variant<FindPaths, CompleteWords> request(const CompletionPlan& plan, std::size_t index, std::uint64_t pane_id, std::uint64_t request_id) noexcept;

  // The `index`th question went out under `request_id`: its answer joins the choices.
  void sent(CompletionPlan& plan, std::size_t index, std::uint64_t request_id) noexcept;

  // The line offers the plan's choices: one is written at once, more open the menu.
  void offer(tbc::view<State&, tbc::lt::a> state, PaneLine& line, tbc::view<CompletionPlan, tbc::lt::a> plan);

  // An answer to a question Tab asked: the pane whose menu changed, 0 when none did, and none
  // when the answer is not one.
  [[nodiscard]] ds::Option<std::uint64_t> receive(tbc::view<State&, tbc::lt::a> state, tbc::view<Lines&, tbc::lt::a> lines, const CompletionWords& message);

  [[nodiscard]] ds::Option<std::uint64_t> receive(tbc::view<State&, tbc::lt::a> state, tbc::view<Lines&, tbc::lt::a> lines, const PathResults& message);

  // ---- requests that fail -----------------------------------------------------------------------

  // Request `request_id` failed, or a lost connection will never answer it: it settles as one that
  // found nothing. Its word stops waiting, its spec is unavailable and its menu stops expecting
  // it; none of them is an error the user should read. The pane whose line changed, 0 when none
  // did, and none when the request is not the line's.
  [[nodiscard]] ds::Option<std::uint64_t> fail(tbc::view<State&, tbc::lt::a> state, tbc::view<Lines&, tbc::lt::a> lines, std::uint64_t request_id);

  // Every question in flight fails.
  void failAll(State& state, Lines& lines) noexcept;

  // ---- the history the suggestions read --------------------------------------------------------

  // Whether the history is on its way.
  [[nodiscard]] bool historyAsked(const State& state) noexcept;

  // The question for the commands people typed, most recent first and each once.
  [[nodiscard]] QueryHistory historyQuery(std::uint64_t request_id) noexcept;

  void askedHistory(State& state, std::uint64_t request_id) noexcept;

  // Whether `message` answers the question for the history; the history is replaced when it does.
  bool receive(State& state, const HistoryResults& message);

  // ---- the command block selected from the line -------------------------------------------------

  [[nodiscard]] ds::Option<std::size_t> selectedBlock(const Lines& lines, std::uint64_t pane_id) noexcept;

  [[nodiscard]] ds::Option<std::size_t> selectedBlock(const PaneLine& line) noexcept;

  // Block `index` is selected, or none: the line is back at the live end. `live_prompt` is the row
  // the live prompt starts on, kept from the first selection on.
  void selectBlock(PaneLine& line, ds::Option<std::size_t> index, ds::Option<std::uint32_t> live_prompt) noexcept;

  // The row the live prompt started on when the selection began.
  [[nodiscard]] ds::Option<std::uint32_t> livePrompt(const Lines& lines, std::uint64_t pane_id) noexcept;

  // The first key of a two-key command (`[[`, `gg`, `zt`, `yc`…), which the next key takes.
  void beginChord(PaneLine& line, char first) noexcept;

  [[nodiscard]] char takeChord(PaneLine& line) noexcept;

  // The view's top before a jump, `here` by stable row; the jumps Ctrl-O had gone back past are
  // dropped.
  void recordJump(PaneLine& line, std::uint64_t here);

  // Back to where the last jump left from, or forward again: the stable row the view's top goes
  // to; none at either end. `here` is the view's top now.
  [[nodiscard]] ds::Option<std::uint64_t> jump(PaneLine& line, std::uint64_t here, bool back);

}

namespace telar::gui::features::prompt {

  inline PaneLine* find(Lines& lines, std::uint64_t pane_id) noexcept {
    auto* found = lines.findMut(pane_id);

    return found == nullptr ? nullptr : &found->getMut();
  }

  inline tbc::view<LineView, tbc::lt::a> view(tbc::view<const State&, tbc::lt::a> state, tbc::view<const PaneLine&, tbc::lt::a> line) noexcept {
    return LineView{line.line, state.history.view()};
  }

  inline tbc::view<ds::Option<LineView>, tbc::lt::a> line(tbc::view<const State&, tbc::lt::a> state, tbc::view<const Lines&, tbc::lt::a> lines, std::uint64_t pane_id) noexcept {
    const auto* found = lines.find(pane_id);
    if (found == nullptr) {
      return ds::none;
    }

    return view(state, **found);
  }

  inline History history(const State& state) noexcept {
    return state.history.view();
  }

  template <typename Now>
  void output(Lines& lines, std::uint64_t pane_id, Now&& now) noexcept {
    if (auto* line = find(lines, pane_id)) {
      line->output = now();
    }
  }

  // The action bound to `key` in the editor's mode; defined with the use cases that are not on a
  // key's path.
  [[nodiscard]] ds::Option<Action> bound(const KeyPress& key, const Editor& editor, const PromptConfiguration& configuration);

  inline Outcome press(const State& state, PaneLine& line, Surface surface, const KeyPress& key, const PromptConfiguration& configuration, shell::Dialect dialect) {
    auto& edited = line.line;
    const auto syntax = shell::Syntax{.dialect = dialect};
    const auto incomplete = [&memory = state.memory, syntax](std::string_view text) {
      return prompt::incomplete(memory, text, syntax);
    };

    const auto action = bound(key, edited.editor(), configuration);

    return action ? edited.perform(surface, *action, incomplete, history(state)) : edited.press(surface, key, incomplete, history(state));
  }

  template <typename Now>
  bool toProgram(const PaneLine& line, const KeyPress& key, const PaneShell& shell, std::uint32_t cursor_column, Now&& now) {
    const auto& typed = line.line;
    if (typed.answering()) {
      return false;
    }

    // Signal and end-of-file keys always reach the program, as does typing while it seems to ask
    // a question.
    if (key.key == Key::character && key.modifiers.control && !key.modifiers.alt && key.character < 0x80) {
      const char control = static_cast<char>(key.character & 0x1f);
      if (controlKey(shell, {&control, 1})) {
        return true;
      }
    }

    return typed.editor().text().empty() && PendingPrompt::likely(cursor_column, std::chrono::nanoseconds{now() - line.output});
  }

  inline std::string_view delivery(const PaneLine& line) noexcept {
    return line.line.delivery();
  }

  inline void typeSecret(PaneLine& line, char byte) noexcept {
    const auto value = static_cast<unsigned char>(byte);
    auto& typed = line.line;

    if (value == 0x7f || value == 0x08 || value == 0x15) {
      typed.clearSecret();
    } else if (value >= 0x20) {
      typed.countSecretKey();
    }
  }

}
