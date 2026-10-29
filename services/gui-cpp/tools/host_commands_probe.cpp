#include "application/host_effects.hpp"
#include "application/notification_payload.hpp"
#include "core/memory.hpp"
#include "platform/command_line.hpp"
#include "platform/notification_commands.hpp"
#include "platform/sound_commands.hpp"
#include "probe_io.hpp"
#include "probe_text.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <stdexcept>

namespace {

using namespace telar;
using namespace telar::gui;

enum class Host : std::uint8_t {
  apple,
  linux,
};
enum class Operation : std::uint8_t {
  sound,
  notification,
};

void writeCommand(const platform::CommandLine &command) {
  probe::write(std::uint8_t{1});
  probe::write(static_cast<std::uint8_t>(command.count + 1));
  probe::writeText(command.executable);
  for (const auto argument : command.arguments()) {
    probe::writeText(argument);
  }
}

template <typename Commands>
bool play(AgentSound sound, std::uint8_t success_mask) {
  for (std::size_t backend = 0; backend < Commands::attempts; ++backend) {
    writeCommand(Commands::prepare({.sound = sound, .backend = backend}));
    if ((success_mask & (std::uint32_t{1} << backend)) != 0) {
      return true;
    }
  }

  return false;
}

bool operate(Operation operation, Host host, SystemAllocator &memory) {
  if (operation == Operation::sound) {
    const auto sound = static_cast<AgentSound>(probe::read<std::uint8_t>());
    const auto success_mask = probe::read<std::uint8_t>();

    return host == Host::apple ? play<platform::AppleSoundCommands>(sound, success_mask) : play<platform::LinuxSoundCommands>(sound, success_mask);
  }

  const auto succeeds = probe::read<std::uint8_t>() != 0;
  const auto title = probe::readText(memory);
  const auto message = probe::readText(memory);
  const auto payload = NotificationPayload::create(title, message);
  if (host == Host::apple) {
    platform::AppleNotificationCommand command;
    writeCommand(command.prepare(payload));
  } else {
    writeCommand(platform::LinuxNotificationCommand::prepare(payload));
  }

  return succeeds;
}

}

int main() try {
  SystemAllocator memory;
  probe::write(static_cast<std::uint16_t>(HostEffectLimits::maximum_system_notifications));
  while (true) {
    const auto operation = std::getchar();
    if (operation == EOF) {
      return 0;
    }

    const auto host = probe::read<std::uint8_t>();
    if (operation > static_cast<int>(Operation::notification) || host > static_cast<std::uint8_t>(Host::linux)) {
      throw std::invalid_argument{"UnknownHostCommandOperation"};
    }

    const auto succeeded = operate(static_cast<Operation>(operation), static_cast<Host>(host), memory);
    probe::write(std::uint8_t{0});
    probe::write(static_cast<std::uint8_t>(succeeded));
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
