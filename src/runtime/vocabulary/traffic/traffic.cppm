export module telar.runtime.vocabulary.traffic;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.plugins;
import telar.runtime.vocabulary.exchange;
import telar.runtime.vocabulary.frames;

import telar.platform.primitives;
import telar.wire.vocabulary;
import telar.base.memory.containers;
import telar.base.ds;

// Interface: plugins/effects.cppm
export {
  namespace telar::runtime::plugins {

    struct EffectBatch {
      ds::Array<NotificationBody, Limits::effects> notifications;
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
      ds::Option<HalfView> request;
      ds::Option<HalfView> response;
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
      static tbc::view<std::span<const Byte>, tbc::lt::a> encodeExchange(tbc::view<std::span<Byte>, tbc::lt::a> output, ExchangeIdentity identity, const CapturedExchange& exchange, std::size_t part_limit = std::numeric_limits<std::size_t>::max());

      static std::size_t exchangeBytes(const CapturedExchange& exchange);

      static ExchangeView decodeExchange(std::span<const Byte> input);

      static tbc::view<std::span<const Byte>, tbc::lt::a> encodeEffects(tbc::view<std::span<Byte>, tbc::lt::a> output, std::uint64_t event_id, const EffectBatch& batch);

      static EffectReply decodeEffects(std::span<const Byte> input);

      static tbc::view<std::span<const Byte>, tbc::lt::a> encodeError(tbc::view<std::span<Byte>, tbc::lt::a> output, std::uint64_t event_id, std::string_view message);

      static ErrorReply decodeError(std::span<const Byte> input);

      static constexpr std::size_t prefix_bytes = sizeof(std::uint32_t);

    private:
      template <FrameOutput Output>
      static void writeExchange(Output& writer, ExchangeIdentity identity, const CapturedExchange& exchange, std::size_t part_limit = std::numeric_limits<std::size_t>::max());

      static ExchangeProtocol exchangeProtocol(CaptureProtocol protocol);

      template <FrameOutput Output>
      static void writeHalf(Output& writer, const CaptureHalf* half, std::size_t part_limit);

      static tbc::view<ds::Option<HalfView>, tbc::lt::a> readHalf(FrameReader& reader);
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

      bool allows(Capability capability) const noexcept;

      bool authorized() const noexcept;

      // The capabilities that give a plugin the traffic bridge.
      static constexpr ds::Array traffic_capabilities{Capability::traffic_observe, Capability::traffic_intercept, Capability::traffic_control, Capability::traffic_record};

      bool traffic() const noexcept;

      bool stillAuthorized(Capabilities current) const noexcept;
    };

  }
}

// Interface: traffic/connection.cppm
export {
  namespace telar::runtime::traffic {

    FileDescriptor connect(std::string_view path);

    void sendAll(int socket, std::span<const Byte> bytes);

  }
}
