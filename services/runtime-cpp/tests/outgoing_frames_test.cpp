#include "check.hpp"
#include "transport/outgoing_frames.hpp"
#include <optional>
#include <random>

using namespace telar;
using namespace telar::runtime;

namespace {

struct ExpectedFrame {
  std::vector<Byte> bytes{};
  DeliveryLane lane;
  std::size_t sent = 0;
  std::optional<std::uint64_t> deferred_id{};
};

std::vector<Byte> encodeFrame(const auto &message) {
  std::vector<Byte> result(frame_prefix_size + Codec::encodedSize(message));
  std::span<Byte> bytes = result;
  u32::encode(result.size() - frame_prefix_size, bytes);
  Codec::encode(message, bytes);
  return result;
}

void testRandomWrites() {
  SystemAllocator system;
  BudgetAllocator memory{system, 2 * 1024 * 1024};
  OutgoingFrames queue{memory};
  std::vector<ExpectedFrame> pending;
  std::optional<ExpectedFrame> active;
  std::mt19937 random{0x525350};
  const std::array tags{ServerTag::request_completed, ServerTag::history_results, ServerTag::pane_frame,
                        ServerTag::pane_title, ServerTag::graphics_image, ServerTag::runtime_stopping};

  std::string current_text;
  const auto project = [&](const DeferredResponse &request, auto &&send) {
    send(PaneText{.request_id = std::get<ReadPane>(request).request_id, .pane_id = 1, .text = current_text});
  };
  const auto select = [&] {
    if (!active && !pending.empty()) {
      const auto first = std::min_element(pending.begin(), pending.end(), [](const auto &left, const auto &right) { return left.lane < right.lane; });
      active = std::move(*first);
      if (active->deferred_id) {
        active->bytes = encodeFrame(PaneText{.request_id = *active->deferred_id, .pane_id = 1, .text = current_text});
      }
      pending.erase(first);
    }
  };

  const auto write = [&](std::size_t limit) {
    const auto bytes = queue.prepare(limit, project);
    select();
    check(bytes.empty() == !active);
    if (bytes.empty()) {
      return;
    }

    const auto count = random() % (bytes.size() + 1);
    std::size_t consumed = 0;
    while (consumed < count) {
      select();
      check(active.has_value());
      const auto amount = std::min(count - consumed, active->bytes.size() - active->sent);
      check(std::equal(bytes.begin() + consumed, bytes.begin() + consumed + amount, active->bytes.begin() + active->sent));
      active->sent += amount;
      consumed += amount;
      if (active->sent == active->bytes.size()) {
        active.reset();
      }
    }
    queue.consume(count);

    const auto responses = std::count_if(pending.begin(), pending.end(), [](const auto &frame) { return responseLane(frame.lane); });
    check(queue.responseDepth() == static_cast<std::size_t>(responses));
  };

  for (unsigned operation = 0; operation < 20000; ++operation) {
    current_text.assign(random() % 1024, static_cast<char>('a' + random() % 26));
    if (random() % 4 == 0 || pending.size() > 180) {
      write(1 + random() % 4096);
      continue;
    }

    if (random() % 4 == 0) {
      const bool full = queue.responseDepth() == 128;
      try {
        queue.defer(ReadPane{.request_id = operation + 1, .pane_id = 1});
        check(!full);
        pending.push_back(ExpectedFrame{.lane = DeliveryLane::management, .deferred_id = operation + 1});
      } catch (const ResponseQueueFull &) {
        check(full);
      }
      continue;
    }

    const auto tag = tags[random() % tags.size()];
    std::vector<Byte> payload(1 + random() % 512);
    std::generate(payload.begin(), payload.end(), [&] { return static_cast<Byte>(random()); });
    payload.front() = static_cast<Byte>(tag);
    const auto lane = deliveryLane(tag);
    const bool full = responseLane(lane) && queue.responseDepth() == 128;
    try {
      queue.appendPayload(payload);
      check(!full);
      ExpectedFrame expected{.bytes = std::vector<Byte>(frame_prefix_size + payload.size()), .lane = lane};
      std::span<Byte> frame = expected.bytes;
      u32::encode(payload.size(), frame);
      std::copy(payload.begin(), payload.end(), frame.begin());
      pending.push_back(std::move(expected));
    } catch (const ResponseQueueFull &) {
      check(full);
    }
  }

  while (!queue.empty()) {
    write(65536);
  }
  check(!active && pending.empty());
  check(queue.responseHighWater() == 128);
}

void testCapacityAndReservation() {
  SystemAllocator system;
  BudgetAllocator memory{system, 8192};
  OutgoingFrames queue{memory};
  for (unsigned index = 0; index < 128; ++index) {
    queue.append(RequestCompleted{.request_id = index + 1});
  }

  bool rejected = false;
  try {
    queue.append(RequestCompleted{.request_id = 129});
  } catch (const ResponseQueueFull &) {
    rejected = true;
  }
  check(rejected && queue.responseDepth() == 128);

  auto first = queue.prepare(1);
  check(first.size() == 1 && queue.responseDepth() == 127);
  queue.append(RequestCompleted{.request_id = 129});
  check(queue.responseDepth() == 128);
  queue.consume(1);
  queue.append(RuntimeStopping{});
  auto partial = queue.prepare(4096);
  check(partial.size() == frame_prefix_size + Codec::encodedSize(RequestCompleted{.request_id = 1}) - 1);
  queue.consume(partial.size());
  auto stopping = queue.prepare(4096);
  check(stopping[frame_prefix_size] == static_cast<Byte>(ServerTag::runtime_stopping));
  queue.consume(stopping.size());
  queue.clear();
  check(queue.responseDepth() == 0 && queue.responseHighWater() == 128);

  queue.appendConfirmation(NotificationShown{.request_id = 1}, [&](auto &reply) {
    for (unsigned index = 0; index < 127; ++index) {
      queue.append(RequestCompleted{.request_id = index + 2});
    }
    reply.delivered_clients = 7;
  });
  const auto batch = queue.prepare(4096);
  auto payload = batch.subspan(frame_prefix_size, MessageSchema<NotificationShown>::payload_size);
  std::array<Byte, 64> scratch;
  DecodeStorage storage{scratch};
  check(Codec::decode<NotificationShown>(payload, storage).delivered_clients == 7);
  queue.consume(batch.size());
  check(queue.empty());

  const auto retained = memory.liveBytes();
  rejected = false;
  try {
    queue.append(PaneClipboard{.pane_id = 1, .bytes = std::vector<Byte>(8192)});
  } catch (const std::bad_alloc &) {
    rejected = true;
  }
  check(rejected && queue.empty() && queue.responseDepth() == 0 && memory.liveBytes() == retained);
  queue.append(RequestCompleted{.request_id = 1});
  const auto bytes = queue.prepare(4096);
  check(!bytes.empty());
  queue.consume(bytes.size());
}

void testDeferredAllocationFailure() {
  SystemAllocator system;
  BudgetAllocator memory{system, 256};
  OutgoingFrames queue{memory};
  queue.defer(QueryLimits{1});
  const std::string oversized(1024, 'x');
  const auto oversized_response = [&](const DeferredResponse &, auto &&send) {
    send(PaneText{.request_id = 1, .pane_id = 1, .text = oversized});
  };
  bool failed = false;
  try {
    queue.prepare(4096, oversized_response);
  } catch (const std::bad_alloc &) {
    failed = true;
  }
  check(failed && !queue.empty() && queue.size() == 0 && queue.responseDepth() == 1);

  const auto response = [](const DeferredResponse &, auto &&send) { send(RequestCompleted{.request_id = 1}); };
  const auto bytes = queue.prepare(4096, response);
  check(bytes.size() == encodeFrame(RequestCompleted{.request_id = 1}).size() && queue.responseDepth() == 0);
  queue.consume(bytes.size());
  check(queue.empty());

  BudgetAllocator exhausted{system, 0};
  OutgoingFrames refused{exhausted};
  failed = false;
  try {
    refused.defer(QueryLimits{1});
  } catch (const std::bad_alloc &) {
    failed = true;
  }
  check(failed && refused.empty() && refused.responseDepth() == 0 && refused.responseHighWater() == 0);
}

}

void testOutgoingFrames() {
  testRandomWrites();
  testCapacityAndReservation();
  testDeferredAllocationFailure();
}
