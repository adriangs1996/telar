#pragma once

#include "../diagnostics/trace.hpp"
#include "../http1/message_relay.hpp"
#include "http1_observer.hpp"
#include "socket_interest.hpp"

namespace telar::runtime {

template <Http1CapturePolicy Capture = IgnoreHttp1Capture>
class Http1Connection {
public:
  explicit Http1Connection(ProxyCounters &counters, Capture capture = {}) noexcept : counters_(counters), capture_(std::move(capture)) {
    capture_.begin();
  }

  template <PeekableByteStream Child, PeekableByteStream Origin>
  bool advance(Child &child, Origin &origin, TunnelReadiness readiness) noexcept {
    TELAR_TRACE("proxy.http1Exchange");
    if (!rejection_.empty()) {
      return sendRejection(child);
    }

    bool active = false;
    for (std::size_t round = 0; round < maximum_rounds && !finished_ && !upgraded_; ++round) {
      const bool request_progress = advanceMessage(request_, child, origin, readiness);
      active = active || request_progress;
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

  SocketInterest childInterest() const noexcept {
    if (!rejection_.empty()) {
      SocketInterest interest;
      interest.include(rejection_waiting_);
      return interest;
    }
    SocketInterest interest;
    interest.include(request_.sourceInterest());
    if (response_started_) {
      interest.include(response_.destinationInterest());
    }
    return interest;
  }

  SocketInterest originInterest() const noexcept {
    SocketInterest interest;
    if (rejection_.empty()) {
      interest.include(request_.destinationInterest());
      if (response_started_) {
        interest.include(response_.sourceInterest());
      }
    }
    return interest;
  }

  bool readsChild() const noexcept {
    return rejection_.empty() && request_.sourceInterest() != StreamReadiness::none;
  }

  bool readsOrigin() const noexcept {
    return rejection_.empty() && response_started_ && response_.sourceInterest() != StreamReadiness::none;
  }

  bool finished() const noexcept {
    return finished_;
  }

  bool upgraded() const noexcept {
    return upgraded_;
  }

  bool idle() const noexcept {
    return !finished_ && !upgraded_ && !request_.started();
  }

  std::uint32_t inflight() const noexcept {
    return !finished_ && !upgraded_ && request_.started() ? 1 : 0;
  }

private:
  using State = Http1MessageRelay::State;

  template <PeekableByteStream Source, ByteStream Destination>
  bool advanceMessage(Http1MessageRelay &message, Source &source, Destination &destination, TunnelReadiness readiness) noexcept {
    if (!readiness.child.satisfies(message.sourceInterest()) && !readiness.origin.satisfies(message.destinationInterest())) {
      return false;
    }
    Http1TransportObserver observer{counters_, capture_, &message == &request_ ? CaptureSide::request : CaptureSide::response};
    return message.advance(source, destination, observer);
  }

  void finishResponse() noexcept {
    const auto &head = *response_.head();
    if (head.informational) {
      capture_.discardInformational();
      response_.reset(true, request_.head()->head_request);
      return;
    }

    capture_.finishResponse(head.status);
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

  void reject(std::string_view answer) noexcept {
    counters_.record(ProxyCounter::http1_head_too_large);
    rejection_ = answer;
  }

  template <ByteStream Child>
  bool sendRejection(Child &child) noexcept {
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
  Http1MessageRelay request_;
  Http1MessageRelay response_;
  std::string_view rejection_;
  std::size_t rejection_offset_ = 0;
  StreamReadiness rejection_waiting_ = StreamReadiness::writable;
  bool response_started_ = false;
  bool finished_ = false;
  bool upgraded_ = false;
};

}
