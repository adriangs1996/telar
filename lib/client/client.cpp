module telar.client;

import std;
import telar.tbc;
import telar.wire.vocabulary;
import telar.sys.posix;
import telar.sys.socket;
#if defined(__APPLE__)
import telar.sys.apple;
#endif
#if defined(__linux__)
import telar.sys.linux;
#endif

namespace telar {

  HandshakeRejectReason HandshakeReasonByte::validate(HandshakeRejectReason reason) {
    switch (reason) {
    case HandshakeRejectReason::incompatible_schema:
    case HandshakeRejectReason::client_limit_reached:
      return reason;
    default:
      throw EncodingError{"Unknown handshake rejection reason"};
    }
  }

  void HandshakeReasonByte::encode(HandshakeRejectReason reason, std::span<Byte>& output) {
    u8::encode(static_cast<Byte>(validate(reason)), output);
  }

  HandshakeRejectReason HandshakeReasonByte::decode(std::span<const Byte>& input) {
    return validate(static_cast<HandshakeRejectReason>(u8::decode(input)));
  }

  template <typename Message>
  std::array<Byte, HandshakeSchema<Message>::payload_size> HandshakeCodec::encode(const Message& message) {
    using Sch = HandshakeSchema<Message>;
    std::array<Byte, Sch::payload_size> payload{};
    std::span<Byte> output = payload;

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
    default:
      throw EncodingError{"Unexpected handshake response"};
    }
  }

  HandshakeTag HandshakeCodec::decodeHeader(std::span<const Byte>& input) {
    if (input.size() < header_size) {
      throw EncodingError{"Invalid handshake response length"};
    }

    if (FixedBytes<handshake::magic.size()>::decode(input) != handshake::magic) {
      throw EncodingError{"Invalid handshake magic"};
    }

    const auto tag = static_cast<HandshakeTag>(u8::decode(input));

    switch (tag) {
    case HandshakeTag::client_hello:
    case HandshakeTag::server_accept:
    case HandshakeTag::server_reject:
      return tag;
    default:
      throw EncodingError{"Unknown handshake message tag"};
    }
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
  template std::array<Byte, HandshakeSchema<ClientHello>::payload_size> HandshakeCodec::encode(const ClientHello&);
  template std::array<Byte, HandshakeSchema<ServerAccept>::payload_size> HandshakeCodec::encode(const ServerAccept&);
  template std::array<Byte, HandshakeSchema<ServerReject>::payload_size> HandshakeCodec::encode(const ServerReject&);
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

  namespace {

    // Names the HandshakeLayout a message's schema derives from, which declares its pretty_print.
    template <Direction Side, HandshakeTag Tag, typename... Fields>
    HandshakeLayout<Side, Tag, Fields...> layoutOf(const HandshakeLayout<Side, Tag, Fields...>&);

  }

  template <typename Message>
  using HandshakeLayoutOf = decltype(layoutOf(std::declval<HandshakeSchema<Message>>()));

  template void HandshakeCodec::pretty_print(const ClientHello&, std::FILE*);
  template void HandshakeCodec::pretty_print(const ServerAccept&, std::FILE*);
  template void HandshakeCodec::pretty_print(const ServerReject&, std::FILE*);
  template void HandshakeLayoutOf<ClientHello>::pretty_print(const ClientHello&, std::FILE*);
  template void HandshakeLayoutOf<ServerAccept>::pretty_print(const ServerAccept&, std::FILE*);
  template void HandshakeLayoutOf<ServerReject>::pretty_print(const ServerReject&, std::FILE*);
#endif

  SocketError::SocketError(const char* message)
      : message{message} {}

  const char* SocketError::what() const noexcept {
    return message;
  }

  Client::Client(Client&& other) noexcept
      : _address(other._address),
        _fd(std::exchange(other._fd, -1)) {}

  Client& Client::operator=(Client&& other) noexcept {
    if (this != &other) {
      deinit();
      _address = other._address;
      _fd = std::exchange(other._fd, -1);
    }

    return *this;
  }

  Client::~Client() {
    deinit();
  }

  Client Client::init(const char* socket_path) {
    Client client{};

    client._address.sun_family = AF_UNIX;

    const auto path_length = std::strlen(socket_path);
    if (path_length >= sizeof(client._address.sun_path)) {
      throw SocketError{"Socket path too long"};
    }

    std::memcpy(client._address.sun_path, socket_path, path_length + 1);

#if defined(__linux__)
    client._fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
#else
    // Darwin has no SOCK_CLOEXEC: a fork between these two calls can still inherit it.
    client._fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (client._fd >= 0 && fcntl(client._fd, F_SETFD, FD_CLOEXEC) < 0) {
      client.deinit();
      throw SocketError{"Error configuring socket"};
    }

#endif
    if (client._fd < 0) {
      throw SocketError{"Error opening socket"};
    }

    if (setsockopt(client._fd, SOL_SOCKET, SO_SNDTIMEO, &io_timeout, sizeof(io_timeout)) < 0) {
      client.deinit();
      throw SocketError{"Error configuring runtime I/O timeout"};
    }

#if defined(__APPLE__)
    const int enabled = 1;
    if (setsockopt(client._fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) < 0) {
      client.deinit();
      throw SocketError{"Error configuring socket"};
    }
#endif

    auto address_ptr = reinterpret_cast<sockaddr*>(&client._address);

    while (connect(client._fd, address_ptr, sizeof(client._address)) < 0) {
      if (sys::lastError() == EINTR) {
        continue;
      }

      client.deinit();
      throw SocketError{"Error connecting"};
    }

    return client;
  }

  void Client::handshake() {
    timeval timeout{
        .tv_sec = 30,
        .tv_usec = 0,
    };

    if (setsockopt(_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) {
      throw SocketError{"Error enabling runtime receive timeout for handshake"};
    }

    try {
      const ClientHello request{};

      sendFrame(HandshakeCodec::encode(request));

      std::array<Byte, HandshakeCodec::max_message_size> buffer{};
      const auto response = HandshakeCodec::decodeResponse(receiveFrame(buffer));

      if (const auto* accepted = std::get_if<ServerAccept>(&response)) {
        if (accepted->schema != request.schema) {
          throw SocketError{"Runtime accepted an unexpected wire schema"};
        }

        timeout.tv_sec = 0;
        if (setsockopt(_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) {
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
    if (_fd >= 0) {
      close(_fd);
      _fd = -1;
    }
  }

  tbc::view<std::span<const Byte>, tbc::lt::a> Client::receiveFrame(tbc::view<std::span<Byte>, tbc::lt::a> buffer) {
    std::array<Byte, frame_prefix_size> prefix{};

    readAll(prefix.data(), prefix.size());

    std::span<const Byte> input = prefix;
    const auto length = u32::decode(input);
    if (length == 0 || length > max_payload_size || length > buffer.size()) {
      throw SocketError{"Invalid runtime frame length"};
    }

    readAll(buffer.data(), length);
    return buffer.first(length);
  }

  int Client::descriptor() const noexcept {
    return _fd;
  }

  void Client::interrupt() const noexcept {
    if (_fd >= 0) {
      ::shutdown(_fd, SHUT_RDWR);
    }
  }

  void Client::writeAll(const std::uint8_t* bytes, std::size_t size) {
    while (size != 0) {
#if defined(__linux__)
      const auto count = ::send(_fd, bytes, size, MSG_NOSIGNAL);
#else
      // SO_NOSIGPIPE already keeps a closed peer from raising SIGPIPE.
      const auto count = ::send(_fd, bytes, size, 0);
#endif
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count <= 0) {
        if (count < 0 && (sys::lastError() == EAGAIN || sys::lastError() == EWOULDBLOCK)) {
          throw SocketError{"Runtime send timed out"};
        }

        throw SocketError{"Error sending runtime message"};
      }

      bytes += count;
      size -= static_cast<std::size_t>(count);
    }
  }

  void Client::readAll(std::uint8_t* bytes, std::size_t size) {
    while (size != 0) {
      const auto count = recv(_fd, bytes, size, 0);
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count < 0) {
        if (sys::lastError() == EAGAIN || sys::lastError() == EWOULDBLOCK) {
          throw SocketError{"Runtime receive timed out"};
        }

        throw SocketError{"Error receiving runtime message"};
      }

      if (count == 0) {
        throw SocketError{"Runtime closed the connection"};
      }

      bytes += count;
      size -= static_cast<std::size_t>(count);
    }
  }

}
