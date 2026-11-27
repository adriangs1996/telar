// What the line recalls of the commands people ran: the history the runtime keeps, each command
// once with where it last ran and how it ended, and the order the suggestion and Up read it in
// for one pane. The choice of candidates lives here alone, so a runtime index that ranks them can
// take the list's place without the line knowing.
export module telar.gui.features.prompt:recall;

import std;

import :completion;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.tbc;

export namespace telar::gui::features::prompt {

  // How far Up reaches back: the pane's own commands, then its workspace's, then every one, as
  // atuin's filter_mode_shell_up_key_binding.
  enum class UpScope : std::uint8_t {
    global,
    workspace,
    pane,
  };

  // Where a line runs: its pane, the directory its shell is in and its workspace's path, empty
  // where they are not known.
  struct Place {
    std::uint64_t pane_id = 0;
    std::string_view directory;
    std::string_view workspace;
  };

}

namespace telar::gui::features::prompt {

  // The commands one walk of Up reads, newest first, copied when it starts: a command another pane
  // runs meanwhile, or a history that arrives, does not move the steps it counts.
  class Walk {
  public:
    explicit Walk(tbc::mut_a<Memory> memory);

    void clear() noexcept;

    void push(std::string_view command);

    [[nodiscard]] std::size_t size() const noexcept;

    [[nodiscard]] bool empty() const noexcept;

    [[nodiscard]] std::string_view operator[](std::size_t index) const noexcept;

  private:
    tbc::val_a<ds::String<Memory>> bytes_;
    tbc::val_a<ds::Vec<std::uint32_t, Memory>> ends_;
  };

  // A candidate the suggestion took: from the line's own commands or from the recall, by index,
  // so it is read again rather than kept as a view either could outlive.
  struct Suggested {
    enum class Source : std::uint8_t {
      none,
      own,
      recall,
    };

    Source source = Source::none;
    std::size_t index = 0;
  };

  class Recall {
  public:
    // The suggestions read the whole list on every change of the line: commands run since it
    // loaded replace the oldest instead of growing it for as long as the client lives.
    static constexpr std::size_t capacity = 1000;

    explicit Recall(tbc::mut_a<Memory> memory);

    [[nodiscard]] std::size_t size() const noexcept;

    [[nodiscard]] bool empty() const noexcept;

    // The `index`th command, newest first.
    [[nodiscard]] std::string_view command(std::size_t index) const noexcept;

    // Moves with every change to the commands or to how one ended.
    [[nodiscard]] std::uint64_t revision() const noexcept;

    // `command` ran from a line at `place`: the newest, once, its end not known yet.
    void remember(std::string_view command, const Place& place);

    // The command pane `pane_id` ran last ended, `failed` or not.
    void ended(std::uint64_t pane_id, bool failed) noexcept;

    // The list starts over, for the history the runtime sent: add then gives it newest first.
    void clear() noexcept;

    // One more command older than those added, as the history lists it; false past the capacity.
    bool add(std::string_view command, const Place& place, bool failed);

    // Whether `command`'s last run failed, as far as the list knows.
    [[nodiscard]] bool failed(std::string_view command) const noexcept;

    // The command whose rest the suggestion for `typed` at `place` shows: the newest that starts
    // with it and whose last run did not fail, from the same directory first, then the same
    // workspace, then anywhere, the pane's own first within each; then the line's `own`
    // commands, oldest first, which the list may not have.
    [[nodiscard]] Suggested suggest(History own, std::string_view typed, const Place& place) const noexcept;

    // The commands Up walks from `place` within `scope`, newest first and each once, that start
    // with `prefix` and are not it: the line's `own`, oldest first, then the list's of the same
    // pane, of the same workspace, and of any. Into `out`, replacing what it held.
    void walk(Walk& out, History own, std::string_view prefix, const Place& place, UpScope scope) const;

  private:
    // One allocation per command: its text, then the directory and the workspace it ran in.
    struct Entry {
      tbc::val_a<ds::String<Memory>> text;
      std::uint32_t command_end = 0;
      std::uint32_t directory_end = 0;
      std::uint64_t pane_id = 0;
      bool failed = false;

      [[nodiscard]] std::string_view command() const noexcept;

      [[nodiscard]] std::string_view directory() const noexcept;

      [[nodiscard]] std::string_view workspace() const noexcept;
    };

    [[nodiscard]] tbc::val_a<Entry> entry(std::string_view command, const Place& place, bool failed) const;

    tbc::mut_a<Memory> memory_;
    tbc::val_a<ds::Vec<Entry, Memory>> entries_;
    std::uint64_t revision_ = 0;
  };

  // What a key in the line reads of the commands run: the recall, where the line is, and how
  // far Up reaches back.
  struct Recalling {
    const Recall& recall;
    Place place;
    UpScope scope = UpScope::global;
  };

}
