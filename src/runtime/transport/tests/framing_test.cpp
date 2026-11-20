#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <sys/socket.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.platform.primitives;
import telar.testing;
import telar.runtime.transport.connection;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.client;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // Dispatches a connection's frames as the runtime does: lent out of it while the visitor runs.
  template <typename Link, typename Visitor>
  bool dispatchFrames(SystemAllocator& memory, Link& connection, Visitor&& visit) {
    typename Link::Frames frames{memory};

    connection.exchange(frames);
    const bool remaining = Link::dispatch(frames, [&] {
      return !connection.flags().read_paused;
    },
        visit);

    connection.exchange(frames);
    return remaining;
  }

  void testFraming(SystemAllocator& memory) {
    int sockets[2];

    check(::socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    FileDescriptor peer{sockets[1]};

    setNonblocking(sockets[0]);
    Connection connection{memory, FileDescriptor{sockets[0]}};
    const auto hello = HandshakeCodec::encode(ClientHello{});
    ds::Array<Byte, frame_prefix_size> prefix{};
    std::span<Byte> writer = prefix.viewMut();

    u32::encode(hello.size(), writer);

    check(::write(peer.get(), prefix.data(), 2) == 2);
    check(connection.read());
    bool received = false;
    const auto dispatch = [&](std::span<const Byte> payload, DecodeStorage&) {
      received = true;
      check(HandshakeCodec::decode<ClientHello>(payload).schema == handshake::schema_id);
      connection.send(RequestCompleted{.request_id = 17});
    };

    check(!dispatchFrames(memory, connection, dispatch));
    check(!received);
    check(::write(peer.get(), prefix.data() + 2, 2) == 2);
    check(::write(peer.get(), hello.data(), hello.size()) == static_cast<ssize_t>(hello.size()));
    check(connection.read());
    dispatchFrames(memory, connection, dispatch);
    check(received);
    connection.write();
    ds::Array<Byte, 64> response{};
    const auto count = ::read(peer.get(), response.dataMut(), response.size());

    check(count == static_cast<ssize_t>(frame_prefix_size + MessageSchema<RequestCompleted>::payload_size));
    ds::Array<Byte, 64> scratch;
    DecodeStorage storage{scratch.viewMut()};
    const auto accepted = Codec::decode<RequestCompleted>(std::span<const Byte>{response}.subspan(frame_prefix_size, MessageSchema<RequestCompleted>::payload_size), storage);

    check(accepted.request_id == 17);

    for (unsigned index = 0; index < 2; ++index) {
      check(::write(peer.get(), prefix.data(), prefix.size()) == static_cast<ssize_t>(prefix.size()));
      check(::write(peer.get(), hello.data(), hello.size()) == static_cast<ssize_t>(hello.size()));
    }

    check(connection.read());
    unsigned requests = 0;
    const auto pause_after_request = [&](std::span<const Byte> payload, DecodeStorage&) {
      check(std::ranges::equal(payload, hello));
      ++requests;
      connection.flagsMut().read_paused = true;
    };

    check(dispatchFrames(memory, connection, pause_after_request));
    check(requests == 1);
    check(dispatchFrames(memory, connection, pause_after_request));
    check(requests == 1);
    connection.flagsMut().read_paused = false;
    check(!dispatchFrames(memory, connection, pause_after_request));
    check(requests == 2);
  }

  void testFramingCase() {
    SystemAllocator memory;

    testFraming(memory);
  }

  const telar::testing::Case case_framing{"connection.framing", testFramingCase};

}
