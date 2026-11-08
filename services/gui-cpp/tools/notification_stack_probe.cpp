#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstddef>
#include <cstdint>
#include <cmath>
#include <cstdio>

import std;
import telar.base.memory;
import telar.base.text;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.gui.tools.probe_geometry;
import telar.gui.tools.probe_io;
import telar.gui.application.workspace_replica;
import telar.gui.presentation.notification_stack;

namespace {

using namespace telar;
using namespace telar::gui;

enum class Operation : std::uint8_t {
  reset,
  frame,
};

NotificationItem readItem() {
  NotificationItem item;
  item.id = NotificationId{probe::read<std::uint64_t>()};
  item.phase = static_cast<NotificationItem::Phase>(probe::read<std::uint8_t>());
  item.transition_position_ns = probe::read<std::uint64_t>();
  item.transition_updated_ns = probe::read<std::uint64_t>();
  item.expires_at_ns = probe::read<std::uint64_t>();
  item.target.kind = static_cast<NotificationTarget::Kind>(probe::read<std::uint8_t>());
  item.target.id = probe::read<std::uint64_t>();

  return item;
}

void frame(NotificationStack &stack) {
  const auto now_ns = probe::read<std::uint64_t>();
  const auto host = probe::readRect();
  const auto ratio = probe::read<float>();
  const auto visible_pane = probe::read<std::uint64_t>();
  const auto count = probe::read<std::uint8_t>();
  if (count > NotificationCenter::capacity) {
    throw std::length_error{"NotificationProbeCapacityExceeded"};
  }

  std::array<NotificationItem, NotificationCenter::capacity> storage;
  std::array<float, NotificationCenter::capacity> heights{};
  for (std::size_t index = 0; index < count; ++index) {
    storage[index] = readItem();
    heights[index] = probe::read<float>();
  }

  const auto items = std::span{storage}.first(count);
  const auto cards = stack.prepare({.items = items, .host = host, .ratio = ratio, .now_ns = now_ns}, [&](const NotificationItem &item) {
    return visible_pane != 0 && item.target.kind == NotificationTarget::Kind::pane && item.target.id == visible_pane;
  },
                                   [&](const NotificationItem &item, float) {
                                     return heights[static_cast<std::size_t>(&item - items.data())];
                                   });
  probe::write(static_cast<std::uint8_t>(cards.count));
  for (const auto &card : cards.items()) {
    probe::write(static_cast<std::uint8_t>(card.index));
    probe::write(card.id.value);
    probe::writeRect(card.bounds);
    probe::write(card.opacity);
  }
}

}

int main() try {
  NotificationStack stack;
  while (true) {
    const auto operation = std::getchar();
    if (operation == EOF) {
      return 0;
    }

    switch (static_cast<Operation>(operation)) {
    case Operation::reset:
      stack = {};
      break;
    case Operation::frame:
      frame(stack);
      break;
    default:
      throw std::invalid_argument{"UnknownNotificationStackOperation"};
    }
  }
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
