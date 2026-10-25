#include "plugins/service.hpp"

using namespace telar;
using namespace telar::runtime;
namespace tap = telar::runtime::plugins;

template <Allocator Memory>
auto copyHalf(Memory &memory, CaptureQuota &quota, const tap::ExchangeView &exchange, const tap::HalfView &view, CaptureSide side) {
  const ProxyCaptureLimits limits{.enabled = true};
  auto half = makeOwned<CaptureHalf<Memory>>(memory, memory, quota, limits, CaptureStart{.key = exchange.key, .side = side, .protocol = static_cast<CaptureProtocol>(exchange.protocol), .host = exchange.host, .started_at_ms = exchange.started_at_ms});
  half->setMethod(exchange.method);
  half->setTarget(exchange.target);
  half->setEncoding(view.encoding);
  half->append(half->headPart(), view.head);
  half->append(half->bodyPart(), view.body);
  half->body.truncated = view.body_truncated;
  half->body_decoded = view.decoded;
  half->status_code = view.status_code;
  half->finish(view.outcome, view.finished_at_ms);
  return half;
}

int main(int argc, char **argv) {
  try {
    if (argc != 3 && argc != 4) {
      throw std::invalid_argument{"Expected ENTRY WORKER_EXECUTABLE [TRACE_PREFIX]"};
    }
    SystemAllocator system;
    BudgetAllocator budget{system, 512 * 1024 * 1024};
    SynchronizedAllocator memory{budget};
#if TELAR_DEBUG
    trace::Session tracing{memory, argc == 4 ? argv[3] : nullptr};
#endif
    CaptureQuota quota{tap::Limits::held_bytes};
    tap::ServiceSpec specification;
    specification.entry.assign(argv[1]);
    specification.plugin_id = 1;
    specification.generation = 8;
    specification.declared.insert(tap::Capability::proxy_tap);
    specification.declared.insert(tap::Capability::notifications);
    specification.granted = specification.declared;
    const std::array specifications{specification};
    tap::Service service{memory, std::span<const tap::ServiceSpec>{specifications}, argv[2], argc == 4 ? argv[3] : ""};
    tap::PipeStream stream{STDIN_FILENO, STDOUT_FILENO};
    tap::FrameChannel channel{stream};
    std::array<Byte, tap::Limits::effect_bytes> output;
    std::uint64_t event_id = 0;
    while (auto frame = channel.receive(memory, tap::Limits::frame_bytes)) {
      const auto decoded = tap::Protocol::decodeExchange(frame->bytes());
      CapturedExchange exchange{memory};
      if (decoded.request) {
        exchange.request = copyHalf(memory, quota, decoded, *decoded.request, CaptureSide::request);
      }
      if (decoded.response) {
        exchange.response = copyHalf(memory, quota, decoded, *decoded.response, CaptureSide::response);
      }
      service.submit(exchange);
      ++event_id;
      pollfd ready{service.descriptor(), POLLIN, 0};
      int count;
      do {
        count = ::poll(&ready, 1, 5000);
      } while (count < 0 && errno == EINTR);
      if (count <= 0) {
        throw SystemError{"Wait for plugin service result", count == 0 ? ETIMEDOUT : errno};
      }
      service.collect([&](const tap::EffectBatch &batch) { channel.send(tap::Protocol::encodeEffects(output, event_id, batch)); });
    }
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "plugin-service-probe: %s\n", error.what());
    return 1;
  }
}
