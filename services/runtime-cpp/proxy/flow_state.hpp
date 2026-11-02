#pragma once

#include "../traffic/flow.hpp"
#include "../memory/fixed_text.hpp"
#include "../memory/sensitive_buffer.hpp"
#include "../platform/byte_stream.hpp"
#include <netdb.h>
#include <cstdio>
#include <sys/socket.h>

namespace telar::runtime {

class FlowGate {
public:
  FlowGate() = default;
  ~FlowGate() {
    if (control_ && ticket_) {
      control_->cancel(ticket_);
    }
  }
  FlowGate(const FlowGate &) = delete;
  FlowGate &operator=(const FlowGate &) = delete;

  void attach(traffic::FlowControl *control, traffic::FlowEvent event) noexcept {
    control_ = control;
    event_ = event;
  }

  void visibility(traffic::Visibility value) noexcept { event_.visibility = value; }
  std::optional<traffic::FlowControl::Time> deadline() const noexcept { return ticket_ ? control_->deadline(ticket_) : std::nullopt; }
  bool rejected() const noexcept { return rejected_; }
  std::string_view failureReason() const noexcept { return failure_; }
  void fail(std::string_view reason, bool reading = false) noexcept {
    if (rejected_) { return; }
    rejected_ = true;
    failure_ = reason;
    if (control_) {
      auto event = event_;
      event.bytes = {};
      event.reason = reason;
      if (reading) { event.direction = event.direction == traffic::Direction::outbound ? traffic::Direction::inbound : traffic::Direction::outbound; }
      control_->observeFlow(traffic::Kind::flow_error, event);
    }
  }

  // The caller retains its input until the entire replacement has been sent, including partial TLS writes.
  template <ByteStream Stream>
  StreamResult write(Stream &stream, std::span<const Byte> bytes) noexcept {
    if (rejected_) {
      return {StreamResult::State::failed};
    }
    if (!control_) {
      return stream.write(bytes);
    }
    if (!offered_) {
      event_.bytes = bytes.first(std::min(bytes.size(), traffic::FlowControl::chunk_bytes));
      original_size_ = event_.bytes.size();
      ticket_ = control_->intercept(event_);
      offered_ = true;
    }
    if (ticket_) {
      const auto decision = control_->poll(ticket_, replacement_.bytes());
      if (decision.verdict == traffic::Verdict::pending) {
        return {StreamResult::State::blocked, 0, StreamReadiness::completion};
      }
      ticket_ = 0;
      if (decision.verdict == traffic::Verdict::reject) {
        fail("hook_rejected");
        return {StreamResult::State::failed};
      }
      replacing_ = decision.verdict == traffic::Verdict::replace;
      replacement_size_ = decision.bytes;
    }

    const auto input = bytes.first(original_size_);
    const auto output = replacing_ ? replacement_.bytes().first(replacement_size_).subspan(sent_) : input;
    if (output.empty()) {
      return complete();
    }
    const auto result = stream.write(output);
    if (result.state != StreamResult::State::data) {
      if (result.state == StreamResult::State::failed || result.state == StreamResult::State::ended) { fail("socket_write_failed"); }
      return result;
    }
    event_.bytes = output.first(result.bytes);
    control_->observeFlow(traffic::Kind::stream_data, event_);
    event_.offset += result.bytes;
    if (replacing_) {
      sent_ += result.bytes;
      return sent_ == replacement_size_ ? complete() : StreamResult{StreamResult::State::blocked, 0, StreamReadiness::writable};
    }
    offered_ = false;
    return result;
  }

private:
  StreamResult complete() noexcept {
    const auto count = original_size_;
    eraseSensitive(replacement_.bytes().data(), replacement_size_);
    offered_ = replacing_ = false;
    sent_ = replacement_size_ = 0;
    return {StreamResult::State::data, count};
  }

  traffic::FlowControl *control_ = nullptr;
  traffic::FlowEvent event_;
  SensitiveBuffer<traffic::FlowControl::chunk_bytes> replacement_;
  std::uint64_t ticket_ = 0;
  std::size_t original_size_ = 0;
  std::size_t replacement_size_ = 0;
  std::size_t sent_ = 0;
  bool offered_ = false;
  bool replacing_ = false;
  bool rejected_ = false;
  std::string_view failure_;
};

template <ByteStream Stream>
class FlowStream {
public:
  explicit FlowStream(Stream &stream, FlowGate &gate) noexcept : stream_(stream), gate_(&gate) {}
  explicit FlowStream(Stream &stream, FlowGate *gate) noexcept : stream_(stream), gate_(gate) {}
  StreamResult read(std::span<Byte> bytes) noexcept {
    const auto result = stream_.read(bytes);
    if (gate_ && result.state == StreamResult::State::failed) { gate_->fail("socket_read_failed", true); }
    return result;
  }
  StreamResult write(std::span<const Byte> bytes) noexcept { return gate_ ? gate_->write(stream_, bytes) : stream_.write(bytes); }
  void halfClose() noexcept { stream_.halfClose(); }
  StreamResult peek(std::span<Byte> bytes) noexcept requires PeekableByteStream<Stream> {
    const auto result = stream_.peek(bytes);
    if (gate_ && result.state == StreamResult::State::failed) { gate_->fail("socket_read_failed", true); }
    return result;
  }
  StreamView peekView(std::size_t maximum) noexcept requires BufferedByteStream<Stream> {
    const auto result = stream_.peekView(maximum);
    if (gate_ && result.state == StreamResult::State::failed) { gate_->fail("socket_read_failed", true); }
    return result;
  }
  void consume(std::size_t bytes) noexcept requires BufferedByteStream<Stream> { stream_.consume(bytes); }
private:
  Stream &stream_;
  FlowGate *gate_;
};

class FlowState {
public:
  ~FlowState() {
    if (control_) {
      event_.reason = outbound.rejected() ? outbound.failureReason() : inbound.rejected() ? inbound.failureReason() : reason_;
      control_->observeFlow(traffic::Kind::flow_close, event_);
    }
  }

  void open(traffic::FlowControl *control, std::uint64_t id, int child, int origin, std::string_view host) noexcept {
    control_ = control;
    endpoint(child, client_);
    endpoint(origin, server_);
    event_ = {.id = id, .client = client_.view(), .server = server_.view(), .host = host};
    outbound.attach(control, event_);
    auto incoming = event_;
    incoming.direction = traffic::Direction::inbound;
    inbound.attach(control, incoming);
    if (control_) {
      control_->observeFlow(traffic::Kind::flow_open, event_);
    }
  }

  void visibility(traffic::Visibility value) noexcept {
    event_.visibility = value;
    outbound.visibility(value);
    inbound.visibility(value);
  }

  void reason(std::string_view value) noexcept { reason_ = value; }
  auto context() const noexcept -> traffic::FlowEvent { return event_; }
  void error(std::string_view value) noexcept {
    reason_ = value;
    if (control_) {
      event_.reason = value;
      control_->observeFlow(traffic::Kind::flow_error, event_);
    }
  }
  bool rejected() const noexcept { return outbound.rejected() || inbound.rejected(); }

  std::optional<traffic::FlowControl::Time> deadline() const noexcept {
    const auto out = outbound.deadline();
    const auto in = inbound.deadline();
    return out && in ? std::min(*out, *in) : out ? out : in;
  }

  FlowGate outbound;
  FlowGate inbound;

private:
  static void endpoint(int socket, FixedText<128> &result) noexcept {
    sockaddr_storage address{};
    socklen_t size = sizeof(address);
    std::array<char, NI_MAXHOST> host{};
    std::array<char, NI_MAXSERV> port{};
    if (::getpeername(socket, reinterpret_cast<sockaddr *>(&address), &size) == 0 && ::getnameinfo(reinterpret_cast<sockaddr *>(&address), size, host.data(), host.size(), port.data(), port.size(), NI_NUMERICHOST | NI_NUMERICSERV) == 0) {
      std::array<char, 128> text{};
      std::snprintf(text.data(), text.size(), address.ss_family == AF_INET6 ? "[%s]:%s" : "%s:%s", host.data(), port.data());
      result.assign(text.data());
    }
  }
  traffic::FlowControl *control_ = nullptr;
  traffic::FlowEvent event_;
  FixedText<128> client_;
  FixedText<128> server_;
  std::string_view reason_ = "closed";
};

}
