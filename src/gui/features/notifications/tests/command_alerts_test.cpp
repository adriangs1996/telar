#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <string>
#include <string_view>

import telar.testing;
import telar.gui.foundation.core;
import telar.gui.features.notifications;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  using namespace telar::gui::features::notifications;

  std::string message(FinishedCommand command) {
    CommandAlerts::Message text;

    return std::string{CommandAlerts::input(command, text).message};
  }

  // The notice names the command by its first line and says how long it ran as the separators
  // do, and how a failure ended.
  void noticeSaysWhatRanAndHowLong() {
    constexpr std::uint32_t minute_and_five = 65'000;
    constexpr std::uint32_t hour_and_more = 3'723'000;

    check(message({.command = "cargo build\n--release", .duration_ms = minute_and_five}) == "cargo build · 1m 05s", "the first line of the command and its minutes and seconds");
    check(message({.command = "make", .failed = true, .status = -1, .duration_ms = hour_and_more}) == "make · 1h 02m 03s · exit -1", "hours, and the exit status of a failure");

    const std::string long_command(CommandAlerts::message_capacity * 2, 'x');
    const auto cut = message({.command = long_command, .duration_ms = minute_and_five});

    check(cut.size() <= CommandAlerts::message_capacity && cut.ends_with(" · 1m 05s"), "a command too long for the notice is cut, keeping how long it ran");
  }

  // Only a command that ran at least as long as asked, nobody watching it end, tells of it.
  void onlyUnwatchedLongCommandsAlert() {
    const LongCommandNotice notice{.after_ms = 30'000};
    const FinishedCommand long_command{.duration_ms = 30'000};
    const FinishedCommand quick_command{.duration_ms = 29'999};

    check(CommandAlerts::alerts(notice, long_command, false), "a long command nobody watched alerts");
    check(!CommandAlerts::alerts(notice, quick_command, false), "a quicker one does not");
    check(!CommandAlerts::alerts(notice, long_command, true), "nor one the window showed as it ended");
    check(!CommandAlerts::alerts({.enabled = false}, long_command, false), "nor any while the notices are off");
  }

  const telar::testing::Case case_notice_says_what_ran_and_how_long{"command_alerts.notice_says_what_ran_and_how_long", noticeSaysWhatRanAndHowLong};
  const telar::testing::Case case_only_unwatched_long_commands_alert{"command_alerts.only_unwatched_long_commands_alert", onlyUnwatchedLongCommandsAlert};

}
