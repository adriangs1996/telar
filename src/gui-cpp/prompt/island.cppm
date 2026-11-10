module;
#include <cstddef>
#include <cstdint>

export module telar.gui.prompt.island;

import std;

export import telar.gui.prompt.editor;
export import telar.gui.prompt.routing;
export import telar.gui.prompt.completion;

// One pane's command editor: the line being written or queued, the commands sent from it, and
// what the owner must do next. It knows nothing of Qt or the transport, so tests drive it as the
// session does.
export namespace telar::gui::prompt {

// What the owner does after a key.
enum class Outcome : std::uint8_t {
  // The island used the key; repaint it.
  edited,
  // Send `delivery` to the shell as a command and run it.
  run,
  // Send `delivery` to the running program as typed input followed by Enter.
  answer,
  // Send `delivery` to the shell as raw bytes (end of file, clear screen).
  bytes,
  // The key belongs to the terminal: encode and send it as usual.
  terminal,
  // Neither the island nor the terminal: telar's own binding may take it.
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

class Island {
public:
  static constexpr std::size_t recent_capacity = 512;

  inline explicit Island(Keymap keymap = Keymap::emacs)
      : editor_(keymap) {}

  inline Editor &editor() noexcept {
    return editor_;
  }

  inline const Editor &editor() const noexcept {
    return editor_;
  }

  inline std::string_view delivery() const noexcept {
    return delivery_;
  }

  inline std::uint64_t revision() const noexcept {
    return revision_ + editor_.text().revision();
  }

  // The command typed while another runs waits for it; Enter arms it to run when that one
  // succeeds.
  inline bool queued() const noexcept {
    return armed_;
  }

  // While a program runs, typed lines go to it instead of the queue.
  inline bool answering() const noexcept {
    return answering_;
  }

  inline std::uint32_t secretKeys() const noexcept {
    return secret_keys_;
  }

  inline const std::vector<std::string> &recent() const noexcept {
    return recent_;
  }

  inline void setKeymap(Keymap keymap) {
    if (editor_.keymap() != keymap) {
      editor_.setKeymap(keymap);
      ++revision_;
    }
  }

  // A key in the editor or the queue. `incomplete` tells whether the shell would wait for more
  // of the command, so Enter continues it on a new line.
  // The rest of a command this one starts, from what this island sent (newest first) and then
  // `history`, newest first. Only while typing at the end of a non-empty line.
  inline std::string_view suggestion(std::span<const std::string> history) const noexcept {
    const auto &text = editor_.text();
    if (text.size() < 2 || text.cursor() != text.size() || menu_ || (editor_.keymap() == Keymap::vim && editor_.mode() != Mode::insert)) {
      return {};
    }
    const auto view = text.view();
    const auto extends = [&](std::string_view command) { return command.size() > view.size() && command.starts_with(view); };
    for (auto entry = recent_.rbegin(); entry != recent_.rend(); ++entry) {
      if (extends(*entry)) {
        return std::string_view{*entry}.substr(view.size());
      }
    }
    for (const auto &command : history) {
      if (extends(command)) {
        return std::string_view{command}.substr(view.size());
      }
    }
    return {};
  }

  template <typename Incomplete>
  inline Outcome press(Surface surface, const KeyPress &key, Incomplete &&incomplete, std::span<const std::string> history = {}) {
    delivery_.clear();
    // → and Ctrl-E at the end take the whole suggestion, Alt-F its next word, as fish does.
    if (const auto rest = suggestion(history); !rest.empty()) {
      const bool all = (key.key == Key::right && !key.modifiers.alt && !key.modifiers.shift) || key.key == Key::end || (key.key == Key::character && key.modifiers.control && (key.character == 'e' || key.character == 'f'));
      const bool word = (key.key == Key::character && key.modifiers.alt && key.character == 'f') || (key.key == Key::right && key.modifiers.alt);
      if (all || word) {
        auto taken = rest;
        if (word) {
          const auto start = taken.find_first_not_of(' ');
          const auto end = taken.find_first_of(" /", start == std::string_view::npos ? 0 : start);
          taken = taken.substr(0, end == std::string_view::npos ? taken.size() : end + (taken[end] == '/' ? 1 : 0));
        }
        const std::string copy{taken};
        editor_.text().insert(copy);
        return Outcome::edited;
      }
    }
    bool refining = false;
    refining_ = false;
    if (menu_) {
      if (const auto outcome = menuKey(key, refining)) {
        return *outcome;
      }
    }
    if (surface == Surface::running && key.key == Key::enter && key.modifiers.alt) {
      answering_ = !answering_;
      ++revision_;
      return Outcome::edited;
    }

    const auto outcome = handle(editor_.press(key), surface, incomplete);
    return refining && menu_ ? refine(outcome) : outcome;
  }

  // A key the user bound to an action; the rest of the island answers it as for any key.
  template <typename Incomplete>
  inline Outcome perform(Surface surface, Action action, Incomplete &&incomplete, std::span<const std::string> history = {}) {
    delivery_.clear();
    closeMenu();
    if (action == Action::accept_suggestion) {
      if (const auto rest = suggestion(history); !rest.empty()) {
        const std::string copy{rest};
        editor_.text().insert(copy);
      }
      return Outcome::edited;
    }
    return handle(editor_.perform(action), surface, incomplete);
  }

  inline void insertText(std::string_view text) {
    closeMenu();
    editor_.insertText(text);
  }

  // Writes `text` over [begin, end) of the line, as a path chosen for the word there does.
  inline void replaceText(std::size_t begin, std::size_t end, std::string_view text) {
    closeMenu();
    editor_.text().replace(begin, end, text);
  }

  inline const std::optional<Menu> &menu() const noexcept {
    return menu_;
  }

  // Offers `choices` for the word in [begin, end): one is written at once, more open the
  // menu. While `requests` are still looking for more, even one choice waits for them.
  inline void offer(std::vector<Choice> choices, std::size_t begin, std::size_t end, std::vector<std::uint64_t> requests, shell::Dialect dialect, std::string label = {}) {
    const bool whole = choices.size() <= Menu::capacity;
    if (!whole) {
      choices.resize(Menu::capacity);
    }
    auto all = choices;
    menu_ = Menu{.choices = std::move(choices), .begin = begin, .end = end, .requests = std::move(requests), .dialect = dialect, .label = std::move(label), .all = std::move(all), .floor = end, .whole = whole, .refined = std::exchange(refining_, false)};
    settle();
    ++revision_;
  }

  // What a pending request found, added to the menu it was asked for.
  inline bool receive(std::uint64_t request, std::span<const Choice> paths, bool truncated = false) {
    if (!menu_ || std::erase(menu_->requests, request) == 0) {
      return false;
    }
    menu_->whole = menu_->whole && !truncated && menu_->all.size() + paths.size() <= Menu::capacity;
    // Answers to an older word join, narrowed to the word as it is now.
    const auto word = typedWord();
    for (const auto &path : paths) {
      if (menu_->all.size() < Menu::capacity && std::ranges::none_of(menu_->all, [&](const Choice &choice) { return choice.text == path.text; })) {
        menu_->all.push_back(path);
        if (path.text.starts_with(word)) {
          menu_->choices.push_back(path);
        }
      }
    }
    settle();
    ++revision_;
    return true;
  }

  inline bool pending(std::uint64_t request) const noexcept {
    return menu_ && std::ranges::find(menu_->requests, request) != menu_->requests.end();
  }

  // The shell is back at its prompt after `succeeded` (or not): a queued command runs only
  // after a success, and otherwise stays as a draft.
  inline Outcome promptReturned(bool succeeded) {
    delivery_.clear();
    secret_keys_ = 0;
    answering_ = false;
    if (!armed_) {
      return Outcome::edited;
    }
    armed_ = false;
    ++revision_;
    if (!succeeded || editor_.text().empty()) {
      return Outcome::edited;
    }
    delivery_.assign(editor_.text().view());
    remember(delivery_);
    ++launches_;
    editor_.clear();
    return Outcome::run;
  }

  // Commands the editor sent to run, for a view to follow each one.
  inline std::uint64_t launches() const noexcept {
    return launches_;
  }

  inline void countSecretKey() noexcept {
    ++secret_keys_;
    ++revision_;
  }

  inline void clearSecret() noexcept {
    if (secret_keys_ != 0) {
      secret_keys_ = 0;
      ++revision_;
    }
  }

  inline void remember(std::string_view command) {
    if (command.empty() || (!recent_.empty() && recent_.back() == command)) {
      return;
    }
    if (recent_.size() == recent_capacity) {
      recent_.erase(recent_.begin());
    }
    recent_.emplace_back(command);
  }

private:
  template <typename Incomplete>
  inline Outcome handle(Request request, Surface surface, Incomplete &&incomplete) {
    switch (request) {
    case Request::none:
      history_index_.reset();
      return Outcome::edited;
    case Request::submit:
      return submit(surface, incomplete(editor_.text().view()));
    case Request::history_previous:
      return travel(-1);
    case Request::history_next:
      return travel(1);
    case Request::cancel:
      if (surface == Surface::running && editor_.text().empty()) {
        return Outcome::terminal;
      }
      editor_.clear();
      armed_ = false;
      history_index_.reset();
      ++revision_;
      return Outcome::edited;
    case Request::end_of_file:
      if (surface == Surface::running) {
        return Outcome::terminal;
      }
      delivery_.assign("\x04");
      return Outcome::bytes;
    case Request::clear_screen:
      delivery_.assign("\x0c");
      return surface == Surface::editor ? Outcome::bytes : Outcome::ignored;
    case Request::complete:
      return Outcome::complete;
    case Request::history_search:
      return surface == Surface::editor ? Outcome::search_history : Outcome::edited;
    case Request::unhandled:
      return Outcome::ignored;
    }
    return Outcome::ignored;
  }

  inline void closeMenu() noexcept {
    if (menu_) {
      menu_.reset();
      ++revision_;
    }
  }

  // A menu with nothing left to wait for and one choice writes it; with none it closes.
  inline void settle() {
    if (!menu_->requests.empty()) {
      return;
    }
    if (menu_->choices.size() == 1 && !menu_->refined) {
      accept();
    } else if (menu_->choices.empty()) {
      menu_.reset();
    }
  }

  inline void accept() {
    const auto &menu = *menu_;
    const auto &choice = menu.choices[menu.selected];
    auto word = quoteWord(choice.text, menu.dialect);
    if (!choice.directory) {
      word.push_back(' ');
    }
    const auto begin = menu.begin;
    const auto end = std::min(menu.end, editor_.text().size());
    menu_.reset();
    editor_.text().replace(begin, end, word);
    ++revision_;
  }

  // While the menu is open, Tab and the arrows move through it, Enter takes the choice and
  // Escape closes it; any other key closes it and edits as usual.
  inline std::optional<Outcome> menuKey(const KeyPress &key, bool &refining) {
    auto &menu = *menu_;
    const auto count = menu.choices.size();
    const bool forward = (key.key == Key::tab && !key.modifiers.shift) || key.key == Key::down || (key.key == Key::character && key.modifiers.control && key.character == 'n');
    const bool backward = key.key == Key::backtab || (key.key == Key::tab && key.modifiers.shift) || key.key == Key::up || (key.key == Key::character && key.modifiers.control && key.character == 'p');
    if (count != 0 && (forward || backward)) {
      menu.selected = (menu.selected + (forward ? 1 : count - 1)) % count;
      ++revision_;
      return Outcome::edited;
    }
    if (key.key == Key::enter && count != 0) {
      accept();
      return Outcome::edited;
    }
    if (key.key == Key::escape) {
      closeMenu();
      return Outcome::edited;
    }
    // Typing in the word, or erasing it, refines the choices once the editor has the key.
    const bool inserting = editor_.keymap() == Keymap::emacs || editor_.mode() == Mode::insert;
    const bool plain = !key.modifiers.control && !key.modifiers.alt;
    const bool typing = key.key == Key::character && plain && key.character > U' ' && key.character != 0x7f;
    if (inserting && (typing || (key.key == Key::backspace && plain))) {
      refining = true;
      return std::nullopt;
    }
    closeMenu();
    return std::nullopt;
  }

  // The word the menu completes, as typed so far.
  inline std::string_view typedWord() const noexcept {
    const auto text = editor_.text().view();
    if (!menu_ || menu_->begin > menu_->end || menu_->end > text.size()) {
      return {};
    }
    return text.substr(menu_->begin, menu_->end - menu_->begin);
  }

  // After a key typed or erased in the word: the choices that still start with it. Erasing
  // past where they were offered asks for them again; leaving the word closes the menu.
  inline Outcome refine(Outcome outcome) {
    auto &menu = *menu_;
    const auto &text = editor_.text();
    const auto cursor = text.cursor();
    if (cursor < menu.begin || text.view().substr(menu.begin, cursor - menu.begin).find_first_of(" \t\n") != std::string_view::npos) {
      closeMenu();
      return outcome;
    }
    menu.end = cursor;
    if (cursor < menu.floor || (!menu.whole && cursor != menu.floor)) {
      menu_.reset();
      refining_ = true;
      ++revision_;
      return Outcome::complete;
    }
    const auto word = typedWord();
    menu.choices.clear();
    for (const auto &choice : menu.all) {
      if (choice.text.starts_with(word)) {
        menu.choices.push_back(choice);
      }
    }
    menu.selected = 0;
    menu.refined = true;
    if (menu.choices.empty() && menu.requests.empty()) {
      closeMenu();
    }
    ++revision_;
    return outcome;
  }

  inline Outcome submit(Surface surface, bool incomplete) {
    if (incomplete) {
      editor_.newline();
      return Outcome::edited;
    }
    if (surface == Surface::running) {
      if (answering_) {
        delivery_.assign(editor_.text().view());
        editor_.clear();
        return Outcome::answer;
      }
      armed_ = !editor_.text().empty();
      ++revision_;
      return Outcome::edited;
    }
    if (editor_.text().empty()) {
      delivery_.clear();
      return Outcome::run;
    }
    delivery_.assign(editor_.text().view());
    remember(delivery_);
    ++launches_;
    editor_.clear();
    history_index_.reset();
    return Outcome::run;
  }

  // Up and Down past the editor's first and last line walk the commands sent from it, keeping
  // what was being written to come back to.
  inline Outcome travel(int direction) {
    if (recent_.empty()) {
      return Outcome::edited;
    }
    if (!history_index_) {
      if (direction > 0) {
        return Outcome::edited;
      }
      draft_.assign(editor_.text().view());
      history_index_ = recent_.size();
    }
    const auto next = static_cast<std::ptrdiff_t>(*history_index_) + direction;
    if (next < 0) {
      return Outcome::edited;
    }
    if (static_cast<std::size_t>(next) >= recent_.size()) {
      history_index_.reset();
      editor_.text().assign(draft_);
    } else {
      history_index_ = static_cast<std::size_t>(next);
      editor_.text().assign(recent_[*history_index_]);
    }
    editor_.text().moveTo(editor_.text().size());
    ++revision_;
    return Outcome::edited;
  }

  Editor editor_;
  std::vector<std::string> recent_;
  std::string draft_;
  std::string delivery_;
  std::optional<std::size_t> history_index_;
  std::optional<Menu> menu_;
  std::uint64_t revision_ = 0;
  std::uint64_t launches_ = 0;
  // The next offer refines the menu typing reopened: one choice left is not written.
  bool refining_ = false;
  std::uint32_t secret_keys_ = 0;
  bool armed_ = false;
  bool answering_ = false;
};

}
