#include "application/notification_payload.hpp"
#include "application/sound_playback.hpp"
#include "core/configuration.hpp"
#include "core/memory.hpp"
#include "probe_io.hpp"
#include "probe_text.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <stdexcept>

namespace {

using namespace telar;
using namespace telar::gui;

enum class Operation : std::uint8_t {
  reset,
  configure,
  request,
  complete,
  scheduling_failed,
  payload,
};

bool readFlag() {
  const auto value = probe::read<std::uint8_t>();
  if (value > 1) {
    throw std::invalid_argument{"InvalidSoundPolicyFlag"};
  }

  return value != 0;
}

SoundPolicy readPolicy() {
  const auto enabled = readFlag();
  const auto ready = readFlag();
  const auto needs_input = readFlag();

  return {.enabled = enabled, .ready = ready, .needs_input = needs_input};
}

AgentSound readSound() {
  const auto value = probe::read<std::uint8_t>();
  if (value > static_cast<std::uint8_t>(AgentSound::needs_input)) {
    throw std::invalid_argument{"InvalidAgentSound"};
  }

  return static_cast<AgentSound>(value);
}

void writePayload(SystemAllocator &memory) {
  const auto title = probe::readText(memory);
  const auto message = probe::readText(memory);
  const auto payload = NotificationPayload::create(title, message);
  probe::writeText(payload.title.view());
  probe::writeText(payload.message.view());
}

SoundRequestOutcome operate(SoundPlayback &playback, Operation operation, SystemAllocator &memory) {
  switch (operation) {
  case Operation::reset:
    playback = SoundPlayback{readPolicy()};
    break;
  case Operation::configure:
    playback.configure(readPolicy());
    break;
  case Operation::request:
    return playback.request(readSound());
  case Operation::complete:
    if (const auto next = playback.complete()) {
      return {.state = SoundRequestOutcome::State::start, .sound = *next};
    }

    break;
  case Operation::scheduling_failed:
    playback.schedulingFailed();
    break;
  case Operation::payload:
    writePayload(memory);
    break;
  }

  return {};
}

void writeSnapshot(const SoundPlayback &playback, SoundRequestOutcome outcome) {
  probe::write(static_cast<std::uint8_t>(outcome.state));
  probe::write(outcome.state == SoundRequestOutcome::State::start ? static_cast<std::uint8_t>(outcome.sound) : std::uint8_t{0});
  probe::write(static_cast<std::uint8_t>(playback.active()));
  probe::write(static_cast<std::uint8_t>(playback.queued().has_value()));
  probe::write(static_cast<std::uint8_t>(playback.queued().value_or(AgentSound::ready)));
  const auto policy = playback.configuration();
  probe::write(static_cast<std::uint8_t>(policy.enabled));
  probe::write(static_cast<std::uint8_t>(policy.ready));
  probe::write(static_cast<std::uint8_t>(policy.needs_input));
}

}

int main() try {
  SystemAllocator memory;
  SoundPlayback playback;
  while (true) {
    const auto value = std::getchar();
    if (value == EOF) {
      return 0;
    }

    if (value > static_cast<int>(Operation::payload)) {
      throw std::invalid_argument{"InvalidNotificationEffectOperation"};
    }

    const auto outcome = operate(playback, static_cast<Operation>(value), memory);
    writeSnapshot(playback, outcome);
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
