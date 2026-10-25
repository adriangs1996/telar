#pragma once

#include "frame_channel.hpp"
#include "host.hpp"
#include "pipe_stream.hpp"

namespace telar::runtime::plugins {

template <Allocator Memory>
void runWorker(Memory &memory, const char *entry_path) {
  Host host{memory, entry_path};
  PipeStream stream{STDIN_FILENO, STDOUT_FILENO};
  FrameChannel channel{stream};
  while (auto frame = channel.receive(memory, Limits::frame_bytes)) {
    const auto exchange = Protocol::decodeExchange(frame->bytes());
    SensitiveAllocation output{memory, Limits::effect_bytes};
    channel.send(host.invoke(exchange, output.bytes()));
  }
}

}
