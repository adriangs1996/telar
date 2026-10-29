#include "application/notification_center.hpp"
#include "application/notification_item.hpp"
#include "core/memory.hpp"
#include "probe_io.hpp"
#include "probe_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <optional>
#include <stdexcept>

namespace {

using namespace telar;
using namespace telar::gui;

enum class Operation : std::uint8_t {
  reset,
  push,
  advance,
  dismiss,
  activate,
  sample,
};

struct Outcome {
  NotificationId id{};
  bool changed = false;
  std::optional<NotificationTarget> activated = std::nullopt;
};

NotificationTarget readTarget() {
  const auto kind = static_cast<NotificationTarget::Kind>(probe::read<std::uint8_t>());
  const auto id = probe::read<std::uint64_t>();

  return {.kind = kind, .id = kind == NotificationTarget::Kind::none ? 0 : id};
}

void writeTarget(NotificationTarget target) {
  probe::write(static_cast<std::uint8_t>(target.kind));
  probe::write(target.kind == NotificationTarget::Kind::none ? 0 : target.id);
}

NotificationId push(NotificationCenter &center, std::uint64_t now_ns, SystemAllocator &memory) {
  const auto level = static_cast<NotificationLevel>(probe::read<std::uint8_t>());
  const auto target = readTarget();
  const auto duration = probe::read<std::uint64_t>();
  const auto title = probe::readText(memory);
  const auto message = probe::readText(memory);
  const auto link = probe::readText(memory);

  return center.push(now_ns, {.level = level, .target = target, .title = title, .message = message, .link = link, .duration_ns = duration});
}

Outcome operate(NotificationCenter &center, Operation operation, std::uint64_t now_ns, SystemAllocator &memory) {
  switch (operation) {
  case Operation::reset:
    center = NotificationCenter{probe::read<std::uint64_t>()};
    return {};
  case Operation::push:
    return {.id = push(center, now_ns, memory)};
  case Operation::advance:
    return {.changed = center.advance(now_ns)};
  case Operation::dismiss:
    return {.changed = center.dismiss(NotificationId{probe::read<std::uint64_t>()}, now_ns)};
  case Operation::activate:
    return {.activated = center.activate(NotificationId{probe::read<std::uint64_t>()}, now_ns)};
  case Operation::sample:
    return {};
  }

  throw std::runtime_error{"InvalidNotificationOperation"};
}

void writeItem(const NotificationItem &item, std::uint64_t now_ns) {
  probe::write(item.id.value);
  probe::write(static_cast<std::uint8_t>(item.level));
  writeTarget(item.target);
  probe::write(static_cast<std::uint8_t>(item.phase));
  probe::write(item.transition_position_ns);
  probe::write(item.transition_updated_ns);
  probe::write(item.expires_at_ns);
  probe::write(item.opacity());
  probe::write(item.opacity(now_ns));
  probe::write(static_cast<std::uint8_t>(item.clickable()));
  probe::writeText(item.title.view());
  probe::writeText(item.message.view());
  probe::writeText(item.link.view());
  probe::writeText(item.linkHost());
}

void writeSnapshot(const NotificationCenter &center, Outcome outcome, std::uint64_t now_ns, std::uint64_t interval_ns) {
  probe::write(outcome.id.value);
  probe::write(static_cast<std::uint8_t>(outcome.changed));
  probe::write(static_cast<std::uint8_t>(outcome.activated.has_value()));
  writeTarget(outcome.activated.value_or(NotificationTarget{}));
  probe::write(static_cast<std::uint8_t>(center.items().size()));
  for (const auto &item : center.items()) {
    writeItem(item, now_ns);
  }

  const auto deadline = center.nextDeadline(now_ns, interval_ns);
  probe::write(static_cast<std::uint8_t>(deadline.has_value()));
  probe::write(deadline.value_or(0));
}

}

int main() try {
  SystemAllocator memory;
  NotificationCenter center;
  while (true) {
    const auto operation = std::getchar();
    if (operation == EOF) {
      return 0;
    }

    const auto now = probe::read<std::uint64_t>();
    const auto interval = probe::read<std::uint64_t>();
    const auto outcome = operate(center, static_cast<Operation>(operation), now, memory);
    writeSnapshot(center, outcome, now, interval);
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
