module;
#include "tbc/view.hpp"

#include <cerrno>
#include <cstdint>
#include <limits.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

export module telar.runtime.vocabulary.traffic;

import std;
import telar.sys.posix;

export import telar.plugins;
export import telar.runtime.vocabulary.exchange;
export import telar.runtime.vocabulary.frames;

import telar.platform.error;
import telar.platform.net;
import telar.platform.primitives;
import telar.wire.vocabulary;

// Interface: plugins/effects.cppm
export {
  namespace telar::runtime::plugins {

    struct EffectBatch {
      std::array<NotificationBody, Limits::effects> notifications;
      std::uint8_t count = 0;
    };

    struct EffectReply {
      std::uint64_t event_id = 0;
      EffectBatch batch;
    };

    struct ErrorReply {
      std::uint64_t event_id = 0;
      std::string_view message{};
    };

  }
}

// Interface: plugins/exchange_view.cppm
export {
  namespace telar::runtime::plugins {

    enum class ExchangeProtocol : std::uint8_t {
      http11,
      h2,
      upgraded,
    };

    struct HalfView {
      std::span<const std::uint8_t> head{};
      std::span<const std::uint8_t> body{};
      std::string_view encoding{};
      bool decoded = false;
      bool body_truncated = false;
      std::uint16_t status_code = 0;
      CaptureOutcome outcome = CaptureOutcome::failed;
      std::int64_t finished_at_ms = 0;
      bool head_truncated = false;
    };

    struct ExchangeIdentity {
      std::uint64_t id = 0;
      std::uint64_t generation = 0;
    };

    struct ExchangeView {
      ExchangeIdentity identity;
      ExchangeProtocol protocol = ExchangeProtocol::http11;
      CaptureKey key;
      std::string_view host{};
      std::string_view method{};
      std::string_view target{};
      std::int64_t started_at_ms = 0;
      std::optional<HalfView> request;
      std::optional<HalfView> response;
    };

  }
}

// Interface: plugins/protocol.cppm
export {
  namespace telar::runtime::plugins {

    enum class FrameKind : Byte {
      exchange = 1,
      effects = 2,
      error = 3,
      traffic_setup = 4,
      traffic_event = 5,
      traffic_reply = 6,
      traffic_control_event = 7,
    };

    enum class EffectKind : Byte {
      notification = 3,
    };

    class Protocol {
    public:
      template <Allocator Memory>
      inline static tbc::view<std::span<const Byte>, tbc::lt::a> encodeExchange(tbc::view<std::span<Byte>, tbc::lt::a> output, ExchangeIdentity identity, const CapturedExchange<Memory>& exchange, std::size_t part_limit = SIZE_MAX) {
        FrameWriter writer{output};

        writeExchange(writer, identity, exchange, part_limit);
        return writer.finish();
      }

      template <Allocator Memory>
      inline static std::size_t exchangeBytes(const CapturedExchange<Memory>& exchange) {
        FrameSize size;

        writeExchange(size, {}, exchange);
        return size.finish();
      }

      inline static ExchangeView decodeExchange(std::span<const Byte> input) {
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

      inline static tbc::view<std::span<const Byte>, tbc::lt::a> encodeEffects(tbc::view<std::span<Byte>, tbc::lt::a> output, std::uint64_t event_id, const EffectBatch& batch) {
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

      inline static EffectReply decodeEffects(std::span<const Byte> input) {
        FrameReader reader{input};

        reader.require(FrameKind::effects);
        EffectReply result;

        result.event_id = reader.integer<std::uint64_t>();
        result.batch.count = reader.integer<Byte>();
        if (result.batch.count > Limits::effects) {
          throw EncodingError{"Tap returned too many effects"};
        }

        for (auto& notification : std::span{result.batch.notifications}.first(result.batch.count)) {
          reader.require(EffectKind::notification);
          notification.level = reader.tag(NotificationLevel::failure);
          notification.duration_ms = reader.integer<std::uint32_t>();
          notification.title = reader.text();
          notification.message = reader.text();
        }

        reader.finish();
        return result;
      }

      inline static tbc::view<std::span<const Byte>, tbc::lt::a> encodeError(tbc::view<std::span<Byte>, tbc::lt::a> output, std::uint64_t event_id, std::string_view message) {
        FrameWriter writer{output};

        writer.tag(FrameKind::error);
        writer.integer(event_id);
        writer.text(message.substr(0, Limits::error_bytes));
        return writer.finish();
      }

      inline static ErrorReply decodeError(std::span<const Byte> input) {
        FrameReader reader{input};

        reader.require(FrameKind::error);
        const ErrorReply reply{reader.integer<std::uint64_t>(), reader.text()};

        reader.finish();
        return reply;
      }

      static constexpr std::size_t prefix_bytes = sizeof(std::uint32_t);

    private:
      template <FrameOutput Output, Allocator Memory>
      inline static void writeExchange(Output& writer, ExchangeIdentity identity, const CapturedExchange<Memory>& exchange, std::size_t part_limit = SIZE_MAX) {
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

      inline static ExchangeProtocol exchangeProtocol(CaptureProtocol protocol) {
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

      template <FrameOutput Output, Allocator Memory>
      inline static void writeHalf(Output& writer, const CaptureHalf<Memory>* half, std::size_t part_limit) {
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

      inline static tbc::view<std::optional<HalfView>, tbc::lt::a> readHalf(FrameReader& reader) {
        if (!reader.boolean()) {
          return std::nullopt;
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
    };

  }
}

// Interface: plugins/service_spec.cppm
export {
  namespace telar::runtime::plugins {

    struct ServiceSpec {
      std::uint8_t package_index = 0;
      std::uint64_t plugin_id = 0;
      PackageDigest digest{};
      std::uint64_t generation = 0;
      FixedText<PackageLimits::id_bytes> name;
      FixedText<PATH_MAX> entry;
      Capabilities declared;
      Capabilities granted;
      std::shared_ptr<std::atomic<bool>> permission;

      inline bool allows(Capability capability) const noexcept {
        return authorized() && declared.contains(capability) && granted.contains(capability);
      }

      inline bool authorized() const noexcept {
        return !permission || permission->load(std::memory_order_acquire);
      }

      // The capabilities that give a plugin the traffic bridge.
      static constexpr std::array traffic_capabilities{Capability::traffic_observe, Capability::traffic_intercept, Capability::traffic_control, Capability::traffic_record};

      inline bool traffic() const noexcept {
        return std::ranges::any_of(traffic_capabilities, [&](Capability capability) {
          return allows(capability);
        });
      }

      inline bool stillAuthorized(Capabilities current) const noexcept {
        return current.containsAll(declared.intersection(granted));
      }
    };

  }
}

// Interface: traffic/connection.cppm
export {
  namespace telar::runtime::traffic {

    inline FileDescriptor connect(std::string_view path) {
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

    inline void sendAll(int socket, std::span<const Byte> bytes) {
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
}
