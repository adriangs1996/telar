module telar.client;

import std;
import telar.tbc;
import telar.wire.vocabulary;
import telar.sys.posix;
import telar.sys.socket;
import telar.base.ds;
#ifdef __APPLE__
import telar.sys.apple;
#endif
#ifdef __linux__
import telar.sys.linux_api;
#endif

namespace telar {

  namespace {

    // Whether a socket call failed for its timeout. POSIX lets EWOULDBLOCK differ from EAGAIN,
    // though Linux and macOS spell one error twice.
    bool timedOut(int error) noexcept {
      constexpr bool distinct_would_block = EWOULDBLOCK != EAGAIN;

      return error == EAGAIN || (distinct_would_block && error == EWOULDBLOCK);
    }

  }

  // The byte comes off the wire, so it may hold no reason at all.
  HandshakeRejectReason HandshakeReasonByte::validate(HandshakeRejectReason reason) {
    if (reason == HandshakeRejectReason::incompatible_schema || reason == HandshakeRejectReason::client_limit_reached) {
      return reason;
    }

    throw EncodingError{"Unknown handshake rejection reason"};
  }

  void HandshakeReasonByte::encode(HandshakeRejectReason reason, std::span<Byte>& output) {
    u8::encode(static_cast<Byte>(validate(reason)), output);
  }

  HandshakeRejectReason HandshakeReasonByte::decode(std::span<const Byte>& input) {
    return validate(static_cast<HandshakeRejectReason>(u8::decode(input)));
  }

  template <typename Message>
  ds::Array<Byte, HandshakeSchema<Message>::payload_size> HandshakeCodec::encode(const Message& message) {
    using Sch = HandshakeSchema<Message>;
    ds::Array<Byte, Sch::payload_size> payload{};
    std::span<Byte> output = payload.viewMut();

    FixedBytes<handshake::magic.size()>::encode(handshake::magic, output);
    u8::encode(static_cast<Byte>(Sch::tag), output);
    Sch::encodeBody(message, output);

    return payload;
  }

  template <typename Message>
  Message HandshakeCodec::decode(std::span<const Byte> input) {
    if (decodeHeader(input) != HandshakeSchema<Message>::tag) {
      throw EncodingError{"Unexpected handshake message"};
    }

    return decodeBody<Message>(input);
  }

  HandshakeResponse HandshakeCodec::decodeResponse(std::span<const Byte> input) {
    switch (decodeHeader(input)) {
    case HandshakeTag::server_accept:
      return decodeBody<ServerAccept>(input);
    case HandshakeTag::server_reject:
      return decodeBody<ServerReject>(input);
    case HandshakeTag::client_hello:
      break;
    }

    throw EncodingError{"Unexpected handshake response"};
  }

  HandshakeTag HandshakeCodec::decodeHeader(std::span<const Byte>& input) {
    if (input.size() < header_size) {
      throw EncodingError{"Invalid handshake response length"};
    }

    if (FixedBytes<handshake::magic.size()>::decode(input) != handshake::magic) {
      throw EncodingError{"Invalid handshake magic"};
    }

    // The byte comes off the wire, so it may name no message at all.
    const auto tag = static_cast<HandshakeTag>(u8::decode(input));
    if (tag == HandshakeTag::client_hello || tag == HandshakeTag::server_accept || tag == HandshakeTag::server_reject) {
      return tag;
    }

    throw EncodingError{"Unknown handshake message tag"};
  }

  template <typename Message>
  Message HandshakeCodec::decodeBody(std::span<const Byte> input) {
    using Sch = HandshakeSchema<Message>;

    if (input.size() != Sch::payload_size - header_size) {
      throw EncodingError{"Invalid handshake response length"};
    }

    Message message{};

    Sch::decodeBody(input, message);
    return message;
  }

  // The three handshake messages are every HandshakeSchema there is.
  template ds::Array<Byte, HandshakeSchema<ClientHello>::payload_size> HandshakeCodec::encode(const ClientHello&);
  template ds::Array<Byte, HandshakeSchema<ServerAccept>::payload_size> HandshakeCodec::encode(const ServerAccept&);
  template ds::Array<Byte, HandshakeSchema<ServerReject>::payload_size> HandshakeCodec::encode(const ServerReject&);
  template ClientHello HandshakeCodec::decode(std::span<const Byte>);
  template ServerAccept HandshakeCodec::decode(std::span<const Byte>);
  template ServerReject HandshakeCodec::decode(std::span<const Byte>);

#ifdef TELAR_DEBUG
  template <typename Message>
  void HandshakeCodec::pretty_print(const Message& message, std::FILE* output) {
    const auto payload = encode(message);

    debug::printFrame<HandshakeSchema<Message>>(payload, output);
  }

  template <Direction Side, HandshakeTag Tag, typename... Fields>
  template <typename Message>
  void HandshakeLayout<Side, Tag, Fields...>::pretty_print(const Message& message, std::FILE* output) {
    HandshakeCodec::pretty_print(message, output);
  }

  template void HandshakeCodec::pretty_print(const ClientHello&, std::FILE*);
  template void HandshakeCodec::pretty_print(const ServerAccept&, std::FILE*);
  template void HandshakeCodec::pretty_print(const ServerReject&, std::FILE*);
  // A message's schema derives from the HandshakeLayout that declares its pretty_print, which its
  // injected class name names.
  template void HandshakeSchema<ClientHello>::HandshakeLayout::pretty_print(const ClientHello&, std::FILE*);
  template void HandshakeSchema<ServerAccept>::HandshakeLayout::pretty_print(const ServerAccept&, std::FILE*);
  template void HandshakeSchema<ServerReject>::HandshakeLayout::pretty_print(const ServerReject&, std::FILE*);
#endif

  SocketError::SocketError(const char* message)
      : message_{message} {}

  const char* SocketError::what() const noexcept {
    return message_;
  }

  Client::Client(Client&& other) noexcept
      : address_(other.address_),
        fd_(std::exchange(other.fd_, -1)) {}

  Client& Client::operator=(Client&& other) noexcept {
    if (this != &other) {
      deinit();
      address_ = other.address_;
      fd_ = std::exchange(other.fd_, -1);
    }

    return *this;
  }

  Client::~Client() {
    deinit();
  }

  Client Client::init(const char* socket_path) {
    Client client{};

    client.address_.sun_family = AF_UNIX;

    const std::string_view path{socket_path};
    if (path.size() >= sizeof(client.address_.sun_path)) {
      throw SocketError{"Socket path too long"};
    }

    *std::ranges::copy(path, std::span{client.address_.sun_path}.begin()).out = '\0';

#ifdef __linux__
    client.fd_ = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
#else
    // Darwin has no SOCK_CLOEXEC: a fork between these two calls can still inherit it.
    client.fd_ = socket(AF_UNIX, SOCK_STREAM, 0);
    if (client.fd_ >= 0 && fcntl(client.fd_, F_SETFD, FD_CLOEXEC) < 0) { // NOLINT(cppcoreguidelines-pro-type-vararg): fcntl's C signature is variadic
      client.deinit();
      throw SocketError{"Error configuring socket"};
    }

#endif
    if (client.fd_ < 0) {
      throw SocketError{"Error opening socket"};
    }

    if (setsockopt(client.fd_, SOL_SOCKET, SO_SNDTIMEO, &io_timeout, sizeof(io_timeout)) < 0) {
      client.deinit();
      throw SocketError{"Error configuring runtime I/O timeout"};
    }

#ifdef __APPLE__
    const int enabled = 1;
    if (setsockopt(client.fd_, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) < 0) {
      client.deinit();
      throw SocketError{"Error configuring socket"};
    }
#endif

    auto* address_ptr = reinterpret_cast<sockaddr*>(&client.address_); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the socket API passes every address family as a sockaddr

    while (connect(client.fd_, address_ptr, sizeof(client.address_)) < 0) {
      if (sys::lastError() == EINTR) {
        continue;
      }

      client.deinit();
      throw SocketError{"Error connecting"};
    }

    return client;
  }

  void Client::handshake() {
    constexpr std::time_t handshake_seconds = 30;
    timeval timeout{
        .tv_sec = handshake_seconds,
        .tv_usec = 0,
    };

    if (setsockopt(fd_, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) {
      throw SocketError{"Error enabling runtime receive timeout for handshake"};
    }

    try {
      const ClientHello request{};

      sendFrame(HandshakeCodec::encode(request));

      ds::Array<Byte, HandshakeCodec::max_message_size> buffer{};
      const auto response = HandshakeCodec::decodeResponse(receiveFrame(buffer.viewMut()));

      if (const auto* accepted = std::get_if<ServerAccept>(&response)) {
        if (accepted->schema != request.schema) {
          throw SocketError{"Runtime accepted an unexpected wire schema"};
        }

        timeout.tv_sec = 0;
        if (setsockopt(fd_, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) {
          throw SocketError{"Error disabling runtime receive timeout"};
        }

        return;
      }

      switch (std::get<ServerReject>(response).reason) {
      case HandshakeRejectReason::incompatible_schema:
        throw SocketError{"Runtime rejected the wire schema"};
      case HandshakeRejectReason::client_limit_reached:
        throw SocketError{"Runtime client limit reached"};
      }
    } catch (...) {
      deinit();
      throw;
    }
  }

  void Client::deinit() {
    if (fd_ >= 0) {
      close(fd_);
      fd_ = -1;
    }
  }

  tbc::val_a<std::span<const Byte>> Client::receiveFrame(tbc::val_a<std::span<Byte>> buffer) {
    ds::Array<Byte, frame_prefix_size> prefix{};

    readAll(prefix.viewMut());

    std::span<const Byte> input = prefix;
    const auto length = u32::decode(input);
    if (length == 0 || length > max_payload_size || length > buffer.size()) {
      throw SocketError{"Invalid runtime frame length"};
    }

    readAll(buffer.first(length));
    return buffer.first(length);
  }

  int Client::descriptor() const noexcept {
    return fd_;
  }

  void Client::interrupt() const noexcept {
    if (fd_ >= 0) {
      ::shutdown(fd_, SHUT_RDWR);
    }
  }

  void Client::writeAll(std::span<const std::uint8_t> bytes) const {
    while (!bytes.empty()) {
#ifdef __linux__
      const auto count = ::send(fd_, bytes.data(), bytes.size(), MSG_NOSIGNAL);
#else
      // SO_NOSIGPIPE already keeps a closed peer from raising SIGPIPE.
      const auto count = ::send(fd_, bytes.data(), bytes.size(), 0);
#endif
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count <= 0) {
        if (count < 0 && timedOut(sys::lastError())) {
          throw SocketError{"Runtime send timed out"};
        }

        throw SocketError{"Error sending runtime message"};
      }

      bytes = bytes.subspan(static_cast<std::size_t>(count));
    }
  }

  void Client::readAll(std::span<std::uint8_t> bytes) const {
    while (!bytes.empty()) {
      const auto count = recv(fd_, bytes.data(), bytes.size(), 0);
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count < 0) {
        if (timedOut(sys::lastError())) {
          throw SocketError{"Runtime receive timed out"};
        }

        throw SocketError{"Error receiving runtime message"};
      }

      if (count == 0) {
        throw SocketError{"Runtime closed the connection"};
      }

      bytes = bytes.subspan(static_cast<std::size_t>(count));
    }
  }

}
