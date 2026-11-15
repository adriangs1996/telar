module;
#include "tbc/annotations.hpp"

export module telar.gui.prompt.line;

import std;

import telar.gui.prompt.editor;
import telar.gui.prompt.routing;
import telar.gui.prompt.completion;
import telar.shell.syntax;

// One pane's command editor: the line being written or queued, the commands sent from it, and
// what the owner must do next. It knows nothing of Qt or the transport, so tests drive it as the
// session does.
export namespace telar::gui::prompt {

  // What the owner does after a key.
  enum class Outcome : std::uint8_t {
    // The line used the key; repaint it.
    edited,
    // Send `delivery` to the shell as a command and run it.
    run,
    // Send `delivery` to the running program as typed input followed by Enter.
    answer,
    // Send `delivery` to the shell as raw bytes (end of file, clear screen).
    bytes,
    // The key belongs to the terminal: encode and send it as usual.
    terminal,
    // Neither the line nor the terminal: telar's own binding may take it.
    ignored,
    // Tab: the owner works out the choices and offers them.
    complete,
    // Ctrl-R at the shell's prompt: the owner searches the history from the line.
    search_history,
  };

  // The choices Tab offered, over the word they would replace.
  struct Menu {
    static constexpr std::size_t capacity = 256;

    std::vector<Choice> choices;
    std::size_t selected = 0;
    std::size_t begin = 0;
    std::size_t end = 0;
    // Requests to the runtime whose answers join the choices.
    std::vector<std::uint64_t> requests;
    shell::Dialect dialect = shell::Dialect::posix;
    // What the choices are, for the menu's heading: "commands", "branches · git".
    std::string label;
    // Every choice offered for the word, and the cursor it was offered at: typing narrows them
    // down; erasing past that cursor asks for them again.
    std::vector<Choice> all;
    std::size_t floor = 0;
    // Every choice for the word arrived: a cut list asks again as typing narrows it.
    bool whole = true;
    // Refined by typing: a single choice left is not written for the user.
    bool refined = false;
  };

  // Whether the shell would read more of a command before running it, as Enter asks.
  class Continuation {
  public:
    Continuation(const Continuation&) = delete;
    Continuation& operator=(const Continuation&) = delete;

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

  class Line {
  public:
    static constexpr std::size_t recent_capacity = 512;

    explicit Line(Keymap keymap = Keymap::emacs);

    Editor& editor() noexcept;

    [[nodiscard]] const Editor& editor() const noexcept;

    [[nodiscard]] std::string_view delivery() const noexcept;

    [[nodiscard]] std::uint64_t revision() const noexcept;

    // The command typed while another runs waits for it; Enter arms it to run when that one
    // succeeds.
    [[nodiscard]] bool queued() const noexcept;

    // While a program runs, typed lines go to it instead of the queue.
    [[nodiscard]] bool answering() const noexcept;

    [[nodiscard]] std::uint32_t secretKeys() const noexcept;

    [[nodiscard]] const std::vector<std::string>& recent() const noexcept;

    void setKeymap(Keymap keymap);

    // The rest of a command this one starts, from what this line sent (newest first) and then
    // `history`, newest first. Only while typing at the end of a non-empty line.
    [[nodiscard]] std::string_view suggestion(std::span<const std::string> history) const noexcept;

    // A key in the editor or the queue. `incomplete` tells whether the shell would wait for more
    // of the command, so Enter continues it on a new line.
    template <typename Incomplete>
    TBC_GENERIC Outcome press(Surface surface, const KeyPress& key, Incomplete&& incomplete, std::span<const std::string> history = {}) {
      const ContinuationOf<std::remove_reference_t<Incomplete>> continuation{incomplete};

      return pressKey(surface, key, continuation, history);
    }

    // A key the user bound to an action; the rest of the line answers it as for any key.
    template <typename Incomplete>
    TBC_GENERIC Outcome perform(Surface surface, Action action, Incomplete&& incomplete, std::span<const std::string> history = {}) {
      const ContinuationOf<std::remove_reference_t<Incomplete>> continuation{incomplete};

      return performAction(surface, action, continuation, history);
    }

    // press and perform, with the caller's callable behind Continuation.
    Outcome pressKey(Surface surface, const KeyPress& key, const Continuation& incomplete, std::span<const std::string> history = {});

    Outcome performAction(Surface surface, Action action, const Continuation& incomplete, std::span<const std::string> history = {});

    void insertText(std::string_view text);

    // Writes `text` over [begin, end) of the line, as a path chosen for the word there does.
    void replaceText(std::size_t begin, std::size_t end, std::string_view text);

    const std::optional<Menu>& menu() const noexcept;

    // Offers `choices` for the word in [begin, end): one is written at once, more open the
    // menu. While `requests` are still looking for more, even one choice waits for them.
    void offer(std::vector<Choice> choices, std::size_t begin, std::size_t end, std::vector<std::uint64_t> requests, shell::Dialect dialect, std::string label = {});

    // What a pending request found, added to the menu it was asked for.
    bool receive(std::uint64_t request, std::span<const Choice> paths, bool truncated = false);

    bool pending(std::uint64_t request) const noexcept;

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
    std::optional<Outcome> menuKey(const KeyPress& key, bool& refining);

    // The word the menu completes, as typed so far.
    std::string_view typedWord() const noexcept;

    // After a key typed or erased in the word: the choices that still start with it. Erasing
    // past where they were offered asks for them again; leaving the word closes the menu.
    Outcome refine(Outcome outcome);

    Outcome submit(Surface surface, bool incomplete);

    // Up and Down past the editor's first and last line walk the commands sent from it, keeping
    // what was being written to come back to.
    Outcome travel(int direction);

    Editor editor_;
    std::vector<std::string> recent_;
    std::string draft_;
    std::string delivery_;
    std::optional<std::size_t> history_index_;
    std::optional<Menu> menu_;
    std::uint64_t revision_ = 0;
    // The next offer refines the menu typing reopened: one choice left is not written.
    bool refining_ = false;
    std::uint32_t secret_keys_ = 0;
    bool armed_ = false;
    bool answering_ = false;
  };

}
