module telar.runtime.vocabulary.traffic;

import telar.sys.socket;
import telar.platform.error;
import telar.platform.net;
import telar.base.ds;

namespace telar::runtime::plugins {

  tbc::view<std::span<const Byte>, tbc::lt::a> Protocol::encodeExchange(tbc::view<std::span<Byte>, tbc::lt::a> output, ExchangeIdentity identity, const CapturedExchange& exchange, std::size_t part_limit) {
    FrameWriter writer{output};

    writeExchange(writer, identity, exchange, part_limit);
    return writer.finish();
  }

  std::size_t Protocol::exchangeBytes(const CapturedExchange& exchange) {
    FrameSize size;

    writeExchange(size, {}, exchange);
    return size.finish();
  }

  ExchangeView Protocol::decodeExchange(std::span<const Byte> input) {
    FrameReader reader{input};

    reader.require(FrameKind::exchange);
    ExchangeView exchange;

    exchange.identity.id = reader.integer<std::uint64_t>();
    exchange.identity.generation = reader.integer<std::uint64_t>();
    exchange.protocol = reader.tag(ExchangeProtocol::upgraded);
    exchange.key.connection = reader.integer<std::uint64_t>();
    exchange.key.stream = reader.integer<std::uint32_t>();
    exchange.host = reader.text();
    exchange.method = reader.text();
    exchange.target = reader.text();
    exchange.started_at_ms = reader.timestamp();
    exchange.request = readHalf(reader);
    exchange.response = readHalf(reader);
    reader.finish();
    return exchange;
  }

  tbc::view<std::span<const Byte>, tbc::lt::a> Protocol::encodeEffects(tbc::view<std::span<Byte>, tbc::lt::a> output, std::uint64_t event_id, const EffectBatch& batch) {
    if (batch.count > Limits::effects) {
      throw EncodingError{"Tap returned too many effects"};
    }

    FrameWriter writer{output};

    writer.tag(FrameKind::effects);
    writer.integer(event_id);
    writer.integer(batch.count);
    for (const auto& notification : std::span{batch.notifications}.first(batch.count)) {
      writer.tag(EffectKind::notification);
      writer.tag(notification.level);
      writer.integer(notification.duration_ms);
      writer.text(notification.title);
      writer.text(notification.message);
    }

    return writer.finish();
  }

  EffectReply Protocol::decodeEffects(std::span<const Byte> input) {
    FrameReader reader{input};

    reader.require(FrameKind::effects);
    EffectReply result;

    result.event_id = reader.integer<std::uint64_t>();
    result.batch.count = reader.integer<Byte>();
    if (result.batch.count > Limits::effects) {
      throw EncodingError{"Tap returned too many effects"};
    }

    for (auto& notification : result.batch.notifications.viewMut().first(result.batch.count)) {
      reader.require(EffectKind::notification);
      notification.level = reader.tag(NotificationLevel::failure);
      notification.duration_ms = reader.integer<std::uint32_t>();
      notification.title = reader.text();
      notification.message = reader.text();
    }

    reader.finish();
    return result;
  }

  tbc::view<std::span<const Byte>, tbc::lt::a> Protocol::encodeError(tbc::view<std::span<Byte>, tbc::lt::a> output, std::uint64_t event_id, std::string_view message) {
    FrameWriter writer{output};

    writer.tag(FrameKind::error);
    writer.integer(event_id);
    writer.text(message.substr(0, Limits::error_bytes));
    return writer.finish();
  }

  ErrorReply Protocol::decodeError(std::span<const Byte> input) {
    FrameReader reader{input};

    reader.require(FrameKind::error);
    const ErrorReply reply{reader.integer<std::uint64_t>(), reader.text()};

    reader.finish();
    return reply;
  }

  template <FrameOutput Output>
  void Protocol::writeExchange(Output& writer, ExchangeIdentity identity, const CapturedExchange& exchange, std::size_t part_limit) {
    const auto* representative = exchange.request ? exchange.request.get() : exchange.response.get();
    if (representative == nullptr) {
      throw EncodingError{"Cannot encode an empty capture"};
    }

    writer.tag(FrameKind::exchange);
    writer.integer(identity.id);
    writer.integer(identity.generation);
    writer.tag(exchangeProtocol(representative->protocol));
    writer.integer(representative->key.connection);
    writer.integer(representative->key.stream);
    writer.text(representative->host());
    writer.text(representative->method());
    writer.text(representative->target());
    writer.timestamp(representative->started_at_ms);
    writeHalf(writer, exchange.request.get(), part_limit);
    writeHalf(writer, exchange.response.get(), part_limit);
  }

  ExchangeProtocol Protocol::exchangeProtocol(CaptureProtocol protocol) {
    switch (protocol) {
    case CaptureProtocol::http1:
      return ExchangeProtocol::http11;
    case CaptureProtocol::http2:
      return ExchangeProtocol::h2;
    case CaptureProtocol::upgraded:
      return ExchangeProtocol::upgraded;
    }

    throw EncodingError{"Unknown captured protocol"};
  }

  template <FrameOutput Output>
  void Protocol::writeHalf(Output& writer, const CaptureHalf* half, std::size_t part_limit) {
    writer.boolean(half != nullptr);
    if (half == nullptr) {
      return;
    }

    writer.bytes(half->head.bytes().first(std::min(half->head.size(), part_limit)));
    writer.bytes(half->body.bytes().first(std::min(half->body.size(), part_limit)));
    writer.text(half->encoding());
    writer.boolean(half->body_decoded);
    writer.boolean(half->head.truncated || half->head.size() > part_limit);
    writer.boolean(half->body.truncated || half->body.size() > part_limit);
    writer.integer(half->status_code);
    writer.tag(half->outcome);
    writer.timestamp(half->finished_at_ms);
  }

  tbc::view<ds::Option<HalfView>, tbc::lt::a> Protocol::readHalf(FrameReader& reader) {
    if (!reader.boolean()) {
      return ds::none;
    }

    HalfView half;

    half.head = reader.bytes();
    half.body = reader.bytes();
    half.encoding = reader.text();
    half.decoded = reader.boolean();
    half.head_truncated = reader.boolean();
    half.body_truncated = reader.boolean();
    half.status_code = reader.integer<std::uint16_t>();
    half.outcome = reader.tag(CaptureOutcome::reset);
    half.finished_at_ms = reader.timestamp();
    return half;
  }

  bool ServiceSpec::allows(Capability capability) const noexcept {
    return authorized() && declared.contains(capability) && granted.contains(capability);
  }

  bool ServiceSpec::authorized() const noexcept {
    return !permission || permission->load(std::memory_order_acquire);
  }

  bool ServiceSpec::traffic() const noexcept {
    return std::ranges::any_of(traffic_capabilities, [&](Capability capability) {
      return allows(capability);
    });
  }

  bool ServiceSpec::stillAuthorized(Capabilities current) const noexcept {
    return current.containsAll(declared.intersection(granted));
  }

}

namespace telar::runtime::traffic {

  FileDescriptor connect(std::string_view path) {
    sockaddr_un address{};
    if (path.empty() || path.front() != '/' || path.size() >= sizeof(address.sun_path) || path.contains('\0')) {
      throw std::invalid_argument{"Invalid traffic endpoint"};
    }

    std::ranges::copy(path, address.sun_path);
    address.sun_family = AF_UNIX;
    struct stat before{};
    if (::lstat(address.sun_path, &before) != 0 || !S_ISSOCK(before.st_mode) || (before.st_mode & 0077) != 0) {
      throw SystemError{"Traffic endpoint must be a private socket", EACCES};
    }

    FileDescriptor socket{::socket(AF_UNIX, SOCK_STREAM, 0)};
    if (!socket) {
      throw SystemError{"Create traffic connection"};
    }

    setCloseOnExec(socket.get());
    suppressSocketSignals(socket.get());
    if (::connect(socket.get(), reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0) {
      throw SystemError{"Connect traffic endpoint"};
    }

    struct stat after{};
    const auto credentials = peerCredentials(socket.get());
    if (!credentials || credentials->user != before.st_uid || (::geteuid() != 0 && credentials->user != ::geteuid()) || ::lstat(address.sun_path, &after) != 0 || before.st_dev != after.st_dev || before.st_ino != after.st_ino) {
      throw SystemError{"Traffic endpoint identity changed", EACCES};
    }

    return socket;
  }

  void sendAll(int socket, std::span<const Byte> bytes) {
    while (!bytes.empty()) {
      const auto count = ::send(socket, bytes.data(), bytes.size(), 0);
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count <= 0) {
        throw SystemError{"Send traffic frame"};
      }

      bytes = bytes.subspan(static_cast<std::size_t>(count));
    }
  }

}
