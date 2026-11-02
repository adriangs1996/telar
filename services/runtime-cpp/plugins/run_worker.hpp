#pragma once

#include "frame_channel.hpp"
#include "host.hpp"
#include "pipe_stream.hpp"

namespace telar::runtime::plugins {

template <Allocator Memory>
void runWorker(Memory &memory, const char *entry_path, bool traffic = false) {
  PipeStream stream{STDIN_FILENO, STDOUT_FILENO};
  FrameChannel channel{stream};
  std::optional<ServiceSpec> specification;
  if (traffic) {
    const auto frame = channel.receive(memory, 4096);
    if (!frame) { return; }
    specification = TrafficProtocol::setup(frame->bytes());
  }
  Host host{memory, entry_path, specification ? &*specification : nullptr};
  SensitiveAllocation output{memory, traffic ? TrafficLimits::reply_bytes : Limits::effect_bytes};
  if (traffic) { channel.send(host.trafficSetup(output.bytes())); }
  while (auto frame = channel.receive(memory, Limits::frame_bytes)) {
    const auto bytes = frame->bytes();
    std::span<const Byte> encoded;
    if (traffic && (bytes.front() == static_cast<Byte>(FrameKind::traffic_event) || bytes.front() == static_cast<Byte>(FrameKind::traffic_control_event))) { encoded = host.invokeTraffic(TrafficProtocol::event(bytes), output.bytes()); }
    else { encoded = host.invoke(Protocol::decodeExchange(bytes), output.bytes().first(Limits::effect_bytes)); }
    channel.send(encoded);
    eraseSensitive(output.bytes().data(), encoded.size());
  }
}

}
