module;

// One pane's command editor: the line being written or queued, the commands sent from it, and
// what the owner must do next. It knows nothing of Qt or the transport. Nothing here is exported:
// only the feature's own units name it, through a pane's line.
export module telar.gui.features.prompt:line;

import std;

import :keys;
import :text;
import :editor;
import :routing;
import :completion;
import :menu;
import :recall;
import telar.shell.syntax;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.tbc;

namespace telar::gui::features::prompt {

  // Whether the shell would read more of a command before running it, as Enter asks.
  class Continuation {
  public:
    Continuation(const Continuation&) = delete;
    Continuation(Continuation&&) = delete;
    Continuation& operator=(const Continuation&) = delete;
    Continuation& operator=(Continuation&&) = delete;

    [[nodiscard]] virtual bool incomplete(std::string_view text) const = 0;

  protected:
    Continuation() noexcept = default;
    ~Continuation() = default;
  };

  // A caller's callable behind Continuation, for the time of one key.
  template <typename Incomplete>
  class [[tbc::generic]] ContinuationOf final : public Continuation {
  public:
    explicit ContinuationOf(Incomplete& incomplete) noexcept
        : incomplete_(incomplete) {}

    [[nodiscard]] bool incomplete(std::string_view text) const override {
      return incomplete_(text);
    }

  private:
    Incomplete& incomplete_;
  };

  // The bytes [begin, end) of the line that a word takes.
  struct WordRange {
    std::size_t begin = 0;
    std::size_t end = 0;
  };

  class Line {
  public:
    static constexpr std::size_t recent_capacity = 512;

    // The line, its menu and the commands it sent live in `memory`.
    explicit Line(tbc::mut_a<Memory> memory, Keymap keymap = Keymap::emacs);

    Editor& editorMut() noexcept;

    [[nodiscard]] const Editor& editor() const noexcept;

    [[nodiscard]] std::string_view delivery() const noexcept;

    [[nodiscard]] std::uint64_t revision() const noexcept;

    // The command typed while another runs waits for it; Enter arms it to run when that one
    // succeeds.
    // Keys reached the running program: what the queue holds may have been meant for it, so it
    // waits in the line instead of running when the shell is back.
    void disarm() noexcept;
    [[nodiscard]] bool queued() const noexcept;

    // While a program runs, typed lines go to it instead of the queue.
    [[nodiscard]] bool answering() const noexcept;

    [[nodiscard]] std::uint32_t secretKeys() const noexcept;

    [[nodiscard]] History recent() const noexcept;

    void setKeymap(Keymap keymap);

    // The shell that reads the commands the line writes and recalls, for the words of Alt-.
    void useDialect(shell::Dialect dialect) noexcept;

    // The rest of a command this one starts, as the recall ranks them for where the line is
    // (Recall::suggest). Only while typing at the end of a line of two characters or more. Kept
    // until the line or the recall changes, as a key asks for it more than once.
    // From the commands sent from this line or from the recall, both in region `a`.
    [[nodiscard]] tbc::val_a<std::string_view> suggestion(tbc::ref_a<Recall> recall, const Place& place) const noexcept;

    // Whether the line has a use for `key` ahead of any binding: the menu of choices that shows
    // takes every key, and the suggestion the keys that take it.
    [[nodiscard]] bool claims(const KeyPress& key, const Recalling& recalling) const noexcept;

    // A key in the editor or the queue. `incomplete` tells whether the shell would wait for more
    // of the command, so Enter continues it on a new line.
    template <typename Incomplete>
    [[tbc::generic]] Outcome press(Surface surface, const KeyPress& key, const Incomplete& incomplete, const Recalling& recalling) {
      const ContinuationOf<const Incomplete> continuation{incomplete};

      return pressKey(surface, key, continuation, recalling);
    }

    // A key the user bound to an action; the rest of the line answers it as for any key.
    template <typename Incomplete>
    [[tbc::generic]] Outcome perform(Surface surface, Action action, const Incomplete& incomplete, const Recalling& recalling) {
      const ContinuationOf<const Incomplete> continuation{incomplete};

      return performAction(surface, action, continuation, recalling);
    }

    // press and perform, with the caller's callable behind Continuation.
    Outcome pressKey(Surface surface, const KeyPress& key, const Continuation& incomplete, const Recalling& recalling);

    Outcome performAction(Surface surface, Action action, const Continuation& incomplete, const Recalling& recalling);

    // False when the line cannot hold `text`, which leaves it as it was.
    bool insertText(std::string_view text);

    // Writes `text` over [begin, end) of the line, as a path chosen for the word there does.
    void replaceText(std::size_t begin, std::size_t end, std::string_view text);

    // `command` replaces the line, the caret at its end, as a history entry pasted does: Up and
    // Down start over from it, and the menu closes.
    void write(std::string_view command);

    [[nodiscard]] const ds::Option<Menu>& menu() const noexcept;

    // Offers `choices` for the `word`: one is written at once, more open the menu. While
    // `requests` are still looking for more, even one choice waits for them.
    void offer(tbc::val_a<Choices> choices, WordRange word, tbc::val_a<ds::Vec<std::uint64_t, Memory>> requests, shell::Dialect dialect, std::string_view label = {});

    // What a pending request found, added to the menu it was asked for.
    bool receive(std::uint64_t request, tbc::val_a<Choices> paths, bool truncated = false);

    [[nodiscard]] bool pending(std::uint64_t request) const noexcept;

    // Whether an answer that receive took closed the menu to ask for the word again, as Tab
    // does; once.
    [[nodiscard]] bool takeAskAgain() noexcept;

    // The shell is back at its prompt after `succeeded` (or not): a queued command runs only
    // after a success, and otherwise stays as a draft.
    Outcome promptReturned(bool succeeded);

    // What `run` or `answer` handed over reached the pane: the line clears, and remembers
    // `command` unless it is empty. Until then the text stays, for a delivery that fails.
    void committed(std::string_view command);

    void countSecretKey() noexcept;

    void clearSecret() noexcept;

    // The last key of the secret erased, as the line discipline's erase character erases it.
    void eraseSecretKey() noexcept;

    void remember(std::string_view command);

    // The shell did not find the command the line ran: `command` is the one it likely meant,
    // which the empty line suggests whole until something is typed there or another runs.
    void correct(std::string_view command);

    // What the empty line suggests; empty without one.
    [[nodiscard]] std::string_view correction() const noexcept;

    // The runtime's index ranked `command`, history entry `id`, first for what the line holds:
    // the suggestion while it goes on from the line's text. False when it was already the one.
    bool rank(std::string_view command, std::uint64_t id);

    // The entry of the runtime's suggestion the last key took whole; none, once taken.
    [[nodiscard]] ds::Option<std::uint64_t> takeChosen() noexcept;

    // After a key: once something is typed, the line suggests no correction any more.
    void settleCorrection() noexcept;

  private:
    [[nodiscard]] bool textIsSmallAndInVimMode(const Text& text) const;

    [[nodiscard]] static bool isCommandExtendedBy(std::string_view command, std::string_view text);

    // `rest` of a suggestion was written whole: when it is the runtime's, its entry is chosen.
    void noteTaken(std::string_view rest) noexcept;

    Outcome handle(Request request, Surface surface, const Continuation& incomplete, const Recalling& recalling);

    void closeMenu() noexcept;

    // A menu with nothing left to wait for and one choice writes it; with none it closes.
    void settle();

    void accept();
    // Writes `text` in place of the word the menu offers choices for, as it was typed so far;
    // `ends` closes a quote the word opened and adds the space after it.
    void writeChoice(std::string_view text, bool ends);
    // Writes what every choice starts with past what was typed, as zsh and fish do.
    void writeCommonStart();

    // While the menu is open, Tab and the arrows move through it, Enter takes the choice and
    // Escape closes it; any other key closes it and edits as usual.
    ds::Option<Outcome> menuKey(const KeyPress& key, bool& refining);

    // The word the menu completes, as typed so far.
    [[nodiscard]] std::string_view typedWord() const noexcept;

    // After a key typed or erased in the word: the choices that still match it, best first.
    // Erasing past where they were offered asks for them again; leaving the word closes the menu.
    Outcome refine(Outcome outcome);

    Outcome submit(Surface surface, bool incomplete);

    // Up and Down past the editor's first and last line walk the commands that start with what
    // was being written, as fish and zsh's history-beginning-search do, within the recalling's
    // scope (Recall::walk), keeping what was being written to come back to.
    Outcome travel(int direction, const Recalling& recalling);
    // Alt-.: the last argument of the command before, written at the cursor; again at once, the
    // last argument of the one before that in its place.
    Outcome lastArgument(const Recalling& recalling);

    tbc::val_a<Editor> editor_;
    tbc::val_a<ds::Vec<ds::String<Memory>, Memory>> recent_;
    tbc::val_a<ds::String<Memory>> draft_;
    tbc::val_a<ds::String<Memory>> delivery_;
    // The commands Up or Alt-. steps through, taken when the first of them came.
    tbc::val_a<Walk> walk_;
    // The command a mistyped one likely meant, while the line is empty.
    tbc::val_a<ds::String<Memory>> correction_;
    // The runtime's ranked suggestion and its history entry, and the entry a key took whole.
    tbc::val_a<ds::String<Memory>> ranked_;
    std::uint64_t ranked_id_ = 0;
    std::uint64_t chosen_ = 0;
    // How many commands back Up went; none at the line being written, or once what Up brought
    // back was edited: the text's revision then was `recalled_`.
    ds::Option<std::size_t> history_index_;
    std::uint64_t recalled_ = 0;
    // What the last Alt-. wrote: how many commands back it read, where it wrote, and the text's
    // revision after, which a repeat at once still shows.
    std::size_t argument_steps_ = 0;
    std::size_t argument_start_ = 0;
    std::size_t argument_end_ = 0;
    std::uint64_t argument_revision_ = 0;

    // The suggestion last found, and what it was found for: the line's revision, the recall's,
    // and the place, by its pane and a hash of its strings, which change under a view.
    struct SuggestionKey {
      std::uint64_t line = 0;
      std::uint64_t recall = 0;
      std::uint64_t pane = 0;
      std::uint64_t place = 0;
      bool found = false;

      [[nodiscard]] bool operator==(const SuggestionKey&) const = default;
    };

    ds::Cell<Suggested> suggested_{Suggested{}};
    ds::Cell<SuggestionKey> suggested_for_{SuggestionKey{}};
    tbc::val_a<ds::Option<Menu>> menu_;
    std::uint64_t revision_ = 0;
    // The next offer refines the menu typing reopened: one choice left is not written.
    bool refining_ = false;
    std::uint32_t secret_keys_ = 0;
    bool armed_ = false;
    bool answering_ = false;
    bool asks_again_ = false;
    shell::Dialect dialect_ = shell::Dialect::posix;
  };

}
