module;

// The notice a command that ran long gives when it ends where nobody watches it.
export module telar.gui.features.notifications:commands;

import std;
import telar.tbc;

import :center;
import telar.gui.foundation.core;
import telar.gui.foundation.text;

export namespace telar::gui::features::notifications {

  // A command of pane `pane_id` that ended after running `duration_ms`, with `status` when it
  // failed.
  struct FinishedCommand {
    std::uint64_t pane_id = 0;
    std::string_view command;
    bool failed = false;
    std::int32_t status = 0;
    std::uint32_t duration_ms = 0;
  };

  class CommandAlerts {
  public:
    static constexpr std::size_t message_capacity = 160;
    using Message = BoundedText<message_capacity>;

    // Whether `command` tells of its end: `notice` is on, the command ran at least as long as it
    // asks, and nobody `watched` it end.
    [[nodiscard]] static constexpr bool alerts(const LongCommandNotice& notice, const FinishedCommand& command, bool watched) noexcept {
      return notice.enabled && !watched && command.duration_ms >= notice.after_ms;
    }

    // The notice: how the command ended, its first line and how long it ran, written into
    // `message`, region `a`. A click on it shows the pane.
    [[nodiscard]] static tbc::val_a<NotificationInput> input(const FinishedCommand& command, tbc::mut_a<Message> message);
  };

}
