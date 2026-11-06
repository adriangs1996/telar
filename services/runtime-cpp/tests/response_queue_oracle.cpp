#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_base/memory/allocator.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <concepts>
#include <stdexcept>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include <cassert>
#include <cstdint>
#include <cstring>
#include <span>
#include <array>
#include <bit>
#include <exception>



import telar.runtime.transport.connection;

using namespace telar;
using namespace telar::runtime;

struct Operation {
  std::uint32_t kind;
  std::uint64_t value;
};

extern "C" std::size_t evaluate(const Operation *operations, std::size_t count, Byte *output) {
  SystemAllocator memory;
  OutgoingFrames queue{memory};
  Notification notification;
  notification.title = "Queue";
  notification.message = "Notice";
  std::array<Byte, 4096> scratch;
  std::size_t written = 0;

  const auto notify = [&] {
    try {
      queue.append(notification);
      return true;
    } catch (const ResponseQueueFull &) {
      queue.recordDrop();
      return false;
    }
  };

  for (const auto &operation : std::span{operations, count}) {
    bool accepted = true;
    Byte selected = 0;
    Byte delivered = 0;
    std::uint64_t identity = 0;
    try {
      switch (operation.kind) {
      case 0:
        queue.append(RequestCompleted{.request_id = operation.value});
        break;
      case 1:
        queue.append(HistoryResults{.request_id = operation.value});
        break;
      case 2: {
        auto bytes = queue.prepare(max_payload_size);
        if (bytes.empty()) {
          break;
        }
        const auto size = u32::decode(bytes);
        const auto payload = bytes.first(size);
        DecodeStorage storage{scratch};
        switch (static_cast<ServerTag>(payload.front())) {
        case ServerTag::request_completed:
          selected = 1;
          identity = Codec::decode<RequestCompleted>(payload, storage).request_id;
          break;
        case ServerTag::history_results:
          selected = 2;
          identity = Codec::decode<HistoryResults>(payload, storage).request_id;
          break;
        case ServerTag::notification:
          selected = 3;
          break;
        case ServerTag::notification_shown: {
          selected = 4;
          const auto reply = Codec::decode<NotificationShown>(payload, storage);
          identity = reply.request_id;
          delivered = reply.delivered_clients;
          break;
        }
        default:
          std::abort();
        }
        queue.consume(frame_prefix_size + size);
        break;
      }
      case 3:
        queue.clear();
        break;
      case 4:
        accepted = notify();
        break;
      case 5:
        queue.appendConfirmation(NotificationShown{.request_id = operation.value}, [&](auto &reply) { reply.delivered_clients = notify(); });
        break;
      default:
        std::abort();
      }
    } catch (const ResponseQueueFull &) {
      accepted = false;
    }

    auto bytes = std::span{output + written, std::size_t{21}};
    u8::encode(accepted, bytes);
    u8::encode(queue.responseDepth(), bytes);
    u8::encode(queue.responseHighWater(), bytes);
    u8::encode(selected, bytes);
    u8::encode(delivered, bytes);
    u64::encode(queue.dropped(), bytes);
    u64::encode(identity, bytes);
    written += 21;
  }
  return written;
}
