#pragma once

#include "session.hpp"
#include "traffic_protocol.hpp"
#include "../traffic/package_port.hpp"
#include "../traffic/control_access.hpp"
#include "../memory/erasing_allocator.hpp"
#include "../memory/byte_queue.hpp"
#include "../proxy/socket.hpp"
#include <poll.h>

namespace telar::runtime::plugins {

template <ConcurrentAllocator Memory>
class TrafficBridge {
  using Secure = ErasingAllocator<Memory>;
  struct Connection {
    explicit Connection(Secure &memory, TrafficRegistration registration, traffic::PackageChannel channel)
        : registration(std::move(registration)), socket(std::move(channel.socket)), owner(channel.owner), output(memory, 2 * traffic::Limits::http_frame_bytes), registration_ack(this->registration.stage == TrafficStage::stream || this->registration.stage == TrafficStage::http) {}
    TrafficRegistration registration;
    FileDescriptor socket;
    std::uint64_t owner;
    ByteQueue<Secure> output;
    std::array<Byte, traffic::Protocol::prefix_bytes> prefix;
    std::size_t prefix_bytes = 0;
    std::uint64_t dropped = 0;
    std::optional<SensitiveAllocation<Memory>> input;
    std::size_t received = 0;
    bool registration_ack;
    bool ready = false;
    bool notify_ready = false;
    std::chrono::steady_clock::time_point deadline = std::chrono::steady_clock::now() + std::chrono::seconds{45};
    FixedText<1024> error;
  };

public:
  explicit TrafficBridge(Memory &memory, const ServiceSpec &specification, traffic::PackagePort &port, Session<Memory> &session)
      : memory_(memory), secure_(memory), specification_(specification), port_(port), reply_(makeOwned<TrafficReply>(memory)) {
    attach(session);
  }

  void attach(Session<Memory> &session) {
    std::array<Byte, 1024> output;
    auto initialized = session.request(TrafficProtocol::setup(output, specification_), TrafficLimits::reply_bytes);
    apply(0, initialized.bytes());
    session_ = &session;
    for (auto &connection : connections_) {
      if (connection && connection->registration.stage != TrafficStage::control) {
        port_.setPackageAvailable(connection->owner, true);
        connection->notify_ready = connection->ready;
      }
    }
  }

  void detach() noexcept {
    session_ = nullptr;
    for (auto &connection : connections_) {
      if (connection && connection->registration.stage == TrafficStage::control) { connection.reset(); }
      else if (connection) { port_.setPackageAvailable(connection->owner, false); connection->notify_ready = false; }
    }
  }

  std::uint64_t errors() const noexcept { return errors_; }
  bool transportFailed() const noexcept { return transport_failed_; }

  template <typename Consumer>
  void step(int wake, const CancellationSignal &cancellation, Consumer &&consume, bool immediate = false) {
    for (auto &connection : connections_) {
      if (!connection || connection->registration.stage != TrafficStage::control) { continue; }
      if (std::chrono::steady_clock::now() >= connection->deadline) { connection->error.assign("Network control deadline exceeded"); }
      if (!connection->socket && connection->error.view().empty()) {
        try { connection->socket = port_.openControl(specification_); }
        catch (const SystemError &failure) { if (failure.code() != EAGAIN) { connection->error.assign(std::string_view{failure.what()}.substr(0, 1024)); } }
        catch (const std::exception &failure) { connection->error.assign(std::string_view{failure.what()}.substr(0, 1024)); }
      }
      if (!connection->error.view().empty()) { dispatchControl(connection, {}, connection->error.view(), consume); return; }
    }
    for (auto &connection : connections_) {
      if (connection && connection->notify_ready) {
        connection->notify_ready = false;
        constexpr std::string_view reason = "worker_restarted";
        std::array<Byte, 128> output;
        const auto ready = traffic::Protocol::encode(output, {.kind = traffic::Kind::ready, .bytes = {reinterpret_cast<const Byte *>(reason.data()), reason.size()}});
        dispatch(*connection, ready, connection->dropped, consume);
      }
    }
    std::array<pollfd, TrafficLimits::registrations + 3> descriptors{};
    std::array<std::uint32_t, TrafficLimits::registrations> identities{};
    descriptors[0] = {wake, POLLIN, 0};
    descriptors[1] = {cancellation.descriptor(), POLLIN, 0};
    descriptors[2] = {session_ ? session_->outputDescriptor() : -1, POLLIN, 0};
    for (std::size_t index = 0; index < connections_.size(); ++index) {
      const auto &connection = connections_[index];
      identities[index] = connection ? connection->registration.id : 0;
      descriptors[index + 3] = {connection ? connection->socket.get() : -1, static_cast<short>(POLLIN | (connection && connection->output.size() ? POLLOUT : 0)), 0};
    }
    if (::poll(descriptors.data(), descriptors.size(), immediate ? 0 : 100) < 0) {
      if (errno == EINTR) { return; }
      throw SystemError{"Poll package traffic"};
    }
    if (cancellation.requested()) { return; }
    if (descriptors[2].revents != 0) { throw SystemError{"Traffic worker sent an unsolicited reply or exited", EPIPE}; }
    enum class Priority { intercept, observe, control };
    for (const auto priority : {Priority::intercept, Priority::observe, Priority::control}) {
      for (std::size_t index = 0; index < connections_.size(); ++index) {
        auto &connection = connections_[index];
        if (!connection) { continue; }
        const auto stage = connection->registration.stage;
        const auto selected = stage == TrafficStage::control ? Priority::control : stage == TrafficStage::observe ? Priority::observe : Priority::intercept;
        if (selected != priority) { continue; }
        if (connection->registration.id != identities[index]) { continue; }
        const auto readiness = descriptors[index + 3].revents;
        if (stage == TrafficStage::control) {
          std::optional<SensitiveAllocation<Memory>> frame;
          try {
            if (readiness & (POLLERR | POLLNVAL)) { throw SystemError{"Package control channel failed", EPIPE}; }
            if (readiness & POLLOUT) { write(*connection); }
            if (readiness & (POLLIN | POLLHUP)) { frame = read(*connection); }
          } catch (const std::exception &failure) { connection->error.assign(std::string_view{failure.what()}.substr(0, 1024)); }
          if (!connection->error.view().empty()) { dispatchControl(connection, {}, connection->error.view(), consume); }
          else if (frame) { traffic::control::Protocol::reply(frame->bytes()); dispatchControl(connection, frame->bytes(), {}, consume); }
          continue;
        }
        if (readiness & (POLLERR | POLLNVAL)) { transport_failed_ = true; throw SystemError{"Package traffic channel failed", EPIPE}; }
        try { if (readiness & POLLOUT) { write(*connection); } }
        catch (...) { transport_failed_ = true; throw; }
        if (readiness & (POLLIN | POLLHUP)) {
          std::optional<SensitiveAllocation<Memory>> frame;
          try { frame = read(*connection); }
          catch (...) { transport_failed_ = true; throw; }
          if (!frame) { continue; }
          const auto kind = traffic::Protocol::decode(frame->bytes()).kind;
          if (connection->registration_ack && kind == traffic::Kind::ready) { connection->registration_ack = false; continue; }
          if (kind == traffic::Kind::ready) { connection->ready = true; }
          dispatch(*connection, frame->bytes(), connection->dropped, consume);
        }
      }
    }
  }

private:
  template <typename Consumer>
  void dispatchControl(std::optional<Connection> &connection, std::span<const Byte> frame, std::string_view error, Consumer &&consume) {
    if (!session_) { connection.reset(); return; }
    SensitiveAllocation request{memory_, frame.size() + error.size() + 128};
    const auto event_id = ++next_event_;
    const auto encoded = TrafficProtocol::controlEvent(request.bytes(), event_id, connection->registration.id, frame, error);
    connection.reset();
    auto response = session_->request(encoded, TrafficLimits::reply_bytes);
    if (response.bytes().front() == static_cast<Byte>(FrameKind::error)) {
      if (Protocol::decodeError(response.bytes()).event_id != event_id) { throw EncodingError{"Stale control callback error"}; }
      ++errors_;
      return;
    }
    apply(event_id, response.bytes());
    publishEffects(event_id, std::move(response), consume);
  }

  template <typename Consumer>
  void publishEffects(std::uint64_t event_id, SensitiveAllocation<Memory> response, Consumer &&consume) {
    if (reply_->effects.empty()) { return; }
    const auto effects = Protocol::decodeEffects(reply_->effects);
    if (effects.event_id != event_id) { throw EncodingError{"Stale traffic notification"}; }
    if (effects.batch.count != 0) { consume(std::move(response), effects); }
  }

  template <typename Consumer>
  void dispatch(Connection &connection, std::span<const Byte> frame, std::uint64_t dropped, Consumer &&consume) {
    const auto event = traffic::Protocol::decode(frame);
    const bool control = event.kind == traffic::Kind::intercept_request || event.kind == traffic::Kind::http_intercept_request;
    std::optional<traffic::FlowEvent> flow;
    if (control) {
      flow = traffic::FlowCodec::decode(event.bytes);
      if (!port_.packagePending(connection.owner, flow->ticket, connection.registration.stage == TrafficStage::http)) { return; }
    }
    if (!session_) {
      if (control) { fail(connection, *flow); }
      else { ++dropped_observations_; }
      return;
    }
    SensitiveAllocation request{memory_, frame.size() + 64};
    const auto event_id = ++next_event_;
    auto response = session_->request(TrafficProtocol::event(request.bytes(), event_id, connection.registration.id, frame, dropped + dropped_observations_), TrafficLimits::reply_bytes);
    if (response.bytes().front() == static_cast<Byte>(FrameKind::error)) {
      const auto error = Protocol::decodeError(response.bytes());
      if (error.event_id != event_id) { throw EncodingError{"Stale traffic callback error"}; }
      ++errors_;
      if (control) { fail(connection, *flow); port_.packageFailure(specification_, *flow); }
      return;
    }
    apply(event_id, response.bytes());
    publishEffects(event_id, std::move(response), consume);
  }

  static void fail(Connection &connection, const traffic::FlowEvent &flow) {
    std::array<Byte, 32> decision;
    enqueue(connection, traffic::InterceptionCodec::decision(decision, flow.ticket, connection.registration.fail_closed ? traffic::Verdict::reject : traffic::Verdict::allow));
  }

  Connection *find(std::uint32_t id) noexcept {
    for (auto &connection : connections_) { if (connection && connection->registration.id == id) { return &*connection; } }
    return nullptr;
  }

  void apply(std::uint64_t event_id, std::span<const Byte> input) {
    TrafficProtocol::readReply(input, *reply_);
    if (reply_->event_id != event_id) { throw EncodingError{"Stale traffic worker reply"}; }
    const auto registrations = std::span{reply_->registrations}.first(reply_->registration_count);
    if (reply_->changed) {
      std::size_t controls = 0;
      for (std::size_t index = 0; index < registrations.size(); ++index) {
        const auto &registration = registrations[index];
        if (registration.stage == TrafficStage::control) {
          if (++controls > TrafficLimits::controls || !traffic::control::authorized(specification_, traffic::control::Protocol::request(registration.requestBytes()))) { throw EncodingError{"Package control capability denied"}; }
        } else if (!specification_.allows(registration.stage == TrafficStage::observe ? Capability::traffic_observe : Capability::traffic_intercept)) { throw EncodingError{"Package traffic capability denied"}; }
        if (std::ranges::any_of(registrations.first(index), [&](const auto &other) { return other.id == registration.id; })) { throw EncodingError{"Duplicate traffic registration"}; }
      }
      for (auto &connection : connections_) {
        if (connection && !std::ranges::any_of(registrations, [&](const auto &registration) { return registration.id == connection->registration.id; })) { connection.reset(); }
      }
      for (const auto &registration : registrations) {
        if (auto *existing = find(registration.id)) {
          const auto &before = existing->registration;
          if (before.stage != registration.stage || before.selection != registration.selection || before.filter.view() != registration.filter.view() || before.host.view() != registration.host.view() || before.directions != registration.directions || before.visibility != registration.visibility || before.timeout_ms != registration.timeout_ms || before.fail_closed != registration.fail_closed || before.request.view() != registration.request.view()) { throw EncodingError{"Traffic registrations are immutable"}; }
          continue;
        }
        for (auto &connection : connections_) {
          if (connection) { continue; }
          if (registration.stage == TrafficStage::control) {
            connection.emplace(secure_, registration, traffic::PackageChannel{FileDescriptor{}, 0});
            connection->output.append(traffic::control::Protocol::prefix(registration.requestBytes().size()));
            connection->output.append(registration.requestBytes());
            break;
          }
          connection.emplace(secure_, registration, port_.openPackage(specification_, registration.id));
          std::array<Byte, traffic::Protocol::greeting_bytes + traffic::Limits::filter_bytes> greeting;
          const auto hello = traffic::Protocol::greeting(greeting, registration.stage == TrafficStage::observe ? traffic::Role::subscribe : traffic::Role::intercept, registration.filter.view(), registration.selection);
          connection->output.append(hello);
          if (registration.stage != TrafficStage::observe) {
            const auto rule = traffic::InterceptionCodec::rule(greeting, registration.rule());
            enqueue(*connection, rule);
          }
          break;
        }
      }
    }
    for (const auto &decision : std::span{reply_->decisions}.first(reply_->decision_count)) {
      auto *connection = find(decision.registration);
      if (!connection) { continue; }
      if (connection->registration.stage != TrafficStage::stream && connection->registration.stage != TrafficStage::http) { throw EncodingError{"Only interceptors can decide traffic"}; }
      FrameReader reader{decision.payload};
      reader.require(traffic::InterceptionCodec::Command::decision);
      reader.integer<std::uint64_t>();
      const auto verdict = reader.tag(traffic::Verdict::reject);
      const auto bytes = reader.bytes();
      reader.finish();
      if (verdict == traffic::Verdict::pending || (verdict != traffic::Verdict::replace && !bytes.empty())) { throw EncodingError{"Invalid worker decision"}; }
      if (connection->registration.stage == TrafficStage::http && verdict == traffic::Verdict::replace) { HttpMessageCodec::decode(bytes); }
      else if (bytes.size() > traffic::FlowControl::chunk_bytes) { throw EncodingError{"Worker stream decision exceeds its bound"}; }
      enqueue(*connection, decision.payload);
    }
  }

  static void enqueue(Connection &connection, std::span<const Byte> frame) {
    connection.output.append(traffic::Protocol::prefix(frame.size()));
    connection.output.append(frame);
  }

  static void write(Connection &connection) {
    const auto bytes = connection.output.readable();
    const auto count = ::send(connection.socket.get(), bytes.data(), bytes.size(), 0);
    if (count < 0 && socketWouldBlock(errno)) { return; }
    if (count <= 0) { throw SystemError{"Write package traffic", EPIPE}; }
    connection.output.consume(static_cast<std::size_t>(count));
  }

  std::optional<SensitiveAllocation<Memory>> read(Connection &connection) {
    if (!connection.input) {
      const auto prefix_bytes = connection.registration.stage == TrafficStage::control ? traffic::control::Protocol::prefix_bytes : traffic::Protocol::prefix_bytes;
      const auto count = ::recv(connection.socket.get(), connection.prefix.data() + connection.prefix_bytes, prefix_bytes - connection.prefix_bytes, 0);
      if (count < 0 && socketWouldBlock(errno)) { return std::nullopt; }
      if (count <= 0) { throw SystemError{"Read package traffic prefix", EPIPE}; }
      connection.prefix_bytes += static_cast<std::size_t>(count);
      if (connection.prefix_bytes != prefix_bytes) { return std::nullopt; }
      FrameReader prefix{std::span<const Byte>{connection.prefix}.first(prefix_bytes)};
      const auto size = prefix.integer<std::uint32_t>();
      if (connection.registration.stage != TrafficStage::control) { connection.dropped = prefix.integer<std::uint64_t>(); }
      const auto maximum = connection.registration.stage == TrafficStage::control ? traffic::control::Limits::reply_bytes : connection.registration.stage == TrafficStage::http ? traffic::Limits::http_frame_bytes : traffic::Limits::frame_bytes;
      if (size == 0 || size > maximum) { throw EncodingError{"Invalid package traffic frame size"}; }
      connection.input.emplace(memory_, size);
      connection.received = 0;
    }
    const auto bytes = connection.input->bytes();
    const auto count = ::recv(connection.socket.get(), bytes.data() + connection.received, bytes.size() - connection.received, 0);
    if (count < 0 && socketWouldBlock(errno)) { return std::nullopt; }
    if (count <= 0) { throw SystemError{"Read package traffic frame", EPIPE}; }
    connection.received += static_cast<std::size_t>(count);
    if (connection.received != bytes.size()) { return std::nullopt; }
    auto frame = std::move(connection.input);
    connection.input.reset();
    connection.prefix_bytes = 0;
    return frame;
  }

  Memory &memory_;
  Secure secure_;
  ServiceSpec specification_;
  traffic::PackagePort &port_;
  Session<Memory> *session_ = nullptr;
  std::array<std::optional<Connection>, TrafficLimits::registrations> connections_;
  Owned<TrafficReply, Memory> reply_;
  std::uint64_t next_event_ = 0;
  std::uint64_t errors_ = 0;
  std::uint64_t dropped_observations_ = 0;
  bool transport_failed_ = false;
};

}
