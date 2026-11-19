module;
#include "tbc/annotations.hpp"

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
  class TBC_GENERIC ContinuationOf final : public Continuation {
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
    explicit Line(tbc::view<Memory&, tbc::lt::a> memory, Keymap keymap = Keymap::emacs);

    Editor& editorMut() noexcept;

    [[nodiscard]] const Editor& editor() const noexcept;

    [[nodiscard]] std::string_view delivery() const noexcept;

    [[nodiscard]] std::uint64_t revision() const noexcept;

    // The command typed while another runs waits for it; Enter arms it to run when that one
    // succeeds.
    [[nodiscard]] bool queued() const noexcept;

    // While a program runs, typed lines go to it instead of the queue.
    [[nodiscard]] bool answering() const noexcept;

    [[nodiscard]] std::uint32_t secretKeys() const noexcept;

    [[nodiscard]] History recent() const noexcept;

    void setKeymap(Keymap keymap);

    // The rest of a command this one starts, from what this line sent (newest first) and then
    // `history`, newest first. Only while typing at the end of a non-empty line.
    // From the commands sent from this line or from the history, both in region `a`.
    [[nodiscard]] tbc::view<std::string_view, tbc::lt::a> suggestion(tbc::view<History, tbc::lt::a> history) const noexcept;

    // A key in the editor or the queue. `incomplete` tells whether the shell would wait for more
    // of the command, so Enter continues it on a new line.
    template <typename Incomplete>
    TBC_GENERIC Outcome press(Surface surface, const KeyPress& key, const Incomplete& incomplete, History history = {}) {
      const ContinuationOf<const Incomplete> continuation{incomplete};

      return pressKey(surface, key, continuation, history);
    }

    // A key the user bound to an action; the rest of the line answers it as for any key.
    template <typename Incomplete>
    TBC_GENERIC Outcome perform(Surface surface, Action action, const Incomplete& incomplete, History history = {}) {
      const ContinuationOf<const Incomplete> continuation{incomplete};

      return performAction(surface, action, continuation, history);
    }

    // press and perform, with the caller's callable behind Continuation.
    Outcome pressKey(Surface surface, const KeyPress& key, const Continuation& incomplete, History history = {});

    Outcome performAction(Surface surface, Action action, const Continuation& incomplete, History history = {});

    void insertText(std::string_view text);

    // Writes `text` over [begin, end) of the line, as a path chosen for the word there does.
    void replaceText(std::size_t begin, std::size_t end, std::string_view text);

    [[nodiscard]] const ds::Option<Menu>& menu() const noexcept;

    // Offers `choices` for the `word`: one is written at once, more open the menu. While
    // `requests` are still looking for more, even one choice waits for them.
    void offer(tbc::view<Choices, tbc::lt::a> choices, WordRange word, tbc::view<ds::Vec<std::uint64_t, Memory>, tbc::lt::a> requests, shell::Dialect dialect, std::string_view label = {});

    // What a pending request found, added to the menu it was asked for.
    bool receive(std::uint64_t request, tbc::view<Choices, tbc::lt::a> paths, bool truncated = false);

    [[nodiscard]] bool pending(std::uint64_t request) const noexcept;

    // The shell is back at its prompt after `succeeded` (or not): a queued command runs only
    // after a success, and otherwise stays as a draft.
    Outcome promptReturned(bool succeeded);

    void countSecretKey() noexcept;

    void clearSecret() noexcept;

    void remember(std::string_view command);

  private:
    [[nodiscard]] bool textIsSmallAndInVimMode(const Text& text) const;

    [[nodiscard]] static bool isCommandExtendedBy(std::string_view command, std::string_view text);

    Outcome handle(Request request, Surface surface, const Continuation& incomplete);

    void closeMenu() noexcept;

    // A menu with nothing left to wait for and one choice writes it; with none it closes.
    void settle();

    void accept();

    // While the menu is open, Tab and the arrows move through it, Enter takes the choice and
    // Escape closes it; any other key closes it and edits as usual.
    ds::Option<Outcome> menuKey(const KeyPress& key, bool& refining);

    // The word the menu completes, as typed so far.
    [[nodiscard]] std::string_view typedWord() const noexcept;

    // After a key typed or erased in the word: the choices that still start with it. Erasing
    // past where they were offered asks for them again; leaving the word closes the menu.
    Outcome refine(Outcome outcome);

    Outcome submit(Surface surface, bool incomplete);

    // Up and Down past the editor's first and last line walk the commands sent from it, keeping
    // what was being written to come back to.
    Outcome travel(int direction);

    tbc::view<Editor, tbc::lt::a> editor_;
    tbc::view<ds::Vec<ds::String<Memory>, Memory>, tbc::lt::a> recent_;
    tbc::view<ds::String<Memory>, tbc::lt::a> draft_;
    tbc::view<ds::String<Memory>, tbc::lt::a> delivery_;
    ds::Option<std::size_t> history_index_;
    tbc::view<ds::Option<Menu>, tbc::lt::a> menu_;
    std::uint64_t revision_ = 0;
    // The next offer refines the menu typing reopened: one choice left is not written.
    bool refining_ = false;
    std::uint32_t secret_keys_ = 0;
    bool armed_ = false;
    bool answering_ = false;
  };

}
