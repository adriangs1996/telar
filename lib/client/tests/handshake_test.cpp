#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstring>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.client;
import telar.platform.fs;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // A length prefix and then `payload`, as the runtime frames what it sends.
  std::vector<Byte> frame(std::uint32_t length, std::span<const Byte> payload) {
    std::vector<Byte> bytes;

    for (unsigned shift = 0; shift < 32; shift += 8) {
      bytes.push_back(static_cast<Byte>(length >> shift));
    }

    bytes.insert(bytes.end(), payload.begin(), payload.end());
    return bytes;
  }

  std::vector<Byte> frame(std::span<const Byte> payload) {
    return frame(static_cast<std::uint32_t>(payload.size()), payload);
  }

  bool readExactly(int descriptor, std::span<Byte> bytes) {
    while (!bytes.empty()) {
      const auto count = ::read(descriptor, bytes.data(), bytes.size());
      if (count <= 0) {
        return false;
      }

      bytes = bytes.subspan(static_cast<std::size_t>(count));
    }

    return true;
  }

  // A runtime on a Unix socket that answers one connection: it reads the client's hello,
  // writes `replies` one after the other and holds the connection until the client closes it.
  class FakeRuntime {
  public:
    explicit FakeRuntime(std::vector<std::vector<Byte>> replies)
        : directory_("/tmp/telar-handshake-XXXXXX"),
          path_(std::string{directory_.path()} + "/runtime.sock"),
          listener_(::socket(AF_UNIX, SOCK_STREAM, 0)) {
      sockaddr_un address{};

      address.sun_family = AF_UNIX;
      std::strcpy(address.sun_path, path_.c_str());
      check(listener_ >= 0 && ::bind(listener_, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0 && ::listen(listener_, 1) == 0);
      thread_ = std::thread{[this, replies = std::move(replies)] {
        serve(replies);
      }};
    }

    ~FakeRuntime() {
      thread_.join();
      ::close(listener_);
    }

    FakeRuntime(const FakeRuntime&) = delete;
    FakeRuntime& operator=(const FakeRuntime&) = delete;

    const char* path() const noexcept {
      return path_.c_str();
    }

  private:
    void serve(const std::vector<std::vector<Byte>>& replies) const {
      const int connection = ::accept(listener_, nullptr, nullptr);
      ds::Array<Byte, frame_prefix_size + HandshakeCodec::max_message_size> hello{};
      ds::Array<Byte, 256> drained{};

      if (connection < 0) {
        return;
      }

      static_cast<void>(readExactly(connection, hello.viewMut().first(frame_prefix_size + HandshakeCodec::encode(ClientHello{}).size())));
      for (const auto& reply : replies) {
        static_cast<void>(::write(connection, reply.data(), reply.size()));
      }

      while (::read(connection, drained.dataMut(), drained.size()) > 0) {
      }

      ::close(connection);
    }

    TemporaryDirectory directory_;
    std::string path_;
    int listener_;
    std::thread thread_;
  };

  // Hands `response` to a fresh client's handshake and tells whether the client refused it
  // and closed its socket.
  bool handshakeRefused(std::vector<Byte> response) {
    const FakeRuntime runtime{{std::move(response)}};
    auto client = Client::init(runtime.path());
    bool refused = false;

    try {
      client.handshake();
    } catch (const std::exception&) {
      refused = true;
    }

    return refused && client.descriptor() == -1;
  }

  // The CLI connects only to a runtime that accepts its exact wire schema: a rejection, another
  // schema or a malformed answer ends the handshake with the connection closed.
  void testHandshakeRejections() {
    const auto reject = [](HandshakeRejectReason reason) {
      return frame(HandshakeCodec::encode(ServerReject{.reason = reason, .expected_schema = handshake::schema_id}));
    };

    const auto accepted = HandshakeCodec::encode(ServerAccept{.schema = handshake::schema_id});
    SchemaId other = handshake::schema_id;

    other.atMut(other.size() - 1) = static_cast<Byte>(other.back() + 1);
    auto bad_magic = accepted;
    auto unknown_tag = accepted;

    bad_magic.atMut(0) = static_cast<Byte>(bad_magic[0] ^ 0xff);
    unknown_tag.atMut(handshake::magic.size()) = 0x7f;

    check(handshakeRefused(reject(HandshakeRejectReason::incompatible_schema)));
    check(handshakeRefused(reject(HandshakeRejectReason::client_limit_reached)));
    check(handshakeRefused(frame(HandshakeCodec::encode(ServerAccept{.schema = other}))));
    check(handshakeRefused(frame(bad_magic)));
    check(handshakeRefused(frame(unknown_tag)));
    check(handshakeRefused(frame(HandshakeCodec::encode(ClientHello{}))));
    check(handshakeRefused(frame(std::span{accepted}.first(accepted.size() - 1))));
    check(!handshakeRefused(frame(accepted)));
  }

  // A frame's length prefix is checked before its body is read: zero, past the protocol's
  // maximum or past the caller's buffer is refused.
  void testFrameLengthLimits() {
    const auto accepted = frame(HandshakeCodec::encode(ServerAccept{.schema = handshake::schema_id}));
    const std::vector<Byte> body(64, 0x41);

    for (const std::uint32_t length : {std::uint32_t{0}, static_cast<std::uint32_t>(max_payload_size + 1), static_cast<std::uint32_t>(body.size())}) {
      const FakeRuntime runtime{{accepted, frame(length, body)}};
      auto client = Client::init(runtime.path());
      // Exactly the buffer's size on the heap, so a read past it is an overflow the sanitize
      // preset reports.
      const auto storage = std::make_unique<Byte[]>(body.size() / 2);
      bool refused = false;

      client.handshake();
      try {
        static_cast<void>(client.receiveFrame({storage.get(), body.size() / 2}));
      } catch (const SocketError&) {
        refused = true;
      }

      check(refused);
    }
  }

  const telar::testing::Case case_handshake_rejections{"client.handshake_rejections", testHandshakeRejections};
  const telar::testing::Case case_frame_length_limits{"client.frame_length_limits", testFrameLengthLimits};

}
