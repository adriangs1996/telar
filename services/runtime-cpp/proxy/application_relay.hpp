#pragma once

#include "../http1/intercepted_relay.hpp"
#include "../http2/frame_reader.hpp"
#include "../tls/alpn_offer.hpp"
#include "../tls/side.hpp"
#include "connection_observation.hpp"
#include "duplex_relay.hpp"
#include "flow_state.hpp"
#include "http1_capture.hpp"
#include "http1_connection.hpp"
#include "http2_capture.hpp"
#include "http2_connection.hpp"
#include "http2_endpoint_connection.hpp"
#include "stream_prefix.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class ApplicationRelay {
public:
  explicit ApplicationRelay(Memory &memory, ConnectionObservation<Memory> observation, std::string_view hostname, FlowState *flow)
      : memory_(memory),
        observation_(observation),
        hostname_(hostname),
        flow_(flow),
        http1_(nullptr, AllocationDeleter<Http1, Memory>{memory}),
        http2_(nullptr, AllocationDeleter<Http2, Memory>{memory}),
        http2_endpoint_(nullptr, AllocationDeleter<Http2Endpoint, Memory>{memory}) {}

  void select(HttpProtocol protocol, bool unnegotiated) noexcept {
    if (!selected_) {
      if (!unnegotiated) {
        protocol_ = protocol;
      }
      selected_ = true;
    }
  }

  template <PeekableByteStream Child, PeekableByteStream Origin>
  auto advance(Child &child_stream, Origin &origin_stream, TunnelReadiness readiness) noexcept -> bool {
    bool active = false;

    if (!protocol_) {
      const auto read = prefix_.fill(child_stream);
      active = read.state == StreamResult::State::data;
      identify();
      std::array<Byte, Http2Frame::header_bytes> banner{};
      const auto origin = origin_stream.peek(banner);

      if (!protocol_ && prefix_.empty() && (origin.state == StreamResult::State::data || origin.state == StreamResult::State::ended || origin.state == StreamResult::State::failed)) {
        std::optional<Http2Frame> initial;
        Http2FrameReader reader;

        reader.feed(std::span{banner}.first(origin.bytes), [&](const Http2FrameEvent &event) noexcept -> auto {
          if (event.kind == Http2FrameEvent::Kind::begin) {
            initial = event.frame;
          }
        });

        const bool h2_settings = initial && initial->kind == Http2FrameKind::settings && initial->stream == 0 && initial->flags == 0 && initial->length % Http2Frame::settings_entry_bytes == 0;
        protocol_ = h2_settings ? HttpProtocol::http2 : HttpProtocol::other;
      }

      if (!protocol_) {
        if (!protocol_ && (read.state == StreamResult::State::ended || read.state == StreamResult::State::failed)) {
          protocol_ = HttpProtocol::other;
        }

        if (!protocol_) {
          return active;
        }
      }
    }

    PrefixedStream prefixed{child_stream, prefix_};
    FlowStream child{prefixed, flow_ ? &flow_->inbound : nullptr};
    FlowStream origin{origin_stream, flow_ ? &flow_->outbound : nullptr};

    if (active) {
      readiness = TunnelReadiness::available();
    }

    return transfer(child, origin, readiness) || active;
  }

  [[nodiscard]] auto finished() const noexcept -> bool {
    return failed_ || (http1_ && http1_->finished()) || (http2_ && http2_->finished()) || (http2_endpoint_ && http2_endpoint_->finished()) || duplex_.finished();
  }

  [[nodiscard]] auto halfClosed() const noexcept -> bool {
    if (http2_endpoint_) {
      return http2_endpoint_->halfClosed();
    }
    return http2_ ? http2_->halfClosed() : duplex_.halfClosed();
  }

  [[nodiscard]] auto idle() const noexcept -> bool {
    return http1_ && http1_->idle();
  }

  [[nodiscard]] auto inflight() const noexcept -> std::uint32_t {
    if (http2_endpoint_) {
      return http2_endpoint_->inflight();
    }
    return http2_ ? http2_->inflight() : http1_ ? http1_->inflight()
                                                : 0;
  }

  [[nodiscard]] auto buffered() const noexcept -> bool {
    return protocol_ && !prefix_.empty() && readsChild();
  }

  [[nodiscard]] auto readsChild() const noexcept -> bool {
    if (http2_endpoint_) {
      return http2_endpoint_->readsChild();
    }
    return http2_ ? http2_->readsChild() : http1_ && !http1_->upgraded() ? http1_->readsChild()
                                                                         : duplex_.readsChild();
  }

  [[nodiscard]] auto readsOrigin() const noexcept -> bool {
    if (http2_endpoint_) {
      return http2_endpoint_->readsOrigin();
    }
    return http2_ ? http2_->readsOrigin() : http1_ && !http1_->upgraded() ? http1_->readsOrigin()
                                                                          : duplex_.readsOrigin();
  }

  [[nodiscard]] auto deadline() const noexcept -> std::optional<traffic::FlowControl::Time> {
    if (http2_endpoint_) {
      return http2_endpoint_->deadline();
    }
    if (http1_) {
      return http1_->deadline();
    }
    return !protocol_ && sniff_until_ != traffic::FlowControl::Time{} ? std::optional{sniff_until_} : std::nullopt;
  }

  [[nodiscard]] auto interest(TlsSide side) const noexcept -> SocketInterest {
    if (!protocol_ && !prefix_.empty()) {
      return {.readable = side == TlsSide::child};
    }
    if (http2_endpoint_) {
      return side == TlsSide::child ? http2_endpoint_->childInterest() : http2_endpoint_->originInterest();
    }
    if (http1_ && !http1_->upgraded()) {
      return side == TlsSide::child ? http1_->childInterest() : http1_->originInterest();
    }

    if (http2_) {
      return side == TlsSide::child ? http2_->childInterest() : http2_->originInterest();
    }

    return side == TlsSide::child ? duplex_.childInterest() : duplex_.originInterest();
  }

private:
  using Http1 = Http1Connection<Http1Capture<Memory>, Http1InterceptedRelay<Memory>>;
  using Http2 = Http2Connection<Memory, Http2Capture<Memory>>;
  using Http2Endpoint = Http2EndpointConnection<Memory, Http2Capture<Memory>>;

  [[nodiscard]] auto captureStart(CaptureProtocol protocol) const noexcept -> CaptureStart {
    return {
        .key = {
            observation_.identity,
            0,
        },
        .protocol = protocol,
        .host = hostname_,
    };
  }

  void identify() noexcept {
    const auto bytes = prefix_.bytes();
    const std::string_view head{reinterpret_cast<const char *>(bytes.data()), bytes.size()};

    if (head.empty()) {
      return;
    }

    if (sniff_until_ == traffic::FlowControl::Time{}) {
      sniff_until_ = std::chrono::steady_clock::now() + std::chrono::seconds{3};
    }

    constexpr std::string_view http2 = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    if (head.starts_with(http2)) {
      protocol_ = HttpProtocol::http2;
      return;
    }

    const bool h2_prefix = http2.starts_with(head);
    if (!h2_prefix) {
      constexpr std::array methods{"GET ", "POST ", "PUT ", "HEAD ", "DELETE ", "OPTIONS ", "PATCH ", "CONNECT ", "TRACE "};
      const bool possible = std::ranges::any_of(methods, [&](std::string_view method) { return method.starts_with(head) || head.starts_with(method); });

      if (!possible) {
        protocol_ = HttpProtocol::other;
        return;
      }

      const auto end = head.find("\r\n");
      if (end != std::string_view::npos) {
        const auto line = head.substr(0, end);
        protocol_ = line.ends_with(" HTTP/1.1") || line.ends_with(" HTTP/1.0") ? HttpProtocol::http11 : HttpProtocol::other;
        return;
      }

      if (std::ranges::any_of(bytes, [](Byte byte) { return byte == 0 || byte >= 127 || (byte < 32 && byte != '\r' && byte != '\n' && byte != '\t'); })) {
        protocol_ = HttpProtocol::other;
        return;
      }
    }

    if (bytes.size() == StreamPrefix::capacity || std::chrono::steady_clock::now() >= sniff_until_) {
      protocol_ = HttpProtocol::other;
    }
  }

  template <PeekableByteStream Child, PeekableByteStream Origin>
  auto transfer(Child &child, Origin &origin, TunnelReadiness readiness) noexcept -> bool {
    if (*protocol_ == HttpProtocol::http2) {
      if (!http2_ && !http2_endpoint_) {
        try {
          Http2Capture capture{observation_.captures, observation_.counters, captureStart(CaptureProtocol::http2)};
          auto *control = observation_.flows ? observation_.flows->http() : nullptr;
          if (control) {
            const auto event = flow_ ? flow_->context() : traffic::FlowEvent{.id = observation_.identity, .host = hostname_};
            http2_endpoint_ = makeOwned<Http2Endpoint>(memory_, memory_, std::move(capture), control, event);
          } else {
            http2_ = makeOwned<Http2>(memory_, memory_, observation_.counters, std::move(capture));
          }
        } catch (...) {
          failed_ = true;
          return false;
        }
      }

      return http2_endpoint_ ? http2_endpoint_->advance(child, origin, readiness) : http2_->advance(child, origin, readiness);
    }

    if (*protocol_ == HttpProtocol::http11) {
      if (!http1_) {
        try {
          Http1Capture capture{memory_, observation_.captures, captureStart(CaptureProtocol::http1)};
          const auto event = flow_ ? flow_->context() : traffic::FlowEvent{.id = observation_.identity, .host = hostname_};
          const HttpRelayContext context{observation_.flows ? observation_.flows->http() : nullptr, event};
          http1_ = makeOwned<Http1>(memory_, memory_, observation_.counters, std::move(capture), context);
        } catch (...) {
          failed_ = true;
          return false;
        }
      }

      if (!http1_->upgraded()) {
        const bool active = http1_->advance(child, origin, readiness);
        if (!http1_->upgraded()) {
          return active;
        }

        return duplex_.advance(child, origin, TunnelReadiness::available()) || active;
      }
    }

    return duplex_.advance(child, origin, readiness);
  }

  Memory &memory_;
  ConnectionObservation<Memory> observation_;
  std::string_view hostname_;
  FlowState *flow_;
  Owned<Http1, Memory> http1_;
  Owned<Http2, Memory> http2_;
  Owned<Http2Endpoint, Memory> http2_endpoint_;
  DuplexRelay<> duplex_;
  StreamPrefix prefix_;
  std::optional<HttpProtocol> protocol_;
  traffic::FlowControl::Time sniff_until_;
  bool selected_ = false;
  bool failed_ = false;
};
}
