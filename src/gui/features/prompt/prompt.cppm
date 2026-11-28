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
export import :recall;
export import :ranking;
export import :correction;

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

  // A command the shell did not find, whose word [begin, end) the runtime is asked about.
  struct Correction {
    std::uint64_t pane_id;
    Name command;
    std::size_t begin = 0;
    std::size_t end = 0;
    shell::Dialect dialect = shell::Dialect::posix;
  };

  // A command a line handed over that the runtime is yet to say it typed; `kept` when the
  // history filters let it be remembered.
  struct SentCommand {
    std::uint64_t pane_id;
    Name command;
    bool kept = false;
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
    // The line ran a command the recall remembers, whose end the shell has not reported yet.
    bool awaiting_end = false;
    // What the shell's own line editor held when a command cleared it (PaneTypeahead), for the
    // line to take at the next prompt.
    Name typeahead;
    // The question for the runtime's ranked suggestion in flight, 0 for none, and whether the
    // line changed since it was asked, so it is asked again once answered.
    std::uint64_t suggesting = 0;
    bool suggest_again = false;

    // The option rejectedOption found, for the revisions of the line and of the specs it read.
    struct Rejected {
      std::uint64_t line = 0;
      std::uint64_t specs = 0;
      ds::Option<std::pair<std::size_t, std::size_t>> option;
    };

    ds::Option<Rejected> rejected;
    // When the shell reported a command's end without its prompt back yet, as `now` reads the
    // clock: keys typed in between wait in the line, for a while. None outside that gap.
    ds::Option<std::int64_t> ended;
    // The command block selected from the editor's normal mode, by its index among the pane's
    // blocks.
    ds::Option<std::size_t> block;
    // The block was selected from outside the editor's keys, by a click or the window's own
    // step: the keys that type still go to the editor, and let the block go.
    bool typing_leaves_block = false;
    // The first half of `[[`, `]]`, `[f`, `]f`, `gg`, `z.` or `yc`.
    char chord = 0;
    // Where jumps left from, by stable row at the view's top, oldest first, and which of them
    // Ctrl-O went back to: the list's end while it has not.
    ds::Vec<std::uint64_t, Memory> jumps;
    std::size_t jump = 0;
  };

  // The commands the suggestions and Up read, newest first and each once: a view of the state's,
  // valid until a use case changes them.
  class Recalled {
  public:
    [[tbc::hot_path]] inline explicit Recalled(tbc::ref_a<Recall> recall) noexcept
        : recall_(&recall) {}

    [[nodiscard]] [[tbc::hot_path]] inline std::size_t size() const noexcept {
      return recall_->size();
    }

    [[nodiscard]] [[tbc::hot_path]] inline bool empty() const noexcept {
      return recall_->empty();
    }

    [[nodiscard]] [[tbc::hot_path]] inline tbc::val_a<std::string_view> operator[](std::size_t index) const noexcept {
      return recall_->command(index);
    }

    [[nodiscard]] [[tbc::hot_path]] inline tbc::val_a<std::string_view> front() const noexcept {
      return recall_->command(0);
    }

    [[nodiscard]] [[tbc::hot_path]] inline tbc::val_a<std::string_view> back() const noexcept {
      return recall_->command(recall_->size() - 1);
    }

  private:
    tbc::val_a<const Recall*> recall_;
  };

  // What ui reads of a pane's line: a view of it and of the commands its suggestions read for
  // where the line is, valid until a use case changes them. Inline, as a line's view reads it
  // whenever it draws.
  class LineView {
  public:
    [[tbc::hot_path]] inline LineView(tbc::ref_a<Line> line, tbc::ref_a<Recall> recall, tbc::val_a<Place> place) noexcept
        : line_(&line),
          recall_(&recall),
          place_(place) {}

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

    // The rest of a command this one starts: the newest whose last run did not fail, from the
    // line's directory first, then its workspace, then anywhere (Recall::suggest). Only while
    // typing at the end of a line of two characters or more.
    [[nodiscard]] [[tbc::hot_path]] inline tbc::val_a<std::string_view> suggestion() const noexcept {
      return line_->suggestion(*recall_, place_);
    }

    // The same for every view of one line, for a view to tell when the line it shows changed: an
    // address compared, never followed, as Rust's `*const ()`.
    [[nodiscard]] [[tbc::hot_path]] [[tbc::raw]] inline const void* identity() const noexcept {
      return line_;
    }

  private:
    tbc::val_a<const Line*> line_;
    tbc::val_a<const Recall*> recall_;
    tbc::val_a<Place> place_;
  };

  // The questions Tab asks the runtime, and the choices known at once. Opaque: application asks
  // each question under an id of its own (request, sent), then offers the plan to the line.
  struct CompletionPlan {
    // Files or directories under the directory typed, each provider the spec names, then the
    // pane's own shell.
    static constexpr std::size_t maximum_questions = 12;

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
    // The most commands the history query asks for, which the recall holds.
    static constexpr std::uint16_t history_limit = Recall::capacity;

    // Every line and what it asks for live in `allocator`.
    explicit State(tbc::mut_a<Memory> allocator);

    // Everything below lives in memory's region.
    tbc::mut_a<Memory> memory;
    tbc::val_a<Specs> specs;
    // Apart from the specs, so a spec read from them is matched with it.
    tbc::val_a<MatchScratch> scratch;
    tbc::val_a<Recall> recall;
    std::uint64_t history_request = 0;
    // An answer to the history query arrived: until one does, it is asked again.
    bool history_loaded = false;
    // The history changed while a query was on its way, which may have read it before: one more
    // query follows its answer, however many changes come meanwhile.
    bool history_again = false;
    tbc::val_a<ds::Map<std::uint64_t, PathCompletion, Memory>> completions;
    tbc::val_a<ds::Map<std::uint64_t, CommandRequest, Memory>> command_requests;
    tbc::val_a<ds::Map<std::uint64_t, CommandChecks, Memory>> command_checks;
    tbc::val_a<ds::Map<std::uint64_t, CommandRequest, Memory>> spec_requests;
    // Tab pressed while a pane waited for a spec: the line it completes, by pane.
    tbc::val_a<ds::Map<std::uint64_t, Name, Memory>> spec_completions;
    // The directory a question about a command named by its path reads, while it is sent.
    tbc::val_a<Name> command_root;
    // The commands sent that wait for the runtime's answer, by request.
    tbc::val_a<ds::Map<std::uint64_t, SentCommand, Memory>> sent_commands;
    // The commands the shell did not find whose closest command the runtime is asked for.
    tbc::val_a<ds::Map<std::uint64_t, Correction, Memory>> corrections;
    // The questions for ranked suggestions in flight, by request: the pane that asked.
    tbc::val_a<ds::Map<std::uint64_t, std::uint64_t, Memory>> suggestions;
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

  // Pane `pane_id`'s line as it reads at `place`, its own pane alone where none is given.
  [[nodiscard]] [[tbc::hot_path]] inline tbc::val_a<ds::Option<LineView>> line(tbc::ref_a<State> state, tbc::ref_a<Lines> lines, std::uint64_t pane_id, tbc::val_a<Place> place = {}) noexcept;

  [[nodiscard]] [[tbc::hot_path]] inline tbc::val_a<LineView> view(tbc::ref_a<State> state, tbc::ref_a<PaneLine> line, tbc::val_a<Place> place = {}) noexcept;

  // The commands people typed, most recent first and each once, which the suggestions read.
  [[nodiscard]] [[tbc::hot_path]] inline tbc::val_a<Recalled> history(tbc::ref_a<State> state) noexcept;

  // Pane `pane_id` printed now, as `now` reads the clock, only for a pane with a line: a program
  // quiet since may be asking a question.
  template <typename Now>
  [[tbc::generic]] void output(Lines& lines, std::uint64_t pane_id, Now&& now) noexcept;

  // Pane `pane_id` is gone: its line and what it asked for go with it.
  void forget(State& state, Lines& lines, std::uint64_t pane_id) noexcept;

  // ---- keys and text ----------------------------------------------------------------------------

  // Whether a key typed while a program runs reaches the program instead of the queue: the signal
  // and end-of-file keys of `shell`'s line discipline, and any key while the program seems to ask
  // a question, `asked` before its cursor (PendingPrompt::question) and quiet since its last
  // output. Once a key reached
  // it, the rest of the answer follows it until Enter: the echo of each key is output too, and
  // would send the next one to the queue. `now` reads the clock, only when the line is empty and
  // no answer is under way.
  template <typename Now>
  [[nodiscard]] [[tbc::generic]] bool toProgram(PaneLine& line, const KeyPress& key, const PaneShell& shell, std::string_view asked, Now&& now);

  // Whether text an input method committed or a paste reaches the program instead of the queue,
  // as a key would: during an answer, or as its start. Only one line does (oneLine), and a line
  // end after it ends the answer.
  template <typename Now>
  [[nodiscard]] [[tbc::generic]] bool toProgram(PaneLine& line, std::string_view text, std::string_view asked, Now&& now);

  // How the line reads a key: the bindings and Up's scope of `configuration`, the `dialect` of the
  // shell that runs the command, and the `place` the suggestions and Up rank commands for.
  struct KeyReading {
    const PromptConfiguration& configuration;
    shell::Dialect dialect = shell::Dialect::posix;
    Place place;
  };

  // A key in the line: the action the configuration binds to it in the editor's mode, or the
  // editor's own. Enter continues a command the dialect's shell would read more of.
  [[nodiscard]] [[tbc::hot_path]] inline Outcome press(const State& state, PaneLine& line, Surface surface, const KeyPress& key, KeyReading reading);

  // What the line hands its owner with `run`, `answer` or `bytes`: the command, the answer or the
  // keys. Valid until the line's next key.
  [[nodiscard]] [[tbc::hot_path]] inline std::string_view delivery(const PaneLine& line) noexcept;

  // `command` ran from a line at `place`: every pane's suggestions know it at once, without asking
  // the history again.
  void remember(State& state, std::string_view command, const Place& place = {});

  // A command ended in the line's pane with `status`: when it is the one the line ran, a failure
  // keeps it out of the suggestions until it runs again. An interrupt is not a failure: Ctrl-C
  // ends `tail -f` as it should.
  void ended(State& state, PaneLine& line, std::int32_t status) noexcept;

  // What the line handed over with `run` or `answer` reached its pane: the line clears and
  // remembers `command`, empty for an answer. A delivery that fails leaves the text in the line.
  void committed(PaneLine& line, std::string_view command);

  // The most commands that wait for the runtime's answer at once; one sent past it is taken as
  // typed, as a runtime that does not answer.
  inline constexpr std::size_t sent_commands_limit = 64;

  // The line's `command` went out under `request_id`, for a runtime that answers it: the line
  // clears at once, as the shell's would, but remembers nothing until the runtime typed it.
  // `kept` when the history filters keep it. False when too many wait: the caller commits it.
  [[nodiscard]] bool sent(State& state, PaneLine& line, std::uint64_t request_id, std::string_view command, bool kept);

  // The pane that sent the command waiting under `request_id`; none when no command waits there.
  [[nodiscard]] ds::Option<std::uint64_t> sentFrom(const State& state, std::uint64_t request_id) noexcept;

  // The runtime typed the command sent under `request_id`, from `place`: the line remembers it,
  // and every line's suggestions and Up do when it was kept. False when none waited there.
  bool accepted(State& state, Lines& lines, std::uint64_t request_id, const Place& place);

  // The runtime refused the command sent under `request_id`: it comes back into its line, when
  // nothing was typed there since, and nothing remembers it. The command, none when none waited
  // there; it lives until the state's next use case.
  [[nodiscard]] tbc::val_a<ds::Option<SentCommand>> refused(tbc::mut_a<State> state, Lines& lines, std::uint64_t request_id);

  // Text an input method committed or a paste, into the line. Controls other than newline and tab
  // are dropped: they would act on the shell instead of being written. False when the line
  // cannot hold it all, past Text's capacity: it is refused whole, as a command cut short could
  // run something else, and the line stays as it was.
  [[nodiscard]] bool insert(State& state, PaneLine& line, std::string_view text);

  // The most bytes a line holds, which a paste past it is refused for.
  inline constexpr std::size_t line_capacity = Text::capacity;

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
    // The runtime asks the pane's own shell for a command no spec describes.
    bool reads_shell = false;
    // The pane's shell is on a host `ssh` reached, which the runtime asks only for its files and
    // its shell's words.
    bool remote = false;
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

  // ---- what the shell's own line held ----------------------------------------------------------

  // The runtime reports `typed`, what the shell's line editor held when a command cleared it:
  // the line takes it at the shell's next prompt (takeTypeahead). At most the wire's bound.
  void typeahead(PaneLine& line, std::string_view typed);

  // At the shell's prompt, the text the shell's line held goes into the line, before what was
  // typed there since; true when there was any.
  bool takeTypeahead(State& state, PaneLine& line);

  // ---- the runtime's ranked suggestion ---------------------------------------------------------

  // The question for the runtime's best command that starts with what the line holds, its index
  // ranking it with its priors for the line's pane and directory at `place`, under `request_id`:
  // only while typing at the end of a line of two characters or more. None when it has nothing
  // to ask, or a question is in flight, which asks again once answered. It views the line and
  // `place`.
  [[nodiscard]] tbc::val_a<ds::Option<QueryHistory>> suggestionQuery(tbc::ref_a<PaneLine> line, tbc::val_a<Place> place, std::uint64_t request_id);

  // The question went out under `request_id`, `sent`, or not.
  void askedSuggestion(State& state, PaneLine& line, std::uint64_t request_id, bool sent);

  // An answer to a suggestion's question: the pane whose line suggests it now, 0 when it
  // suggests what it did; none when the answer is not one.
  [[nodiscard]] ds::Option<std::uint64_t> ranked(State& state, Lines& lines, const HistoryResults& message);

  // The history entry whose command the line's last key took whole as the runtime suggested
  // it, for the runtime to learn the choice; none, once taken.
  [[nodiscard]] ds::Option<std::uint64_t> takeChosen(PaneLine& line) noexcept;

  // ---- options a command does not accept ------------------------------------------------------

  // The bytes [first, second) of the first option the line's command does not accept, as the
  // spec held for it reads the words, the `dialect`'s shell splitting them: only for a spec
  // marked complete (Specs::complete_marker), and a line of one plain command, without `$`,
  // quotes, escapes, pipes, lists, redirections, groups or substitutions, which only the shell
  // can resolve. Never the word at the line's end, which is still being typed. Kept until the
  // line or the specs change, as each redraw asks.
  [[nodiscard]] ds::Option<std::pair<std::size_t, std::size_t>> rejectedOption(State& state, PaneLine& line, shell::Dialect dialect);

  // ---- did you mean ----------------------------------------------------------------------------

  // The shell said it did not find the command `line` ran, with status 127: its empty line
  // suggests the closest command known, from the history, the pane's aliases and the commands it
  // saw run, as the `dialect`'s shell reads the command. With an `asking` request id, the
  // question under it for the commands the shell runs that start as the word does, whose answer
  // may hold a closer one; none when there is nothing to ask. It views the state.
  [[nodiscard]] tbc::val_a<ds::Option<CompleteWords>> mistyped(tbc::mut_a<State> state, PaneLine& line, std::int32_t status, shell::Dialect dialect, ds::Option<std::uint64_t> asking);

  // The question `request_id` for a correction went out, `sent`, or not.
  void askedCorrection(State& state, std::uint64_t request_id, bool sent);

  // The commands the runtime found for a correction: the pane whose line suggests another, 0 when
  // it suggests the same; none when the answer is not a correction's.
  [[nodiscard]] ds::Option<std::uint64_t> correct(State& state, Lines& lines, const CompletionWords& message);

  // ---- the history the suggestions read --------------------------------------------------------

  // Whether the history is on its way.
  [[nodiscard]] bool historyAsked(const State& state) noexcept;

  // Whether the history is to be asked for: no answer arrived and none is on its way, as after
  // a query that failed or a connection lost.
  [[nodiscard]] bool historyWanted(const State& state) noexcept;

  // The history the state holds is older than the runtime's: it is to be asked for again. A
  // query already on its way is not asked again: its answer is kept, and the history is wanted
  // once more after it, for every change that came meanwhile.
  void historyStale(State& state) noexcept;

  // The question for the commands people typed, most recent first and each once.
  [[nodiscard]] QueryHistory historyQuery(std::uint64_t request_id) noexcept;

  void askedHistory(State& state, std::uint64_t request_id) noexcept;

  // Whether `message` answers the question for the history; the history is replaced when it does.
  bool receive(State& state, const HistoryResults& message);

  // ---- the command block selected from the line -------------------------------------------------

  [[nodiscard]] ds::Option<std::size_t> selectedBlock(const Lines& lines, std::uint64_t pane_id) noexcept;

  [[nodiscard]] ds::Option<std::size_t> selectedBlock(const PaneLine& line) noexcept;

  // Block `index` is selected, or none: the line is back at the live end.
  void selectBlock(PaneLine& line, ds::Option<std::size_t> index, bool typing_leaves = false) noexcept;

  // The selected block is now at `index` among the pane's blocks, or gone: blocks before it were
  // dropped, or came again.
  void moveBlock(PaneLine& line, ds::Option<std::size_t> index) noexcept;

  // Whether the keys that type let the selected block go, as after a click on it.
  [[nodiscard]] bool typingLeavesBlock(const PaneLine& line) noexcept;

  [[nodiscard]] bool typingLeavesBlock(const Lines& lines, std::uint64_t pane_id) noexcept;

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

  inline tbc::val_a<LineView> view(tbc::ref_a<State> state, tbc::ref_a<PaneLine> line, tbc::val_a<Place> place) noexcept {
    if (place.pane_id == 0) {
      place.pane_id = line.pane_id;
    }

    return LineView{line.line, state.recall, place};
  }

  inline tbc::val_a<ds::Option<LineView>> line(tbc::ref_a<State> state, tbc::ref_a<Lines> lines, std::uint64_t pane_id, tbc::val_a<Place> place) noexcept {
    const auto* found = lines.find(pane_id);
    if (found == nullptr) {
      return ds::none;
    }

    return view(state, **found, place);
  }

  inline tbc::val_a<Recalled> history(tbc::ref_a<State> state) noexcept {
    return Recalled{state.recall};
  }

  template <typename Now>
  void output(Lines& lines, std::uint64_t pane_id, Now&& now) noexcept {
    if (auto* line = find(lines, pane_id)) {
      line->output = std::forward<Now>(now)();
    }
  }

  [[nodiscard]] [[tbc::hot_path]] inline UpScope upScope(PromptUpScope scope) noexcept {
    switch (scope) {
    case PromptUpScope::pane:
      return UpScope::pane;
    case PromptUpScope::workspace:
      return UpScope::workspace;
    case PromptUpScope::global:
      break;
    }

    return UpScope::global;
  }

  // Space after a command word that names one of the pane's aliases, as the shell reported it:
  // the word becomes what it stands for and a space, as fish's abbreviations do. False, the line
  // as it was, anywhere else. Defined with the use cases that are not on a key's path.
  [[nodiscard]] bool expand(const State& state, Line& line, std::uint64_t pane_id, shell::Dialect dialect);

  // The action bound to `key` in the editor's mode; defined with the use cases that are not on a
  // key's path.
  [[nodiscard]] ds::Option<Action> bound(const KeyPress& key, const Editor& editor, const PromptConfiguration& configuration);

  inline Outcome press(const State& state, PaneLine& line, Surface surface, const KeyPress& key, KeyReading reading) {
    auto& edited = line.line;
    const auto syntax = shell::Syntax{.dialect = reading.dialect};

    edited.useDialect(reading.dialect);
    const auto incomplete = [&memory = state.memory, syntax](std::string_view text) {
      return prompt::incomplete(memory, text, syntax);
    };

    auto place = reading.place;

    if (place.pane_id == 0) {
      place.pane_id = line.pane_id;
    }

    // With aliases expanded, Space writes what an alias stands for and Alt-Space a space alone,
    // where Space types: not in vim's normal mode, nor in a menu, which takes its keys.
    const bool types = edited.editor().keymap() == Keymap::emacs || edited.editor().mode() == Mode::insert;

    if (reading.configuration.expand_aliases && types && key.key == Key::character && key.character == U' ' && !key.modifiers.control && !edited.menu()) {
      if (key.modifiers.alt) {
        edited.insertText(" ");
        return Outcome::edited;
      }

      if (expand(state, edited, line.pane_id, reading.dialect)) {
        return Outcome::edited;
      }
    }

    const Recalling recalling{.recall = state.recall, .place = place, .scope = upScope(reading.configuration.up_scope)};
    // The menu that shows and the suggestion keep their keys from the bindings.
    const auto action = edited.claims(key, recalling) ? ds::none : bound(key, edited.editor(), reading.configuration);

    const auto outcome = action ? edited.perform(surface, *action, incomplete, recalling) : edited.press(surface, key, incomplete, recalling);

    edited.settleCorrection();
    return outcome;
  }

  // An answer under way, or a program that seems to ask a question. The echo of each key it
  // takes is output too, so its quiet is only read before the first one.
  template <typename Now>
  [[tbc::generic]] bool answers(const PaneLine& line, std::string_view asked, Now&& now) {
    if (line.forwarding) {
      return true;
    }

    return line.line.editor().text().empty() && PendingPrompt::likely(asked, std::chrono::nanoseconds{std::forward<Now>(now)() - line.output});
  }

  template <typename Now>
  bool toProgram(PaneLine& line, const KeyPress& key, const PaneShell& shell, std::string_view asked, Now&& now) {
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

        line.line.disarm();
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

    if (!answers(line, asked, std::forward<Now>(now))) {
      return false;
    }

    line.line.disarm();
    line.forwarding = !enter;
    return true;
  }

  template <typename Now>
  bool toProgram(PaneLine& line, std::string_view text, std::string_view asked, Now&& now) {
    if (line.line.answering() || !oneLine(text) || !answers(line, asked, std::forward<Now>(now))) {
      return false;
    }

    line.line.disarm();
    line.forwarding = !text.ends_with('\n') && !text.ends_with('\r');
    return true;
  }

  inline std::string_view delivery(const PaneLine& line) noexcept {
    return line.line.delivery();
  }

  inline void typeSecret(PaneLine& line, char byte) noexcept {
    // DEL and Backspace erase the last key typed, as the line discipline does; Ctrl-U erases them
    // all, and Ctrl-W too, as the dots cannot tell where a word began. Any other control types
    // nothing.
    constexpr unsigned char delete_control = 0x7f;
    constexpr unsigned char backspace = 0x08;
    constexpr unsigned char kill_line = 0x15;
    constexpr unsigned char kill_word = 0x17;
    constexpr unsigned char first_printable = 0x20;
    // A character is a dot, whatever its length: its continuation bytes add none.
    constexpr unsigned char continuation_mask = 0xc0;
    constexpr unsigned char continuation = 0x80;

    const auto value = static_cast<unsigned char>(byte);
    auto& typed = line.line;

    if (value == delete_control || value == backspace) {
      typed.eraseSecretKey();
    } else if (value == kill_line || value == kill_word) {
      typed.clearSecret();
    } else if (value >= first_printable && (value & continuation_mask) != continuation) {
      typed.countSecretKey();
    }
  }

}
