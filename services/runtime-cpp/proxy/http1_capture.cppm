module;

#include <cstdint>
#include <string_view>
#include <concepts>
#include <span>


#include <chrono>
#include "telar_base/memory/allocator.hpp"
#include <cstring>
#include <cstddef>
#include <array>
#include <brotli/decode.h>
#include <optional>
#include <utility>
#include <initializer_list>
#include <zlib.h>
#include "telar_platform/trace.hpp"
#include <zstd.h>
#include <stdexcept>
#include <algorithm>
#include <atomic>
#include <cassert>
#include <condition_variable>
#include <mutex>
#include <type_traits>


#include <limits>


#include "telar_platform/file_descriptor.hpp"
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#include <cerrno>
#endif
#if (defined(__linux__))
#include <exception>
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#include <csignal>
#endif
#if (defined(__linux__))
#include <fcntl.h>
#endif
#if (defined(__linux__))
#include <sched.h>
#endif
#if (defined(__linux__))
#include <sys/epoll.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__))
#include <unistd.h>
#endif

export module telar.runtime.proxy.http1_capture;

export import telar.runtime.exchange_capture.exchange;


export import telar.runtime.exchange_capture.pipeline;
export import telar.runtime.exchange_capture.producer;


export import telar.runtime.http1.intercepted_relay;
export import telar.runtime.proxy.http2_capture_streams;


export import telar.runtime.platform.stream_read_buffer;


export import telar.runtime.platform.system_certificates;

// Interface: proxy/http1_capture_policy.cppm
export {
namespace telar::runtime {

template <typename Capture>
concept Http1CapturePolicy = requires(Capture &capture, CaptureSide side, std::string_view head, std::span<const std::uint8_t> body, std::uint16_t status) {
  { capture.begin() } noexcept -> std::same_as<void>;
  { capture.head(side, head) } noexcept -> std::same_as<void>;
  { capture.payload(side, body) } noexcept -> std::same_as<void>;
  { capture.finishRequest() } noexcept -> std::same_as<void>;
  { capture.finishResponse(status) } noexcept -> std::same_as<void>;
  { capture.discardInformational() } noexcept -> std::same_as<void>;
  { capture.fail() } noexcept -> std::same_as<void>;
};

struct IgnoreHttp1Capture {
  inline void begin() noexcept {}
  inline void head(CaptureSide, std::string_view) noexcept {}
  inline void payload(CaptureSide, std::span<const std::uint8_t>) noexcept {}
  inline void finishRequest() noexcept {}
  inline void finishResponse(std::uint16_t) noexcept {}
  inline void discardInformational() noexcept {}
  inline void fail() noexcept {}
};

static_assert(Http1CapturePolicy<IgnoreHttp1Capture>);

}
}

// Interface: proxy/http1_capture.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory, CaptureClock Clock = CaptureWallClock>
class Http1Capture {
public:
  inline explicit Http1Capture(Memory &memory, CaptureProducer<Memory> *producer, CaptureStart context) noexcept
      : producer_(producer), context_(context), exchange_(memory) {}

  inline void begin() noexcept {
    exchange_.request.reset();
    exchange_.response.reset();
    if (producer_ == nullptr) {
      return;
    }

    context_.started_at_ms = Clock::now();
    context_.side = CaptureSide::request;
    exchange_.request = producer_->start(context_);
    context_.side = CaptureSide::response;
    exchange_.response = producer_->start(context_);
  }

  inline void head(CaptureSide side, std::string_view bytes) noexcept {
    if (auto &half = select(side)) {
      half->appendHead(bytes);
    }
  }

  inline void payload(CaptureSide side, std::span<const std::uint8_t> bytes) noexcept {
    if (auto &half = select(side)) {
      half->append(half->bodyPart(), bytes);
    }
  }

  inline void finishRequest() noexcept {
    finish(CaptureSide::request, CaptureOutcome::finished);
  }

  inline void finishResponse(std::uint16_t status, bool complete = true) noexcept {
    if (exchange_.response) {
      exchange_.response->status_code = status;
    }
    finish(CaptureSide::response, !complete || status >= 400 ? CaptureOutcome::failed : CaptureOutcome::finished);
  }

  inline void discardInformational() noexcept {
    if (exchange_.response) {
      exchange_.response->head.reset();
    }
  }

  inline void fail() noexcept {
    finish(CaptureSide::request, CaptureOutcome::failed);
    finish(CaptureSide::response, CaptureOutcome::failed);
  }

private:
  using Half = typename CaptureProducer<Memory>::Half;

  inline Half &select(CaptureSide side) noexcept {
    return side == CaptureSide::request ? exchange_.request : exchange_.response;
  }

  inline void finish(CaptureSide side, CaptureOutcome outcome) noexcept {
    auto &half = select(side);
    if (half) {
      half->finish(outcome, Clock::now());
      producer_->publish(std::move(half));
    }
  }

  CaptureProducer<Memory> *producer_;
  CaptureStart context_;
  CapturedExchange<Memory> exchange_;
};

template <ConcurrentAllocator Memory>
Http1Capture(Memory &memory, CaptureProducer<Memory> *producer, CaptureStart context) -> Http1Capture<Memory>;

}
}

// Interface: proxy/http1_observer.cppm
export {
namespace telar::runtime {

template <Http1CapturePolicy Capture>
class Http1TransportObserver {
public:
  inline explicit Http1TransportObserver(ProxyCounters &counters, Capture &capture, CaptureSide side) noexcept : counters_(counters), capture_(capture), side_(side) {}

  inline void headStarted() noexcept {}
  inline void head(std::string_view bytes) noexcept { capture_.head(side_, bytes); }
  inline void payload(std::span<const std::uint8_t> bytes) noexcept { capture_.payload(side_, bytes); }

  inline void lineTooLong(Http1Line line) noexcept {
    counters_.record(line == Http1Line::chunk_size ? ProxyCounter::http1_chunk_line_too_long : ProxyCounter::http1_trailer_line_too_long);
  }

private:
  ProxyCounters &counters_;
  Capture &capture_;
  CaptureSide side_;
};

template <Http1CapturePolicy Capture>
Http1TransportObserver(ProxyCounters &counters, Capture &capture, CaptureSide side) -> Http1TransportObserver<Capture>;

static_assert(Http1Observer<Http1TransportObserver<IgnoreHttp1Capture>>);

}
}

// Interface: proxy/socket_interest.cppm
export {
namespace telar::runtime {

struct SocketInterest {
  bool readable = false;
  bool writable = false;
  bool completion = false;

  inline void include(StreamReadiness readiness) noexcept {
    readable = readable || readiness == StreamReadiness::readable;
    writable = writable || readiness == StreamReadiness::writable;
    completion = completion || readiness == StreamReadiness::completion;
  }

  auto operator==(const SocketInterest &) const noexcept -> bool = default;

  [[nodiscard]] inline auto satisfies(StreamReadiness readiness) const noexcept -> bool {
    return (readiness == StreamReadiness::readable && readable) || (readiness == StreamReadiness::writable && writable) || (readiness == StreamReadiness::completion && completion);
  }
};

struct TunnelReadiness {
  SocketInterest child;
  SocketInterest origin;

  static constexpr auto available() noexcept -> TunnelReadiness {
    return {
        .child = {
            .readable = true,
            .writable = true,
            .completion = true,
        },
        .origin = {
            .readable = true,
            .writable = true,
            .completion = true,
        },
    };
  }
};

}
}

// Interface: proxy/http1_connection.cppm
export {
namespace telar::runtime {

template <Http1CapturePolicy Capture = IgnoreHttp1Capture, typename Relay = Http1MessageRelay>
class Http1Connection {
public:
  inline explicit Http1Connection(ProxyCounters &counters, Capture capture = {}) noexcept : counters_(counters), capture_(std::move(capture)) {
    capture_.begin();
  }

  template <Allocator Memory, typename Context>
  inline Http1Connection(Memory &memory, ProxyCounters &counters, Capture capture, Context context) : counters_(counters), capture_(std::move(capture)), request_(memory, context, false), response_(memory, context, true) {
    capture_.begin();
  }

  template <PeekableByteStream Child, PeekableByteStream Origin>
  inline bool advance(Child &child, Origin &origin, TunnelReadiness readiness) noexcept {
    TELAR_TRACE("proxy.http1Exchange");
    if (!rejection_.empty()) {
      return sendRejection(child);
    }

    bool active = false;
    for (std::size_t round = 0; round < maximum_rounds && !finished_ && !upgraded_; ++round) {
      bool request_progress = advanceMessage(request_, child, origin, readiness);
      active = active || request_progress;
      if (sendContinue(child)) {
        active = true;
        request_progress = advanceMessage(request_, child, origin, TunnelReadiness::available()) || request_progress;
      }
      if (request_.state() == State::head_too_large) {
        reject(request_head_too_large);
        return sendRejection(child) || active;
      }
      if (request_.state() == State::failed) {
        if (request_.head()) {
          capture_.fail();
        }
        finished_ = true;
        break;
      }

      if (request_.state() == State::complete) {
        capture_.finishRequest();
      }

      if (!response_started_ && request_.head()) {
        response_.reset(true, request_.head()->head_request);
        if constexpr (requires { response_.destinationHead(request_.originalHead()); }) { response_.destinationHead(request_.originalHead()); }
        response_started_ = true;
      }
      if (!response_started_) {
        break;
      }

      const bool response_progress = advanceMessage(response_, origin, child, {readiness.origin, readiness.child});
      active = active || response_progress;
      if (response_.state() == State::head_too_large) {
        capture_.fail();
        reject(response_head_too_large);
        return sendRejection(child) || active;
      }
      if (response_.state() == State::failed) {
        capture_.fail();
        finished_ = true;
        break;
      }
      if (response_.state() == State::complete) {
        finishResponse();
        continue;
      }
      if (!request_progress && !response_progress) {
        break;
      }
    }
    return active;
  }

  inline SocketInterest childInterest() const noexcept {
    if (!rejection_.empty()) {
      SocketInterest interest;
      interest.include(rejection_waiting_);
      return interest;
    }
    SocketInterest interest;
    interest.include(request_.sourceInterest());
    if constexpr (requires { request_.continueBytes(); }) {
      if (!request_.continueBytes().empty()) { interest.include(continue_waiting_); }
    }
    if (response_started_) {
      interest.include(response_.destinationInterest());
    }
    return interest;
  }

  inline SocketInterest originInterest() const noexcept {
    SocketInterest interest;
    if (rejection_.empty()) {
      interest.include(request_.destinationInterest());
      if (response_started_) {
        interest.include(response_.sourceInterest());
      }
    }
    return interest;
  }

  inline bool readsChild() const noexcept {
    return rejection_.empty() && request_.sourceInterest() != StreamReadiness::none;
  }

  inline bool readsOrigin() const noexcept {
    return rejection_.empty() && response_started_ && response_.sourceInterest() != StreamReadiness::none;
  }

  inline bool finished() const noexcept {
    return finished_;
  }

  inline bool upgraded() const noexcept {
    return upgraded_;
  }

  inline bool idle() const noexcept {
    return !finished_ && !upgraded_ && !request_.started();
  }

  inline std::uint32_t inflight() const noexcept {
    return !finished_ && !upgraded_ && request_.started() ? 1 : 0;
  }

  inline auto deadline() const noexcept -> std::optional<std::chrono::steady_clock::time_point> {
    if constexpr (requires { request_.deadline(); }) {
      const auto request = request_.deadline();
      const auto response = response_.deadline();
      return request && response ? std::min(*request, *response) : request ? request : response;
    }
    return std::nullopt;
  }

private:
  using State = Http1MessageRelay::State;

  template <PeekableByteStream Source, ByteStream Destination>
  inline bool advanceMessage(Relay &message, Source &source, Destination &destination, TunnelReadiness readiness) noexcept {
    bool expired = false;
    if constexpr (requires { message.deadline(); }) {
      const auto deadline = message.deadline();
      expired = deadline && std::chrono::steady_clock::now() >= *deadline;
    }
    if (!expired && !readiness.child.satisfies(message.sourceInterest()) && !readiness.origin.satisfies(message.destinationInterest())) {
      return false;
    }
    Http1TransportObserver observer{counters_, capture_, &message == &request_ ? CaptureSide::request : CaptureSide::response};
    return message.advance(source, destination, observer);
  }

  template <ByteStream Child>
  inline bool sendContinue(Child &child) noexcept {
    if (request_.state() == State::failed) { return false; }
    if constexpr (requires { request_.continueBytes(); }) {
      const auto bytes = request_.continueBytes();
      if (bytes.empty()) { return false; }
      const auto result = child.write({reinterpret_cast<const std::uint8_t *>(bytes.data()), bytes.size()});
      if (result.state == StreamResult::State::blocked) { continue_waiting_ = result.waiting; return false; }
      if (result.state != StreamResult::State::data || result.bytes == 0) { finished_ = true; return false; }
      request_.continueWritten(result.bytes);
      continue_waiting_ = StreamReadiness::writable;
      return true;
    }
    return false;
  }

  inline void finishResponse() noexcept {
    const auto &head = *response_.head();
    if (head.informational) {
      capture_.discardInformational();
      response_.reset(true, request_.head()->head_request);
      return;
    }

    if constexpr (requires { response_.captureIncomplete(); capture_.finishResponse(head.status, false); }) {
      capture_.finishResponse(head.status, !response_.captureIncomplete());
    } else { capture_.finishResponse(head.status); }
    if (request_.state() != State::complete) {
      finished_ = true;
    } else if (head.upgrade) {
      upgraded_ = true;
    } else if (head.closes) {
      finished_ = true;
    } else {
      request_.reset(false);
      response_started_ = false;
      capture_.begin();
    }
  }

  inline void reject(std::string_view answer) noexcept {
    counters_.record(ProxyCounter::http1_head_too_large);
    rejection_ = answer;
  }

  template <ByteStream Child>
  inline bool sendRejection(Child &child) noexcept {
    const auto remaining = rejection_.substr(rejection_offset_);
    const auto sent = child.write({reinterpret_cast<const std::uint8_t *>(remaining.data()), remaining.size()});
    if (sent.state == StreamResult::State::blocked) {
      rejection_waiting_ = sent.waiting;
      return false;
    }
    if (sent.state != StreamResult::State::data || sent.bytes == 0) {
      finished_ = true;
      return false;
    }
    rejection_offset_ += sent.bytes;
    finished_ = rejection_offset_ == rejection_.size();
    return true;
  }

  static constexpr std::size_t maximum_rounds = 8;
  static constexpr std::string_view request_head_too_large = "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
  static constexpr std::string_view response_head_too_large = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
  ProxyCounters &counters_;
  [[no_unique_address]] Capture capture_;
  Relay request_;
  Relay response_;
  StreamReadiness continue_waiting_ = StreamReadiness::writable;
  std::string_view rejection_;
  std::size_t rejection_offset_ = 0;
  StreamReadiness rejection_waiting_ = StreamReadiness::writable;
  bool response_started_ = false;
  bool finished_ = false;
  bool upgraded_ = false;
};

}
}

// Interface: proxy/socket_watch.cppm
export {
namespace telar::runtime {

class SocketWatch {
public:
  template <EventLoop Poller>
  inline void update(Poller &poller, int descriptor, std::uint64_t token, SocketInterest interest) {
    const bool changed = descriptor != descriptor_ || token != token_ || interest != interest_;
    if (descriptor != descriptor_) {
      remove(poller);
      descriptor_ = descriptor;
    }
    token_ = token;
    if (changed && descriptor_ >= 0) {
      poller.readInterest(descriptor_, token_, interest.readable);
      poller.writeInterest(descriptor_, token_, interest.writable);
    }
    interest_ = interest;
  }

  template <EventLoop Poller>
  inline void remove(Poller &poller) noexcept {
    if (descriptor_ >= 0) {
      poller.remove(descriptor_);
      descriptor_ = -1;
    }
    interest_ = {};
  }

  inline bool matches(const Event &event) const noexcept {
    return descriptor_ >= 0 && event.descriptor == descriptor_ && event.token == token_;
  }

private:
  int descriptor_ = -1;
  std::uint64_t token_ = 0;
  SocketInterest interest_;
};

}
}
