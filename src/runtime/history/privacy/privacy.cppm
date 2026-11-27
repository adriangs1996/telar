export module telar.runtime.history.privacy;

import std;
import telar.tbc;
import telar.config.runtime;
import telar.base.memory.allocators;
import telar.runtime.history.event;
import telar.base.ds;

// What the history writes of what it is given: the configured filters applied to a command and
// the directory it ran in, and the secrets they find, in the command and in its output, redacted
// into buffers each write reuses. Pane commands, agents' commands and imported lines all pass
// here, so a filter means the same whichever way a command arrives.
export namespace telar::runtime {

  // The buffers a redaction is written into, each allocated at its bound the first time it is
  // asked for and never again, so the room it hands out stays where it is: what a later
  // redaction writes there replaces the last, as a cache's entry does, and the buffers are
  // shared rather than lent. A text past its bound has no room to be redacted in and is not kept.
  class [[tbc::shared]] HistoryRedaction {
  public:
    // The longest command and output a write hands the history, and what redacting them adds.
    static constexpr std::size_t maximum_text_bytes = std::size_t{64} * 1024;

    // How many bytes each room holds. A redaction can make a text longer: `token=a` becomes
    // `token=[redacted]`. No rule finds a secret in fewer bytes than its redaction takes past
    // them, so three times the longest text holds it.
    static constexpr std::size_t room_bytes = (maximum_text_bytes * 3) + 16;

    explicit HistoryRedaction(ConcurrentMemory& memory);

    // Room for the redaction of a command or an output, room_bytes each.
    std::span<char> command() const;
    std::span<char> output() const;

  private:
    mutable ds::Vec<char, ConcurrentMemory> command_;
    mutable ds::Vec<char, ConcurrentMemory> output_;
  };

  // The event as the history writes it, or none when the filters refuse its command; the rooms
  // are HistoryRedaction's for its command and its output.
  tbc::val_a<ds::Option<HistoryEventView>> keptPaneEvent(const HistoryFilters& filters, tbc::ref_a<HistoryEventView> event, tbc::val_a<std::span<char>> command_room, tbc::val_a<std::span<char>> output_room); // NOLINT(bugprone-easily-swappable-parameters): the rooms come in the order of what they hold, the command before its output

  tbc::val_a<ds::Option<std::string_view>> keptAgentCommand(const HistoryFilters& filters, tbc::val_a<std::string_view> command, std::string_view directory, tbc::val_a<std::span<char>> room);

  // A line an import read, with the directory its source knew, or none.
  tbc::val_a<ds::Option<std::string_view>> keptImportedCommand(const HistoryFilters& filters, tbc::val_a<std::string_view> command, std::string_view directory, tbc::val_a<std::span<char>> room);

}
