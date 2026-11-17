export module telar.gui.platform.notification_commands;

import std;
import telar.sys.socket;
import telar.tbc;

import telar.gui.text.notification_payload;

import telar.gui.foundation.text;
import telar.wire.vocabulary;

// Interface: platform/command_line.cppm
export {
  namespace telar::gui::platform {

    struct CommandLine {
      static constexpr std::size_t maximum_arguments = 5;

      std::string_view executable;
      std::array<std::string_view, maximum_arguments> values{};
      std::size_t count = 0;

      // The command views the executable and the texts the arguments view, region `a`.
      template <std::size_t Count>
      [[nodiscard]] static constexpr tbc::view<CommandLine, tbc::lt::a> withArguments(tbc::view<std::string_view, tbc::lt::a> executable, tbc::view<std::array<std::string_view, Count>, tbc::lt::a> arguments) noexcept {
        static_assert(Count <= maximum_arguments);
        CommandLine command{.executable = executable, .count = Count};

        std::copy(arguments.begin(), arguments.end(), command.values.begin());

        return command;
      }

      [[nodiscard]] std::span<const std::string_view> arguments() const noexcept;
    };

  }
}

// Interface: platform/notification_commands.cppm
export {
  namespace telar::gui::platform {

    class AppleNotificationCommand {
    public:
      AppleNotificationCommand() = default;
      ~AppleNotificationCommand() = default;
      AppleNotificationCommand(const AppleNotificationCommand&) = delete;
      AppleNotificationCommand& operator=(const AppleNotificationCommand&) = delete;
      AppleNotificationCommand(AppleNotificationCommand&&) = delete;
      AppleNotificationCommand& operator=(AppleNotificationCommand&&) = delete;

      [[nodiscard]] CommandLine prepare(const NotificationPayload& payload);

    private:
      static constexpr std::string_view message_prefix = "display notification \"";
      static constexpr std::string_view title_prefix = "\" with title \"";
      static constexpr std::string_view quote = "\"";
      static constexpr std::size_t maximum_script_bytes = max_notification_title_bytes + max_notification_message_bytes + message_prefix.size() + title_prefix.size() + quote.size();

      BoundedText<maximum_script_bytes> script_;
    };

    struct LinuxNotificationCommand {
      [[nodiscard]] static CommandLine prepare(const NotificationPayload& payload) noexcept;
    };

#ifdef __APPLE__
    using NativeNotificationCommand = AppleNotificationCommand;
#else
    using NativeNotificationCommand = LinuxNotificationCommand;
#endif

  }
}

// Interface: platform/socket_limits.cppm
export {
  namespace telar::gui::platform {

    struct SocketLimits {
      static constexpr std::size_t path_bytes = sizeof(sockaddr_un{}.sun_path) - 1;
    };

  }
}

// Interface: platform/sound_commands.cppm
export {
  namespace telar::gui::platform {

    struct SoundAttempt {
      AgentSound sound = AgentSound::ready;
      std::size_t backend = 0;
    };

    struct AppleSoundCommands {
      static constexpr std::size_t attempts = 1;

      [[nodiscard]] static CommandLine prepare(SoundAttempt request);
    };

    class LinuxSoundCommands {
    public:
      static constexpr std::size_t attempts = 5;

      [[nodiscard]] static CommandLine prepare(SoundAttempt request);

    private:
      enum class Backend : std::uint8_t {
        canberra,
        pulse,
        pipewire,
        ffmpeg,
        mpv,
      };
      static constexpr std::array backends{Backend::canberra, Backend::pulse, Backend::pipewire, Backend::ffmpeg, Backend::mpv};
    };

#ifdef __APPLE__
    using NativeSoundCommands = AppleSoundCommands;
#else
    using NativeSoundCommands = LinuxSoundCommands;
#endif

  }
}
