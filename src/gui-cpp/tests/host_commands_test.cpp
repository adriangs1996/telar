#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <array>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstring>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include "assertions.hpp"
#include <algorithm>
#include <span>
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstdint>
#include <exception>
#include <iostream>



import telar.gui.application.host_effects;
import telar.gui.platform.notification_commands;

namespace {

using namespace telar::gui;
using telar::AgentSound;
using telar::gui::test::require;

void noticeArgumentsPreserveOwnedPayloadAndPreventOptionParsing() {
  const auto payload = NotificationPayload::create("--app-name=other", "a\"b\\c\nUTF-8: \xc3\xa1");
  platform::AppleNotificationCommand apple;
  const auto command = apple.prepare(payload);
  require(command.executable == "/usr/bin/osascript" && command.arguments().size() == 2, "macOS must use the original AppleScript entry point");
  require(command.arguments().front() == "-e" && command.arguments().back() == "display notification \"abcUTF-8: \xc3\xa1\" with title \"--app-name=other\"", "AppleScript must contain only the sanitized title and message");

  const auto linux = platform::LinuxNotificationCommand::prepare(payload);
  require(linux.executable == "notify-send" && linux.arguments().size() == 3, "Linux must use the desktop notification helper");
  require(linux.arguments().front() == "--" && linux.arguments()[1] == payload.title.view() && linux.arguments().back() == payload.message.view(), "notification titles must remain positional arguments even when they begin with an option");
}

void soundBackendsKeepTheOriginalProgramsFilesAndOrder() {
  constexpr std::array executables{"canberra-gtk-play", "paplay", "pw-play", "ffplay", "mpv"};
  for (const auto sound : {AgentSound::ready, AgentSound::needs_input}) {
    const auto apple = platform::AppleSoundCommands::prepare({.sound = sound});
    const std::string_view apple_file = sound == AgentSound::ready ? "/System/Library/Sounds/Glass.aiff" : "/System/Library/Sounds/Ping.aiff";
    require(apple.executable == "/usr/bin/afplay" && apple.arguments().size() == 1 && apple.arguments().front() == apple_file, "macOS must retain the semantic sound's original system file");

    const std::string_view linux_file = sound == AgentSound::ready ? "/usr/share/sounds/freedesktop/stereo/complete.oga" : "/usr/share/sounds/freedesktop/stereo/dialog-warning.oga";
    for (std::size_t backend = 0; backend < executables.size(); ++backend) {
      const auto command = platform::LinuxSoundCommands::prepare({.sound = sound, .backend = backend});
      require(command.executable == executables[backend], "Linux audio fallback order must match the original adapter");
      if (backend == 0) {
        require(command.arguments().front() == "--id" && command.arguments().back() == (sound == AgentSound::ready ? "complete" : "dialog-warning"), "Canberra must receive the semantic event identifier");
      } else {
        require(command.arguments().back() == linux_file, "file-based players must retain the original freedesktop sound path");
      }
    }
  }

  bool rejected = false;
  try {
    static_cast<void>(platform::LinuxSoundCommands::prepare({.backend = platform::LinuxSoundCommands::attempts}));
  } catch (const std::out_of_range &) {
    rejected = true;
  }

  require(rejected, "an invalid backend index must fail before command construction");
}

}

int main() try {
  noticeArgumentsPreserveOwnedPayloadAndPreventOptionParsing();
  soundBackendsKeepTheOriginalProgramsFilesAndOrder();

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
