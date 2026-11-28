#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <array>
#include <cstddef>
#include <cstring>
#include <span>
#include <stdexcept>
#include <string_view>

import telar.testing;
import telar.gui.foundation.system;
import telar.base.ds;
import telar.wire.vocabulary;

namespace {

  using namespace telar::gui;
  using telar::AgentSound;
  using telar::testing::check;

  void noticeArgumentsPreserveOwnedPayloadAndPreventOptionParsing() {
    const auto payload = NotificationPayload::create("--app-name=other", "a\"b\\c\nUTF-8: \xc3\xa1");
    system::AppleNotificationCommand apple;
    const auto command = apple.prepare(payload);

    check(command.executable == "/usr/bin/osascript" && command.arguments().size() == 2, "macOS must use the original AppleScript entry point");
    check(command.arguments().front() == "-e" && command.arguments().back() == "display notification \"abcUTF-8: \xc3\xa1\" with title \"--app-name=other\"", "AppleScript must contain only the sanitized title and message");

    const auto linux = system::LinuxNotificationCommand::prepare(payload);

    check(linux.executable == "notify-send" && linux.arguments().size() == 3, "Linux must use the desktop notification helper");
    check(linux.arguments().front() == "--" && linux.arguments()[1] == payload.title.view() && linux.arguments().back() == payload.message.view(), "notification titles must remain positional arguments even when they begin with an option");
  }

  void soundBackendsKeepTheOriginalProgramsFilesAndOrder() {
    constexpr telar::ds::Array executables{"canberra-gtk-play", "paplay", "pw-play", "ffplay", "mpv"};

    for (const auto sound : {AgentSound::ready, AgentSound::needs_input}) {
      const auto apple = system::AppleSoundCommands::prepare({.sound = sound});
      const std::string_view apple_file = sound == AgentSound::ready ? "/System/Library/Sounds/Glass.aiff" : "/System/Library/Sounds/Ping.aiff";

      check(apple.executable == "/usr/bin/afplay" && apple.arguments().size() == 1 && apple.arguments().front() == apple_file, "macOS must retain the semantic sound's original system file");

      const std::string_view linux_file = sound == AgentSound::ready ? "/usr/share/sounds/freedesktop/stereo/complete.oga" : "/usr/share/sounds/freedesktop/stereo/dialog-warning.oga";

      for (std::size_t backend = 0; backend < executables.size(); ++backend) {
        const auto command = system::LinuxSoundCommands::prepare({.sound = sound, .backend = backend});

        check(command.executable == executables[backend], "Linux audio fallback order must match the original adapter");
        if (backend == 0) {
          check(command.arguments().front() == "--id" && command.arguments().back() == (sound == AgentSound::ready ? "complete" : "dialog-warning"), "Canberra must receive the semantic event identifier");
        } else {
          check(command.arguments().back() == linux_file, "file-based players must retain the original freedesktop sound path");
        }
      }
    }

    bool rejected = false;

    try {
      static_cast<void>(system::LinuxSoundCommands::prepare({.backend = system::LinuxSoundCommands::attempts}));
    } catch (const std::out_of_range&) {
      rejected = true;
    }

    check(rejected, "an invalid backend index must fail before command construction");
  }

  const telar::testing::Case case_notice_arguments_preserve_owned_payload_and_prevent_option_parsing{"host_commands.notice_arguments_preserve_owned_payload_and_prevent_option_parsing", noticeArgumentsPreserveOwnedPayloadAndPreventOptionParsing};
  const telar::testing::Case case_sound_backends_keep_the_original_programs_files_and_order{"host_commands.sound_backends_keep_the_original_programs_files_and_order", soundBackendsKeepTheOriginalProgramsFilesAndOrder};

}
