module;

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
    PaneLine(Memory& memory, std::uint64_t pane, Keymap keymap);

    Line line;
    std::uint64_t pane_id;
    std::int64_t output = 0;
    // A key typed at a program's question reached it: the rest of the answer follows, whatever
    // the echo of each key prints, until Enter, a signal or end-of-file key, or the program
    // stops reading a line.
    bool forwarding = false;
    // The command the queue waits for ended well: the shell may report its end before it is
    // back at its prompt, where the queued command runs.
    bool succeeded = false;
    // When the shell reported a command's end without its prompt back yet, as `now` reads the
    // clock: keys typed in between wait in the line, for a while. None outside that gap.
    ds::Option<std::int64_t> ended;
    // The command block selected from the editor's normal mode, by its index among the pane's
    // blocks, and the row the live prompt started on when the selection began.
    ds::Option<std::size_t> block;
    ds::Option<std::uint32_t> live_prompt;
    // The pointer selected the block: the keys that type still go to the editor.
    bool block_by_pointer = false;
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
    [[tbc::hot_path]] inline LineView(tbc::ref_a<Line> line, tbc::val_a<History> history) noexcept
        : line_(&line),
          history_(history) {}

    [[nodiscard]] [[tbc::hot_path]] inline tbc::val_a<std::string_view> text() const noexcept {
      return line_->editor().text().view();
    }

    [[nodiscard]] [[tbc::hot_path]] inline std::size_t cursor() const noexcept {
      return line_->editor().text().cursor();
    }

    // The other end of the selection; the cursor without one.
    [[nodiscard]] [[tbc::hot_path]] inline std::size_t anchor() const noexcept {
      return line_->editor().text().anchor();
    }

    // What vim's visual modes highlight, which is more than the selection; none outside them.
    [[nodiscard]] [[tbc::hot_path]] inline ds::Option<std::pair<std::size_t, std::size_t>> highlight() const noexcept {
      return line_->editor().visualRange();
    }

    [[nodiscard]] [[tbc::hot_path]] inline Keymap keymap() const noexcept {
      return line_->editor().keymap();
    }

    [[nodiscard]] [[tbc::hot_path]] inline Mode mode() const noexcept {
      return line_->editor().mode();
    }

    // An operator or count of vim's waits for the rest of its command.
    [[nodiscard]] [[tbc::hot_path]] inline bool commandPending() const noexcept {
      return line_->editor().pending();
    }

    // The command typed while another runs waits for it; Enter arms it to run when that one
    // succeeds.
    [[nodiscard]] [[tbc::hot_path]] inline bool queued() const noexcept {
      return line_->queued();
    }

    // While a program runs, typed lines go to it instead of the queue.
    [[nodiscard]] [[tbc::hot_path]] inline bool answering() const noexcept {
      return line_->answering();
    }

    [[nodiscard]] [[tbc::hot_path]] inline std::uint32_t secretKeys() const noexcept {
      return line_->secretKeys();
    }

    [[nodiscard]] [[tbc::hot_path]] inline tbc::ref_a<ds::Option<Menu>> menu() const noexcept {
      return line_->menu();
    }

    // Moves with every change to what the line shows.
    [[nodiscard]] [[tbc::hot_path]] inline std::uint64_t revision() const noexcept {
      return line_->revision();
    }

    // The commands sent from this line, oldest first.
    [[nodiscard]] [[tbc::hot_path]] inline tbc::val_a<History> recent() const noexcept {
      return line_->recent();
    }

    // Whether the menu still waits for the answer to request `request`.
    [[nodiscard]] [[tbc::hot_path]] inline bool pending(std::uint64_t request) const noexcept {
      return line_->pending(request);
    }

    // The rest of a command this one starts: from what this line sent, then from the history.
    // Only while typing at the end of a line of two characters or more.
    [[nodiscard]] [[tbc::hot_path]] inline tbc::val_a<std::string_view> suggestion() const noexcept {
      return line_->suggestion(history_);
    }

    // The same for every view of one line, for a view to tell when the line it shows changed: an
    // address compared, never followed, as Rust's `*const ()`.
    [[nodiscard]] [[tbc::hot_path]] [[tbc::raw]] inline const void* identity() const noexcept {
      return line_;
    }

  private:
    tbc::val_a<const Line*> line_;
    tbc::val_a<History> history_;
  };

  // The questions Tab asks the runtime, and the choices known at once. Opaque: application asks
  // each question under an id of its own (request, sent), then offers the plan to the line.
  struct CompletionPlan {
    // Files or directories under the directory typed, then each provider the spec names.
    static constexpr std::size_t maximum_questions = 11;

    explicit CompletionPlan(Memory& memory);

    struct Question {
      explicit Question(Memory& memory);

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

    // Every line and what it asks for live in `allocator`.
    explicit State(tbc::mut_a<Memory> allocator);

    // Everything below lives in memory's region.
    tbc::mut_a<Memory> memory;
    tbc::val_a<Specs> specs;
    // Apart from the specs, so a spec read from them is matched with it.
    tbc::val_a<MatchScratch> scratch;
    tbc::val_a<ds::Vec<Name, Memory>> history;
    std::uint64_t history_request = 0;
    // An answer to the history query arrived: until one does, it is asked again.
    bool history_loaded = false;
    tbc::val_a<ds::Map<std::uint64_t, PathCompletion, Memory>> completions;
    tbc::val_a<ds::Map<std::uint64_t, CommandRequest, Memory>> command_requests;
    tbc::val_a<ds::Map<std::uint64_t, CommandChecks, Memory>> command_checks;
    tbc::val_a<ds::Map<std::uint64_t, CommandRequest, Memory>> spec_requests;
    // Tab pressed while a pane waited for a spec: the line it completes, by pane.
    tbc::val_a<ds::Map<std::uint64_t, Name, Memory>> spec_completions;
    // The directory a question about a command named by its path reads, while it is sent.
    tbc::val_a<Name> command_root;
    std::uint64_t written = 0;
  };

  // Each pane's line in an allocation of its own, so it stays where it is as others come and go.
  // Apart from the State, so a use case edits a line while it reads the editor's history or asks
  // for completions.
  using Lines = ds::Map<std::uint64_t, ds::Box<PaneLine, Memory>, Memory>;

  // ---- lines ------------------------------------------------------------------------------------

  // Pane `pane_id`'s line, made on first use, in `keymap`.
  [[nodiscard]] tbc::val_a<Opened> open(State& state, tbc::mut_a<Lines> lines, std::uint64_t pane_id, Keymap keymap);

  [[nodiscard]] [[tbc::hot_path]] inline PaneLine* find(Lines& lines, std::uint64_t pane_id) noexcept;

  [[nodiscard]] [[tbc::hot_path]] inline tbc::val_a<ds::Option<LineView>> line(tbc::ref_a<State> state, tbc::ref_a<Lines> lines, std::uint64_t pane_id) noexcept;

  [[nodiscard]] [[tbc::hot_path]] inline tbc::val_a<LineView> view(tbc::ref_a<State> state, tbc::ref_a<PaneLine> line) noexcept;

  // The commands people typed, most recent first and each once, which the suggestions read.
  [[nodiscard]] [[tbc::hot_path]] inline History history(const State& state) noexcept;

  // Pane `pane_id` printed now, as `now` reads the clock, only for a pane with a line: a program
  // quiet since may be asking a question.
  template <typename Now>
  [[tbc::generic]] void output(Lines& lines, std::uint64_t pane_id, Now&& now) noexcept;

  // Pane `pane_id` is gone: its line and what it asked for go with it.
  void forget(State& state, Lines& lines, std::uint64_t pane_id) noexcept;

  // ---- keys and text ----------------------------------------------------------------------------

  // Whether a key typed while a program runs reaches the program instead of the queue: the signal
  // and end-of-file keys of `shell`'s line discipline, and any key while the program seems to ask
  // a question, its cursor at `cursor_column` and quiet since its last output. Once a key reached
  // it, the rest of the answer follows it until Enter: the echo of each key is output too, and
  // would send the next one to the queue. `now` reads the clock, only when the line is empty and
  // no answer is under way.
  template <typename Now>
  [[nodiscard]] [[tbc::generic]] bool toProgram(PaneLine& line, const KeyPress& key, const PaneShell& shell, std::uint32_t cursor_column, Now&& now);

  // Whether text an input method committed or a paste reaches the program instead of the queue,
  // as a key would: during an answer, or as its start. Only one line does (oneLine), and a line
  // end after it ends the answer.
  template <typename Now>
  [[nodiscard]] [[tbc::generic]] bool toProgram(PaneLine& line, std::string_view text, std::uint32_t cursor_column, Now&& now);

  // How the line reads a key: the bindings of `configuration`, and the `dialect` of the shell that
  // runs the command.
  struct KeyReading {
    const PromptConfiguration& configuration;
    shell::Dialect dialect = shell::Dialect::posix;
  };

  // A key in the line: the action the configuration binds to it in the editor's mode, or the
  // editor's own. Enter continues a command the dialect's shell would read more of.
  [[nodiscard]] [[tbc::hot_path]] inline Outcome press(const State& state, PaneLine& line, Surface surface, const KeyPress& key, KeyReading reading);

  // What the line hands its owner with `run`, `answer` or `bytes`: the command, the answer or the
  // keys. Valid until the line's next key.
  [[nodiscard]] [[tbc::hot_path]] inline std::string_view delivery(const PaneLine& line) noexcept;

  // `command` ran from a line: every pane's suggestions know it at once, without asking the
  // history again.
  void remember(State& state, std::string_view command);

  // What the line handed over with `run` or `answer` reached its pane: the line clears and
  // remembers `command`, empty for an answer. A delivery that fails leaves the text in the line.
  void committed(PaneLine& line, std::string_view command);

  // Text an input method committed or a paste, into the line. Controls other than newline and tab
  // are dropped: they would act on the shell instead of being written.
  void insert(State& state, PaneLine& line, std::string_view text);

  // `command` replaces the line, the caret at its end, as a history entry pasted does.
  void write(State& state, PaneLine& line, std::string_view command);

  // A word of pane `pane_id`'s line, from byte `begin`.
  struct LineWord {
    std::uint64_t pane_id = 0;
    std::size_t begin = 0;
    std::string_view text;
  };

  // `text` over `word` while the caret is right after it; false when the line no longer holds it
  // there.
  bool replace(State& state, Lines& lines, const LineWord& word, std::string_view text);

  // The pane whose line took text from outside the keyboard (a paste, a history entry, a
  // suggestion, a path) since the last call, for its view to show it.
  [[nodiscard]] ds::Option<std::uint64_t> takeWrite(State& state) noexcept;

  // A key at a secret prompt, `byte` the first it sends: one more dot, or none after an erase.
  [[tbc::hot_path]] inline void typeSecret(PaneLine& line, char byte) noexcept;

  // The pane's shell went from `previous` to `current` at `now`: a secret prompt ends once it
  // echoes again, and back at its prompt, from a command or from the gap after its end, the
  // command queued runs if the last one succeeded. What the line hands its owner then; none
  // while the shell was not back.
  [[nodiscard]] ds::Option<Outcome> follow(PaneLine& line, const PaneShell& previous, const PaneShell& current, std::int64_t now);

  // Whether keys typed at `now` fall in the gap between a command's end and the shell's prompt,
  // which hooks such as direnv's can make long: the line takes them, as it does while a command
  // runs, instead of the shell's own line editor behind telar's. A gap longer than this is a
  // shell that stopped reporting its prompt, which gets the keys back.
  struct BetweenCommands {
    static constexpr std::chrono::milliseconds limit{2000};

    [[nodiscard]] static bool now(const PaneLine& line, std::int64_t now) noexcept;
  };

  // The system clipboard behind vim's "+ and "* registers.
  void useClipboard(tbc::mut_a<PaneLine> line, tbc::val_a<Clipboard> clipboard);

  // ---- the commands the shell runs --------------------------------------------------------------

  // What the shell of `commands`' pane is known to run of `word`; none when only the runtime can
  // tell.
  [[nodiscard]] ds::Option<CommandPresence> presence(State& state, const Commands& commands, std::string_view word);

  using CommandQuery = std::variant<CompleteWords, FindPaths>;

  // The question about `word` under `request_id`: the commands that start with it, or for a
  // command named by its path, the executables in its directory, which a runtime that
  // `reads_directories` lists and an older one searches for. None when the path names nothing to
  // look for. It views `word`, and for a search the directory it writes in `root`, the state's
  // command_root.
  [[nodiscard]] tbc::val_b<ds::Option<CommandQuery>> ask(tbc::mut_b<Name> root, const Commands& commands, tbc::val_b<std::string_view> word, std::uint64_t request_id, bool reads_directories);

  // The question `request_id` about `word` went out, `sent`, and `word` waits for its answer; or
  // it could not, and `word` stays unknown.
  void asked(State& state, std::uint64_t pane_id, std::string_view word, std::uint64_t request_id, bool sent);

  // A command ran in pane `pane_id` without the shell finding it missing: it exists, as the
  // `dialect`'s shell reads the first command of `command`.
  void learn(State& state, std::uint64_t pane_id, std::string_view command, shell::Dialect dialect);

  // What an answer to a question about a command found; none when the answer is not one.
  [[nodiscard]] tbc::val_a<ds::Option<Settled>> settles(State& state, const CompletionWords& message);

  [[nodiscard]] tbc::val_a<ds::Option<Settled>> settles(State& state, const PathResults& message);

  // The word `settled` names is marked; true when its pane's line shows the change.
  bool settle(State& state, const Settled& settled);

  // ---- completion specs -------------------------------------------------------------------------

  // Whether the runtime has a spec for `command` in `commands`' pane; none when it must be asked:
  // once per command until the shell's next command.
  [[nodiscard]] ds::Option<SpecState> spec(State& state, const Commands& commands, std::string_view command);

  // The question for `command`'s spec under `request_id`, with the digest of the spec held
  // already. It views `command` and the state until the next use case.
  [[nodiscard]] tbc::val_b<RequestCommandSpec> askSpec(const State& state, std::uint64_t pane_id, tbc::val_b<std::string_view> command, std::uint64_t request_id) noexcept;

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
  [[nodiscard]] tbc::val_a<ds::Option<CompletionContext>> completing(State& state, const PaneLine& line, shell::Dialect dialect);

  // Tab waits for the spec of the line's command, and completes once it arrives (resume).
  void awaitSpec(State& state, const PaneLine& line);

  // Where a plan's choices come from: the spec held for the command when `specified`, and, when
  // `asks`, what only the runtime knows (files under `directory`, commands, branches…), for the
  // `dialect`'s shell. A runtime that `reads_directories` lists the one directory a path names;
  // an older one is searched under it.
  struct CompletionSources {
    bool specified = false;
    bool asks = false;
    std::string_view directory;
    shell::Dialect dialect = shell::Dialect::posix;
    bool reads_directories = false;
    // The runtime names revisions, tags too, where a spec expects a @ref; an older one lists
    // branches there.
    bool reads_references = false;
  };

  // The choices for `context` in `line`, from `sources`.
  [[nodiscard]] tbc::val_a<CompletionPlan> plan(State& state, const PaneLine& line, tbc::val_a<CompletionContext> context, const CompletionSources& sources);

  [[nodiscard]] std::size_t questions(const CompletionPlan& plan) noexcept;

  // The `index`th question of pane `pane_id`'s plan, asked under `request_id`.
  struct Asking {
    std::uint64_t pane_id = 0;
    std::size_t index = 0;
    std::uint64_t request_id = 0;
  };

  // The question `asking` names; it views the plan.
  [[nodiscard]] std::variant<FindPaths, CompleteWords> request(const CompletionPlan& plan, Asking asking) noexcept;

  // The `index`th question went out under `request_id`: its answer joins the choices.
  void sent(CompletionPlan& plan, std::size_t index, std::uint64_t request_id) noexcept;

  // The line offers the plan's choices: one is written at once, more open the menu.
  void offer(tbc::mut_a<State> state, PaneLine& line, tbc::val_a<CompletionPlan> plan);

  // An answer to a question Tab asked: the pane whose menu changed, 0 when none did, and none
  // when the answer is not one.
  [[nodiscard]] ds::Option<std::uint64_t> receive(tbc::mut_a<State> state, tbc::mut_a<Lines> lines, const CompletionWords& message);

  [[nodiscard]] ds::Option<std::uint64_t> receive(tbc::mut_a<State> state, tbc::mut_a<Lines> lines, const PathResults& message);

  // Whether pane `pane_id`'s Tab asks again: an answer cut short arrived after typing narrowed
  // the word, and the choices it narrows to may be past the cut. Once per answer.
  [[nodiscard]] bool asksAgain(Lines& lines, std::uint64_t pane_id) noexcept;

  // ---- requests that fail -----------------------------------------------------------------------

  // Request `request_id` failed, or a lost connection will never answer it: it settles as one that
  // found nothing. Its word stops waiting, its spec is unavailable and its menu stops expecting
  // it; none of them is an error the user should read. The pane whose line changed, 0 when none
  // did, and none when the request is not the line's.
  [[nodiscard]] ds::Option<std::uint64_t> fail(tbc::mut_a<State> state, tbc::mut_a<Lines> lines, std::uint64_t request_id);

  // Every question in flight fails.
  void failAll(State& state, Lines& lines) noexcept;

  // ---- the history the suggestions read --------------------------------------------------------

  // Whether the history is on its way.
  [[nodiscard]] bool historyAsked(const State& state) noexcept;

  // Whether the history is to be asked for: no answer arrived and none is on its way, as after
  // a query that failed or a connection lost.
  [[nodiscard]] bool historyWanted(const State& state) noexcept;

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
  void selectBlock(PaneLine& line, ds::Option<std::size_t> index, ds::Option<std::uint32_t> live_prompt, bool by_pointer = false) noexcept;

  // The selected block is now at `index` among the pane's blocks, or gone: blocks before it were
  // dropped, or came again.
  void moveBlock(PaneLine& line, ds::Option<std::size_t> index) noexcept;

  // Whether the pointer selected the block, rather than a key.
  [[nodiscard]] bool blockByPointer(const PaneLine& line) noexcept;

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

  inline tbc::val_a<LineView> view(tbc::ref_a<State> state, tbc::ref_a<PaneLine> line) noexcept {
    return LineView{line.line, state.history.view()};
  }

  inline tbc::val_a<ds::Option<LineView>> line(tbc::ref_a<State> state, tbc::ref_a<Lines> lines, std::uint64_t pane_id) noexcept {
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
      line->output = std::forward<Now>(now)();
    }
  }

  // The action bound to `key` in the editor's mode; defined with the use cases that are not on a
  // key's path.
  [[nodiscard]] ds::Option<Action> bound(const KeyPress& key, const Editor& editor, const PromptConfiguration& configuration);

  inline Outcome press(const State& state, PaneLine& line, Surface surface, const KeyPress& key, KeyReading reading) {
    auto& edited = line.line;
    const auto syntax = shell::Syntax{.dialect = reading.dialect};
    const auto incomplete = [&memory = state.memory, syntax](std::string_view text) {
      return prompt::incomplete(memory, text, syntax);
    };

    const auto action = bound(key, edited.editor(), reading.configuration);

    return action ? edited.perform(surface, *action, incomplete, history(state)) : edited.press(surface, key, incomplete, history(state));
  }

  // An answer under way, or a program that seems to ask a question. The echo of each key it
  // takes is output too, so its quiet is only read before the first one.
  template <typename Now>
  [[tbc::generic]] bool answers(const PaneLine& line, std::uint32_t cursor_column, Now&& now) {
    if (line.forwarding) {
      return true;
    }

    return line.line.editor().text().empty() && PendingPrompt::likely(cursor_column, std::chrono::nanoseconds{std::forward<Now>(now)() - line.output});
  }

  template <typename Now>
  bool toProgram(PaneLine& line, const KeyPress& key, const PaneShell& shell, std::uint32_t cursor_column, Now&& now) {
    // Ctrl with an ASCII character types the control byte that shares its low five bits.
    constexpr char32_t ascii_end = 0x80;
    constexpr char32_t control_bits = 0x1f;

    // Signal and end-of-file keys always reach the program, even while the line composes an
    // answer, and end the line it was reading: an answer composed for it goes too, as the line
    // discipline drops what it had of the line.
    if (key.key == Key::character && key.modifiers.control && !key.modifiers.alt && key.character < ascii_end) {
      const char control = static_cast<char>(key.character & control_bits);
      if (controlKey(shell, {&control, 1})) {
        if (line.line.answering()) {
          line.line.committed({});
        }

        line.forwarding = false;
        return true;
      }
    }

    if (line.line.answering()) {
      return false;
    }

    // Enter on an empty line queues nothing: it is the program's, as for one that printed its
    // question on a line of its own (`echo "Press Enter"; read`), its cursor at the line's start.
    const bool enter = key.key == Key::enter && !key.modifiers.alt;
    if (enter && !line.forwarding && line.line.editor().text().empty()) {
      return true;
    }

    if (!answers(line, cursor_column, std::forward<Now>(now))) {
      return false;
    }

    line.forwarding = !enter;
    return true;
  }

  template <typename Now>
  bool toProgram(PaneLine& line, std::string_view text, std::uint32_t cursor_column, Now&& now) {
    if (line.line.answering() || !oneLine(text) || !answers(line, cursor_column, std::forward<Now>(now))) {
      return false;
    }

    line.forwarding = !text.ends_with('\n') && !text.ends_with('\r');
    return true;
  }

  inline std::string_view delivery(const PaneLine& line) noexcept {
    return line.line.delivery();
  }

  inline void typeSecret(PaneLine& line, char byte) noexcept {
    // DEL, Backspace and Ctrl-U erase what was typed; any other control types nothing.
    constexpr unsigned char delete_control = 0x7f;
    constexpr unsigned char backspace = 0x08;
    constexpr unsigned char kill_line = 0x15;
    constexpr unsigned char first_printable = 0x20;

    const auto value = static_cast<unsigned char>(byte);
    auto& typed = line.line;

    if (value == delete_control || value == backspace || value == kill_line) {
      typed.clearSecret();
    } else if (value >= first_printable) {
      typed.countSecretKey();
    }
  }

}
