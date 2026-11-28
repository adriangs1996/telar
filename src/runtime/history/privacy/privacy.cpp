module telar.runtime.history.privacy;

import std;
import telar.tbc;
import telar.wire.history;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    std::span<char> allocated(ds::Vec<char, ConcurrentMemory>& buffer) {
      if (buffer.empty()) {
        buffer.resize(HistoryRedaction::room_bytes);
      }

      return buffer.viewMut();
    }

    tbc::val_a<ds::Option<std::string_view>> kept(tbc::val_a<FilteredCommand> filtered) noexcept {
      if (filtered.verdict == HistoryVerdict::drop) {
        return ds::none;
      }

      return filtered.text;
    }

  }

  HistoryRedaction::HistoryRedaction(ConcurrentMemory& memory)
      : command_(memory),
        output_(memory) {}

  std::span<char> HistoryRedaction::command() const {
    return allocated(command_);
  }

  std::span<char> HistoryRedaction::output() const {
    return allocated(output_);
  }

  tbc::val_a<ds::Option<HistoryEventView>> keptPaneEvent(const HistoryFilters& filters, tbc::ref_a<HistoryEventView> event, tbc::val_a<std::span<char>> command_room, tbc::val_a<std::span<char>> output_room) { // NOLINT(bugprone-easily-swappable-parameters): the command's room before its output's, as the declaration says
    // A command is filtered as it starts and as it finishes, the same way, so its run is found again.
    if (event.kind != HistoryEventKind::command_finished && event.kind != HistoryEventKind::command_started) {
      return event;
    }

    const auto& command = event.command;
    const auto text = kept(filters.filterPane(command.command, command.directory, command_room));
    if (!text) {
      return ds::none;
    }

    auto written = event;

    written.command.command = *text;
    if (command.output.empty()) {
      return written;
    }

    const auto output = textView(command.output);
    const auto redacted = filters.filterOutput(output, output_room, HistoryOutput::maximum_content_bytes);

    if (redacted.data() != output.data() || redacted.size() != output.size()) {
      // What capture did not keep stays counted as missing, so a redaction alone never marks the
      // output cut.
      written.command.output = byteView(redacted);
      written.command.output_observed = command.output_observed - std::min<std::uint64_t>(command.output_observed, output.size()) + redacted.size();
    }

    return written;
  }

  tbc::val_a<ds::Option<std::string_view>> keptAgentCommand(const HistoryFilters& filters, tbc::val_a<std::string_view> command, std::string_view directory, tbc::val_a<std::span<char>> room) {
    return kept(filters.filterAgent(command, directory, room));
  }

  tbc::val_a<ds::Option<std::string_view>> keptImportedCommand(const HistoryFilters& filters, tbc::val_a<std::string_view> command, std::string_view directory, tbc::val_a<std::span<char>> room) {
    return kept(filters.filterPane(command, directory, room));
  }

}
