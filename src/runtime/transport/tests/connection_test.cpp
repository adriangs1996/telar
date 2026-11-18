#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <sys/socket.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.platform.net;
import telar.platform.error;
import telar.platform.primitives;
import telar.testing;
import telar.runtime.transport.connection;
import telar.wire.runtime;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  using ClientConnection = Connection<SystemAllocator>;

  // The runtime's end of a client channel, set up as the runtime sets up the sockets it accepts, and
  // the client's end.
  struct Channel {
    Channel() {
      int descriptors[2];

      check(::socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) == 0);
      peer.reset(descriptors[1]);
      setNonblocking(descriptors[0]);
      suppressSocketSignals(descriptors[0]);
      local.reset(descriptors[0]);
    }

    FileDescriptor local;
    FileDescriptor peer;
  };

  // A frame's length prefix is checked before anything waits on it: an empty frame or one past the
  // payload limit is refused at once, and no frame is handed on.
  void testInvalidFrameLength() {
    for (const auto length : {std::uint32_t{0}, static_cast<std::uint32_t>(max_payload_size + 1)}) {
      SystemAllocator memory;
      Channel channel;
      ClientConnection connection{memory, std::move(channel.local)};
      std::array<Byte, frame_prefix_size> prefix;
      std::span<Byte> output = prefix;

      u32::encode(length, output);
      check(::write(channel.peer.get(), prefix.data(), prefix.size()) == static_cast<ssize_t>(prefix.size()));
      check(connection.read());

      ClientConnection::Frames frames{memory};
      bool visited = false;
      bool rejected = false;

      connection.exchange(frames);
      try {
        ClientConnection::dispatch(
            frames,
            [] {
              return true;
            },
            [&](std::span<const Byte>, auto&) {
              visited = true;
            }
        );
      } catch (const EncodingError&) {
        rejected = true;
      }

      check(rejected && !visited);
    }
  }

  // A client gone with a frame still queued for it fails the write, so the runtime drops the client
  // instead of retrying a socket nobody reads.
  void testWriteToClosedPeer() {
    SystemAllocator memory;
    Channel channel;
    ClientConnection connection{memory, std::move(channel.local)};

    connection.send(RequestCompleted{.request_id = 1});
    channel.peer.reset();
    bool failed = false;

    try {
      connection.write();
    } catch (const SystemError&) {
      failed = true;
    }

    check(failed);
  }

  const telar::testing::Case case_invalid_frame_length{"connection.invalid_frame_length", testInvalidFrameLength};
  const telar::testing::Case case_write_to_closed_peer{"connection.write_to_closed_peer", testWriteToClosedPeer};

}
