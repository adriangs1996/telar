#include "check.hpp"
#include "transport/client_handshake.hpp"
#include <sys/socket.h>

using namespace telar;
using namespace telar::runtime;

static auto helloFrame(ClientHello hello = {}) {
  const auto payload = HandshakeCodec::encode(hello);
  std::array<Byte, frame_prefix_size + payload.size()> frame;
  std::span<Byte> output = frame;
  u32::encode(payload.size(), output);
  std::copy(payload.begin(), payload.end(), output.begin());
  return frame;
}

static void testFragmentedHello() {
  int descriptors[2];
  check(::socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) == 0);
  FileDescriptor peer{descriptors[1]};
  setNonblocking(descriptors[0]);
  ClientHandshake pending{FileDescriptor{descriptors[0]}, false};
  const auto frame = helloFrame();
  for (std::size_t index = 0; index < frame.size(); ++index) {
    check(::write(peer.get(), &frame[index], 1) == 1);
    pending.read();
    check(pending.stage() == (index + 1 < frame_prefix_size ? ClientHandshake::Stage::prefix : index + 1 < frame.size() ? ClientHandshake::Stage::hello
                                                                                                                        : ClientHandshake::Stage::reply));
  }

  constexpr Byte pipelined = 0xab;
  check(::write(peer.get(), &pipelined, 1) == 1);
  pending.read();
  pending.write();
  check(pending.stage() == ClientHandshake::Stage::accepted && pending.reservesClient());
  auto channel = pending.takeDescriptor();
  Byte retained = 0;
  check(::read(channel.get(), &retained, 1) == 1 && retained == pipelined);
  std::array<Byte, frame_prefix_size + HandshakeSchema<ServerAccept>::payload_size> response;
  check(::read(peer.get(), response.data(), response.size()) == static_cast<ssize_t>(response.size()));
  check(HandshakeCodec::decode<ServerAccept>(std::span<const Byte>{response}.subspan(frame_prefix_size)).schema == handshake::schema_id);
}

static void testRefusal(bool capacity_refused) {
  int descriptors[2];
  check(::socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) == 0);
  FileDescriptor peer{descriptors[1]};
  setNonblocking(descriptors[0]);
  ClientHandshake pending{FileDescriptor{descriptors[0]}, capacity_refused};
  pending.write();
  check(pending.stage() == ClientHandshake::Stage::prefix && pending.reservesClient() != capacity_refused);
  check(!pending.expired(std::chrono::steady_clock::now()));
  check(pending.expired(std::chrono::steady_clock::now() + std::chrono::seconds{3}));
  ClientHello hello;
  hello.schema.front() ^= 1;
  const auto frame = helloFrame(hello);
  check(::write(peer.get(), frame.data(), frame.size()) == static_cast<ssize_t>(frame.size()));
  pending.read();
  pending.write();
  check(pending.stage() == ClientHandshake::Stage::rejected);
  std::array<Byte, frame_prefix_size + HandshakeSchema<ServerReject>::payload_size> response;
  check(::read(peer.get(), response.data(), response.size()) == static_cast<ssize_t>(response.size()));
  const auto rejection = HandshakeCodec::decode<ServerReject>(std::span<const Byte>{response}.subspan(frame_prefix_size));
  check(rejection.reason == (capacity_refused ? HandshakeRejectReason::client_limit_reached : HandshakeRejectReason::incompatible_schema));
  check(rejection.expected_schema == handshake::schema_id);
}

static void testMalformedHello() {
  for (const bool wrong_length : {false, true}) {
    int descriptors[2];
    check(::socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) == 0);
    FileDescriptor peer{descriptors[1]};
    setNonblocking(descriptors[0]);
    ClientHandshake pending{FileDescriptor{descriptors[0]}, false};
    auto frame = helloFrame();
    frame[wrong_length ? 0 : frame_prefix_size] ^= 1;
    check(::write(peer.get(), frame.data(), frame.size()) == static_cast<ssize_t>(frame.size()));
    bool rejected = false;
    try {
      pending.read();
    } catch (const EncodingError &) {
      rejected = true;
    }
    check(rejected);
  }
}

void testAdmission() {
  testFragmentedHello();
  testRefusal(false);
  testRefusal(true);
  testMalformedHello();
}
