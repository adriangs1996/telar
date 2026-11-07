module;
#include "telar_platform/trace_macro.hpp"
#include <cstdlib>
#include <new>
#include <stdlib.h>

#include <cstdint>
#include <cstddef>
#include <cstring>
#include <cassert>
#include <cerrno>

#include <limits.h>


#include <sys/types.h>
#include <climits>
#include <poll.h>

#include <sys/uio.h>
#include <unistd.h>
#include <csignal>
#include <cstdio>

#include <arpa/inet.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

export module telar.runtime.plugins.worker;

import std;

export import telar.runtime.platform.stream_read_buffer;
export import telar.runtime.plugins.protocol;
export import telar.base.memory;
export import telar.platform;


export import telar.runtime.plugins.tap_configuration;


export import telar.runtime.platform.request_worker;


export import telar.plugins;


export import telar.runtime.traffic.control_backend;
export import telar.runtime.traffic.control_protocol;


export import telar.runtime.proxy.relay_direction;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: plugins/frame_channel.cppm
export {
namespace telar::runtime::plugins {

template <typename Stream>
concept FrameStream = requires(Stream &stream, std::span<Byte> destination, std::span<const Byte> bytes) {
  { stream.read(destination) } noexcept -> std::same_as<StreamResult>;
  { stream.write(bytes, bytes) } -> std::same_as<void>;
};

template <FrameStream Stream>
class FrameChannel {
public:
  inline explicit FrameChannel(Stream &stream) noexcept : stream_(stream) {}

  template <Allocator Memory>
  inline std::optional<SensitiveAllocation<Memory>> receive(Memory &memory, std::size_t maximum_bytes) {
    std::array<Byte, Protocol::prefix_bytes> prefix;
    if (!readExact(prefix)) {
      return std::nullopt;
    }

    std::span<const Byte> remaining{prefix};
    const auto length = LittleEndian<std::uint32_t>::decode(remaining);
    if (length == 0 || length > maximum_bytes) {
      throw EncodingError{"Invalid tap frame length"};
    }

    SensitiveAllocation frame{memory, length};
    if (!readExact(frame.bytes())) {
      throw SystemError{"Incomplete tap frame", EPIPE};
    }
    return frame;
  }

  inline void send(std::span<const Byte> payload) {
    if (payload.empty() || payload.size() > Limits::frame_bytes) {
      throw EncodingError{"Invalid tap frame length"};
    }

    std::array<Byte, Protocol::prefix_bytes> prefix;
    std::span<Byte> remaining{prefix};
    LittleEndian<std::uint32_t>::encode(static_cast<std::uint32_t>(payload.size()), remaining);
    stream_.write(prefix, payload);
  }

private:
  inline bool readExact(std::span<Byte> destination) {
    while (!destination.empty()) {
      const auto count = readNext(destination);
      if (count == 0) {
        return false;
      }

      destination = destination.subspan(count);
    }
    return true;
  }

  inline std::size_t readNext(std::span<Byte> destination) {
    if (input_.empty() && destination.size() >= input_capacity) {
      const auto received = stream_.read(destination);
      requireReadable(received.state);
      return received.bytes;
    }

    const auto view = input_.peek([this](std::span<Byte> bytes) noexcept { return stream_.read(bytes); }, destination.size());
    requireReadable(view.state);
    return input_.copyTo(destination);
  }

  inline static void requireReadable(StreamResult::State state) {
    if (state != StreamResult::State::data && state != StreamResult::State::ended) {
      throw SystemError{"Read tap frame"};
    }
  }

  static constexpr std::size_t input_capacity = 16 * 1024;
  Stream &stream_;
  StreamReadBuffer<input_capacity> input_;
};

template <FrameStream Stream>
FrameChannel(Stream &stream) -> FrameChannel<Stream>;

}
}

// Interface: plugins/result.cppm
export {
namespace telar::runtime::plugins {

template <Allocator Memory>
struct Result {
  inline explicit Result(const ServiceSpec &specification, SensitiveAllocation<Memory> storage, EffectReply reply, bool traffic = false) noexcept
      : package_index(specification.package_index), plugin_id(specification.plugin_id), digest(specification.digest), generation(specification.generation), event_id(reply.event_id), storage(std::move(storage)), batch(reply.batch), traffic(traffic) {}

  inline bool authorized(const ServiceSpec &specification) const noexcept {
    const bool source = traffic ? specification.traffic() : specification.allows(Capability::proxy_tap);
    return package_index == specification.package_index && plugin_id == specification.plugin_id && digest == specification.digest && generation == specification.generation && source && (batch.count == 0 || specification.allows(Capability::notifications));
  }

  std::uint8_t package_index;
  std::uint64_t plugin_id;
  PackageDigest digest;
  std::uint64_t generation;
  std::uint64_t event_id;
  SensitiveAllocation<Memory> storage;
  EffectBatch batch;
  bool traffic = false;
};

template <Allocator Memory>
using OwnedResult = Owned<Result<Memory>, Memory>;

}
}

// Interface: plugins/result_queue.cppm
export {
namespace telar::runtime::plugins {

template <Allocator Memory>
class ResultQueue {
  static_assert(Limits::queue_depth <= PIPE_BUF);

public:
  inline void activate() { ready_.emplace(); }

  inline void publish(OwnedResult<Memory> result) noexcept {
    if (results_.publish(std::move(result))) {
      ready_->notify();
    }
  }

  template <typename Consumer>
  inline void collect(Consumer &&consumer) {
    if (!ready_ || !ready_->consume()) {
      return;
    }

    auto result = results_.tryReceive();
    if (result) {
      consumer(**result);
    }
  }

  inline void close() noexcept { results_.close(); }
  inline int descriptor() const noexcept { return ready_ ? ready_->descriptor() : -1; }

private:
  DropChannel<OwnedResult<Memory>, Limits::queue_depth, ChannelPolicy::keep_oldest> results_;
  std::optional<CompletionSignal> ready_;
};

}
}

// Interface: plugins/session_io.cppm
export {
namespace telar::runtime::plugins {

class SessionIo {
public:
  inline explicit SessionIo(PipeProcess &process, const CancellationSignal &cancellation) noexcept
      : process_(process), cancellation_(cancellation) {}

  inline void deadline(std::chrono::milliseconds timeout) noexcept { deadline_ = Clock::now() + timeout; }

  inline bool active() const noexcept {
    if (cancellation_.requested()) {
      errno = ECANCELED;
      return false;
    }
    if (deadline_ != Clock::time_point::max() && Clock::now() >= deadline_) {
      errno = ETIMEDOUT;
      return false;
    }
    return true;
  }

  inline bool ready(int descriptor, short events) noexcept {
    for (;;) {
      std::array watches{
          pollfd{descriptor, events, 0},
          pollfd{process_.error(), POLLIN, 0},
          pollfd{cancellation_.descriptor(), POLLIN, 0},
      };
      const auto timeout = remainingMilliseconds();
      if (timeout == 0) {
        errno = ETIMEDOUT;
        return false;
      }
      const auto count = ::poll(watches.data(), watches.size(), timeout);
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count <= 0) {
        if (count == 0) {
          errno = ETIMEDOUT;
        }
        return false;
      }
      if (watches[2].revents != 0) {
        errno = ECANCELED;
        return false;
      }

      if (watches[1].revents != 0) {
        drainError();
      }
      if (watches[0].revents != 0) {
        return true;
      }
    }
  }

  inline void drainError() noexcept {
    std::array<char, error_chunk_bytes> bytes;
    std::size_t drained = 0;
    while (process_.error() >= 0 && drained < maximum_error_drain_bytes) {
      const auto count = ::read(process_.error(), bytes.data(), bytes.size());
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count <= 0) {
        if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) {
          process_.closeError();
        }
        return;
      }

      const auto received = static_cast<std::size_t>(count);
      const auto retained = std::min(received, Limits::stderr_bytes - error_.view().size());
      error_.append({bytes.data(), retained});
      drained += received;
    }
  }

  inline std::string_view retainedError() const noexcept { return error_.view(); }

private:
  using Clock = std::chrono::steady_clock;
  static constexpr std::size_t error_chunk_bytes = 1024;
  static constexpr std::size_t maximum_error_drain_bytes = 64 * 1024;

  inline int remainingMilliseconds() const noexcept {
    if (deadline_ == Clock::time_point::max()) {
      return -1;
    }
    const auto remaining = std::chrono::ceil<std::chrono::milliseconds>(deadline_ - Clock::now()).count();
    return static_cast<int>(std::clamp<decltype(remaining)>(remaining, 0, INT_MAX));
  }

  PipeProcess &process_;
  const CancellationSignal &cancellation_;
  Clock::time_point deadline_ = Clock::time_point::max();
  SensitiveText<Limits::stderr_bytes> error_;
};

}
}

// Interface: plugins/session.cppm
export {
namespace telar::runtime::plugins {

struct SessionOptions {
  const char *executable;
  const char *entry;
  const CancellationSignal &cancellation;
  std::chrono::milliseconds timeout = Limits::reply_deadline;
  const char *trace_path = nullptr;
  bool traffic = false;
};

template <Allocator Memory>
class Session {
public:
  inline explicit Session(Memory &memory, const SessionOptions &options)
      : memory_(memory), process_(spawn(options)), stream_(process_.output(), process_.input(), SessionIo{process_, options.cancellation}), channel_(stream_), timeout_(options.timeout), tracing_(options.trace_path != nullptr) {}

  inline ~Session() {
#if TELAR_DEBUG
    if (tracing_) {
      finishTrace();
    }
#endif
    process_.signal(SIGKILL);
    stream_.wait().drainError();
    const auto error = stream_.wait().retainedError();
    if (!error.empty()) {
      std::fputs("tap worker stderr: ", stderr);
      std::fwrite(error.data(), 1, error.size(), stderr);
      std::fputc('\n', stderr);
    }
  }

  Session(const Session &) = delete;
  Session &operator=(const Session &) = delete;

  inline OwnedResult<Memory> exchange(const ServiceSpec &specification, std::uint64_t event_id, std::span<const Byte> frame) {
    TELAR_TRACE("plugins.workerExchange");
    auto received = request(frame, Limits::effect_bytes);

    const auto bytes = received.bytes();
    if (bytes.front() == static_cast<Byte>(FrameKind::error)) {
      const auto failure = Protocol::decodeError(bytes);
      requireEvent(event_id, failure.event_id);
      return {nullptr, AllocationDeleter<Result<Memory>, Memory>{memory_}};
    }
    const auto reply = Protocol::decodeEffects(bytes);
    requireEvent(event_id, reply.event_id);
    return makeOwned<Result<Memory>>(memory_, specification, std::move(received), reply);
  }

  inline SensitiveAllocation<Memory> request(std::span<const Byte> frame, std::size_t maximum_bytes) {
    stream_.wait().deadline(timeout_);
    channel_.send(frame);
    stream_.wait().deadline(timeout_);
    auto received = channel_.receive(memory_, maximum_bytes);
    if (!received) { throw SystemError{"Tap worker closed", EPIPE}; }
    if (!stream_.wait().active()) { throw SystemError{"Tap worker request cancelled or expired"}; }
    return std::move(*received);
  }

  inline std::string_view retainedError() const noexcept { return stream_.wait().retainedError(); }
  inline pid_t processId() const noexcept { return process_.processId(); }
  inline int outputDescriptor() const noexcept { return process_.output(); }

private:
  inline static PipeProcess spawn(const SessionOptions &options) {
    std::array<char *, 8> arguments{const_cast<char *>(options.executable), const_cast<char *>("tap-worker"), const_cast<char *>(options.entry), nullptr};
    std::size_t count = 3;
    if (options.traffic) { arguments[count++] = const_cast<char *>("--traffic"); }
#if TELAR_DEBUG
    if (options.trace_path != nullptr) {
      arguments[count++] = const_cast<char *>("--trace");
      arguments[count++] = const_cast<char *>(options.trace_path);
    }
#endif
    std::array<char *, 1> environment{nullptr};
    return PipeProcess{SpawnSpec{.executable = options.executable, .cwd = "/", .arguments = arguments.data(), .environment = environment.data(), .size = {}}, ProcessInput::buffered_socket};
  }

  inline static void requireEvent(std::uint64_t expected, std::uint64_t received) {
    if (expected != received) {
      throw EncodingError{"Stale tap worker reply"};
    }
  }

#if TELAR_DEBUG
  inline void finishTrace() noexcept {
    process_.closeInput();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds{100};
    while (!process_.reap() && std::chrono::steady_clock::now() < deadline) {
      stream_.wait().drainError();
      std::this_thread::sleep_for(std::chrono::milliseconds{1});
    }
  }
#endif

  Memory &memory_;
  PipeProcess process_;
  PipeStream<SessionIo> stream_;
  FrameChannel<PipeStream<SessionIo>> channel_;
  std::chrono::milliseconds timeout_;
  [[maybe_unused]] bool tracing_;
};

}
}

// Interface: plugins/traffic_protocol.cppm
export {
namespace telar::runtime::plugins {

struct TrafficLimits {
  static constexpr std::size_t registrations = 32;
  static constexpr std::size_t decisions = 32;
  static constexpr std::size_t controls = 8;
  static constexpr std::size_t reply_bytes = 4 * 1024 * 1024;
};

enum class TrafficStage : Byte { observe, stream, http, control };

struct TrafficRegistration {
  std::uint32_t id = 0;
  TrafficStage stage = TrafficStage::observe;
  traffic::Selection selection = traffic::Selection::packets;
  FixedText<traffic::Limits::filter_bytes + 1> filter;
  FixedText<ProxyHostname::maximum_bytes + 1> host;
  Byte directions = 3;
  Byte visibility = 2;
  std::uint32_t timeout_ms = traffic::default_timeout_ms;
  bool fail_closed = false;
  FixedText<traffic::control::Limits::request_bytes> request;

  inline std::span<const Byte> requestBytes() const noexcept { const auto bytes = request.view(); return {reinterpret_cast<const Byte *>(bytes.data()), bytes.size()}; }

  inline traffic::InterceptionRule rule() const noexcept { return {host.view(), directions, visibility, timeout_ms, fail_closed, stage == TrafficStage::http}; }
};

struct TrafficDecision {
  std::uint32_t registration = 0;
  std::span<const Byte> payload;
};

struct TrafficReply {
  std::uint64_t event_id = 0;
  bool changed = false;
  std::array<TrafficRegistration, TrafficLimits::registrations> registrations;
  std::size_t registration_count = 0;
  std::array<TrafficDecision, TrafficLimits::decisions> decisions;
  std::size_t decision_count = 0;
  std::span<const Byte> effects;
};

struct TrafficEvent {
  std::uint64_t event_id;
  std::uint32_t registration;
  std::uint64_t dropped;
  traffic::Event event;
  std::span<const Byte> control;
  std::string_view error;
};

class TrafficProtocol {
public:
  inline static std::span<const Byte> setup(std::span<Byte> output, const ServiceSpec &specification) {
    FrameWriter writer{output};
    writer.tag(FrameKind::traffic_setup);
    writer.integer(specification.plugin_id);
    writer.bytes(specification.digest);
    writer.integer(specification.generation);
    writer.text(specification.name.view());
    writer.boolean(specification.allows(Capability::traffic_observe));
    writer.boolean(specification.allows(Capability::traffic_intercept));
    writer.boolean(specification.allows(Capability::traffic_control));
    writer.boolean(specification.allows(Capability::traffic_record));
    return writer.finish();
  }

  inline static ServiceSpec setup(std::span<const Byte> input) {
    FrameReader reader{input};
    reader.require(FrameKind::traffic_setup);
    ServiceSpec specification;
    specification.plugin_id = reader.integer<std::uint64_t>();
    const auto digest = reader.bytes();
    if (digest.size() != specification.digest.size()) { throw EncodingError{"Invalid traffic package digest"}; }
    std::ranges::copy(digest, specification.digest.begin());
    specification.generation = reader.integer<std::uint64_t>();
    specification.name.assign(reader.text());
    for (const auto capability : {Capability::traffic_observe, Capability::traffic_intercept, Capability::traffic_control, Capability::traffic_record}) {
      if (reader.boolean()) { specification.declared.insert(capability); specification.granted.insert(capability); }
    }
    reader.finish();
    if (specification.plugin_id == 0 || specification.generation == 0) { throw EncodingError{"Invalid traffic package identity"}; }
    return specification;
  }

  inline static std::span<const Byte> event(std::span<Byte> output, std::uint64_t event_id, std::uint32_t registration, std::span<const Byte> frame, std::uint64_t dropped = 0) {
    traffic::Protocol::decode(frame);
    FrameWriter writer{output};
    writer.tag(FrameKind::traffic_event);
    writer.integer(event_id);
    writer.integer(registration);
    writer.integer(dropped);
    writer.bytes(frame);
    return writer.finish();
  }

  inline static TrafficEvent event(std::span<const Byte> input) {
    FrameReader reader{input};
    const auto kind = reader.tag(FrameKind::traffic_control_event);
    if (kind != FrameKind::traffic_event && kind != FrameKind::traffic_control_event) { throw EncodingError{"Unexpected worker event"}; }
    TrafficEvent event{.event_id = reader.integer<std::uint64_t>(), .registration = reader.integer<std::uint32_t>(), .dropped = 0, .event = {}};
    if (kind == FrameKind::traffic_event) { event.dropped = reader.integer<std::uint64_t>(); event.event = traffic::Protocol::decode(reader.bytes()); }
    else {
      event.error = reader.text();
      event.control = reader.bytes();
      if (event.error.size() > 1024 || (event.error.empty() == event.control.empty())) { throw EncodingError{"Invalid worker control result"}; }
      if (!event.control.empty()) { traffic::control::Protocol::reply(event.control); }
    }
    reader.finish();
    return event;
  }

  inline static std::span<const Byte> controlEvent(std::span<Byte> output, std::uint64_t event_id, std::uint32_t registration, std::span<const Byte> frame, std::string_view error = {}) {
    FrameWriter writer{output};
    writer.tag(FrameKind::traffic_control_event);
    writer.integer(event_id);
    writer.integer(registration);
    writer.text(error);
    writer.bytes(frame);
    return writer.finish();
  }

  inline static std::span<const Byte> reply(std::span<Byte> output, const TrafficReply &reply) {
    if (reply.registration_count > reply.registrations.size() || reply.decision_count > reply.decisions.size() || (!reply.changed && reply.registration_count != 0)) { throw EncodingError{"Invalid traffic worker reply"}; }
    FrameWriter writer{output};
    writer.tag(FrameKind::traffic_reply);
    writer.integer(reply.event_id);
    writer.boolean(reply.changed);
    writer.integer(static_cast<Byte>(reply.registration_count));
    for (const auto &registration : std::span{reply.registrations}.first(reply.registration_count)) { write(writer, registration); }
    writer.integer(static_cast<Byte>(reply.decision_count));
    for (const auto &decision : std::span{reply.decisions}.first(reply.decision_count)) {
      writer.integer(decision.registration);
      writer.bytes(decision.payload);
    }
    writer.bytes(reply.effects);
    return writer.finish();
  }

  inline static TrafficReply reply(std::span<const Byte> input) {
    TrafficReply reply;
    readReply(input, reply);
    return reply;
  }

  inline static void readReply(std::span<const Byte> input, TrafficReply &reply) {
    if (input.size() > TrafficLimits::reply_bytes) { throw EncodingError{"Traffic worker reply exceeds its bound"}; }
    FrameReader reader{input};
    reader.require(FrameKind::traffic_reply);
    reply.event_id = reader.integer<std::uint64_t>();
    reply.changed = reader.boolean();
    reply.registration_count = reader.integer<Byte>();
    if (reply.registration_count > reply.registrations.size() || (!reply.changed && reply.registration_count != 0)) { throw EncodingError{"Invalid traffic registration count"}; }
    for (auto &registration : std::span{reply.registrations}.first(reply.registration_count)) { registration = read(reader); }
    reply.decision_count = reader.integer<Byte>();
    if (reply.decision_count > reply.decisions.size()) { throw EncodingError{"Invalid traffic decision count"}; }
    for (auto &decision : std::span{reply.decisions}.first(reply.decision_count)) {
      decision.registration = reader.integer<std::uint32_t>();
      decision.payload = reader.bytes();
    }
    reply.effects = reader.bytes();
    reader.finish();
  }

private:
  inline static void write(FrameWriter &writer, const TrafficRegistration &registration) {
    writer.integer(registration.id);
    writer.tag(registration.stage);
    writer.tag(registration.selection);
    writer.text(registration.filter.view());
    writer.text(registration.host.view());
    writer.integer(registration.directions);
    writer.integer(registration.visibility);
    writer.integer(registration.timeout_ms);
    writer.boolean(registration.fail_closed);
    writer.bytes(registration.requestBytes());
  }

  inline static TrafficRegistration read(FrameReader &reader) {
    TrafficRegistration registration;
    registration.id = reader.integer<std::uint32_t>();
    registration.stage = reader.tag(TrafficStage::control);
    registration.selection = reader.tag(traffic::Selection::all);
    registration.filter.assign(reader.text());
    registration.host.assign(reader.text());
    registration.directions = reader.integer<Byte>();
    registration.visibility = reader.integer<Byte>();
    registration.timeout_ms = reader.integer<std::uint32_t>();
    registration.fail_closed = reader.boolean();
    registration.request.assign(reader.text());
    if (registration.id == 0 || static_cast<Byte>(registration.selection) == 0 || registration.filter.view().contains('\0')) { throw EncodingError{"Invalid traffic registration"}; }
    if (registration.stage == TrafficStage::control) { traffic::control::Protocol::request(registration.requestBytes()); }
    else if (!registration.request.view().empty()) { throw EncodingError{"Only control registrations carry requests"}; }
    if ((registration.stage == TrafficStage::stream || registration.stage == TrafficStage::http) && (!registration.filter.view().empty() || !ProxyHostname::validPattern(registration.host.view()) || registration.directions == 0 || registration.directions > 3 || registration.visibility == 0 || registration.visibility > 3 || registration.timeout_ms == 0 || registration.timeout_ms > traffic::maximum_timeout_ms)) { throw EncodingError{"Invalid worker interception rule"}; }
    return registration;
  }
};

}
}

// Interface: plugins/traffic_bridge.cppm
export {
namespace telar::runtime::plugins {

template <ConcurrentAllocator Memory>
class TrafficBridge {
  using Secure = ErasingAllocator<Memory>;
  struct Connection {
    inline explicit Connection(Secure &memory, TrafficRegistration registration, traffic::PackageChannel channel)
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
  inline explicit TrafficBridge(Memory &memory, const ServiceSpec &specification, traffic::PackagePort &port, Session<Memory> &session)
      : memory_(memory), secure_(memory), specification_(specification), port_(port), reply_(makeOwned<TrafficReply>(memory)) {
    attach(session);
  }

  inline void attach(Session<Memory> &session) {
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

  inline void detach() noexcept {
    session_ = nullptr;
    for (auto &connection : connections_) {
      if (connection && connection->registration.stage == TrafficStage::control) { connection.reset(); }
      else if (connection) { port_.setPackageAvailable(connection->owner, false); connection->notify_ready = false; }
    }
  }

  inline std::uint64_t errors() const noexcept { return errors_; }
  inline bool transportFailed() const noexcept { return transport_failed_; }

  template <typename Consumer>
  inline void step(int wake, const CancellationSignal &cancellation, Consumer &&consume, bool immediate = false) {
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
  inline void dispatchControl(std::optional<Connection> &connection, std::span<const Byte> frame, std::string_view error, Consumer &&consume) {
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
  inline void publishEffects(std::uint64_t event_id, SensitiveAllocation<Memory> response, Consumer &&consume) {
    if (reply_->effects.empty()) { return; }
    const auto effects = Protocol::decodeEffects(reply_->effects);
    if (effects.event_id != event_id) { throw EncodingError{"Stale traffic notification"}; }
    if (effects.batch.count != 0) { consume(std::move(response), effects); }
  }

  template <typename Consumer>
  inline void dispatch(Connection &connection, std::span<const Byte> frame, std::uint64_t dropped, Consumer &&consume) {
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

  inline static void fail(Connection &connection, const traffic::FlowEvent &flow) {
    std::array<Byte, 32> decision;
    enqueue(connection, traffic::InterceptionCodec::decision(decision, flow.ticket, connection.registration.fail_closed ? traffic::Verdict::reject : traffic::Verdict::allow));
  }

  inline Connection *find(std::uint32_t id) noexcept {
    for (auto &connection : connections_) { if (connection && connection->registration.id == id) { return &*connection; } }
    return nullptr;
  }

  inline void apply(std::uint64_t event_id, std::span<const Byte> input) {
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

  inline static void enqueue(Connection &connection, std::span<const Byte> frame) {
    connection.output.append(traffic::Protocol::prefix(frame.size()));
    connection.output.append(frame);
  }

  inline static void write(Connection &connection) {
    const auto bytes = connection.output.readable();
    const auto count = ::send(connection.socket.get(), bytes.data(), bytes.size(), 0);
    if (count < 0 && socketWouldBlock(errno)) { return; }
    if (count <= 0) { throw SystemError{"Write package traffic", EPIPE}; }
    connection.output.consume(static_cast<std::size_t>(count));
  }

  inline std::optional<SensitiveAllocation<Memory>> read(Connection &connection) {
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
}

// Interface: plugins/worker.cppm
export {
namespace telar::runtime::plugins {

struct WorkerLaunch {
  const char *executable;
  CancellationSignal &cancellation;
  std::chrono::milliseconds timeout = Limits::reply_deadline;
  std::string_view trace_prefix{};
  traffic::PackagePort *traffic = nullptr;
};

struct WorkerMetrics {
  std::uint64_t dropped = 0;
  std::uint64_t timeouts = 0;
  bool disabled = false;
  std::uint64_t callback_errors = 0;
};

template <typename Clock>
concept WorkerClock = requires {
  { Clock::now() } noexcept -> std::same_as<typename Clock::time_point>;
};

template <ConcurrentAllocator Memory, WorkerClock Clock = std::chrono::steady_clock>
class Worker {
public:
  using Shared = std::shared_ptr<SharedExchange<Memory>>;

  inline explicit Worker(Memory &memory, const ServiceSpec &specification, ResultQueue<Memory> &results, TapBudget &budget, WorkerLaunch launch)
      : memory_(memory), specification_(bindPermissions(memory, specification)), results_(results), budget_(budget), launch_(launch), entry_(specification.entry.view(), AllocatorRef<char, Memory>{memory}), trace_path_(AllocatorRef<char, Memory>{memory}), thread_([this] { run(); }) {}

  inline ~Worker() { stop(); }

  inline void stop() noexcept {
    cancellation_.request();
    requests_.close();
    if (thread_.joinable()) {
      thread_.join();
    }
    bridge_.reset();
    session_.reset();
  }

  inline void revoke() noexcept {
    specification_.permission->store(false, std::memory_order_release);
    if (revoked_.exchange(true, std::memory_order_acq_rel)) { return; }
    disabled_.store(true, std::memory_order_relaxed);
    cancellation_.request();
    requests_.close();
    if (launch_.traffic) { launch_.traffic->revokePackage(specification_); }
  }

  inline bool revoked() const noexcept { return revoked_.load(std::memory_order_acquire); }

  inline void submit(Shared exchange) noexcept {
    if (specification_.allows(Capability::proxy_tap) && !disabled_.load(std::memory_order_relaxed)) {
      requests_.publish(std::move(exchange));
      wake_.notify();
    }
  }

  inline WorkerMetrics metrics() const noexcept {
    return {requests_.metrics().dropped, timeouts_.load(std::memory_order_relaxed), disabled_.load(std::memory_order_relaxed), callback_errors_.load(std::memory_order_relaxed)};
  }

  inline const ServiceSpec &specification() const noexcept { return specification_; }

private:
  inline static ServiceSpec bindPermissions(Memory &memory, const ServiceSpec &specification) {
    auto bound = specification;
    if (!bound.permission) { bound.permission = std::allocate_shared<std::atomic<bool>>(AllocatorRef<std::atomic<bool>, Memory>{memory}, true); }
    return bound;
  }

  inline void run() noexcept {
    if (launch_.traffic && specification_.traffic()) {
      runTraffic();
    } else {
      while (auto request = requests_.receive()) {
        if (!disabled_.load(std::memory_order_relaxed)) {
          process(**request);
        }
      }
    }

    if (revoked() || cancellation_.requested() || launch_.cancellation.requested()) {
      bridge_.reset();
      session_.reset();
    }
  }

  inline void runTraffic() noexcept {
    while (!launch_.cancellation.requested() && !cancellation_.requested()) {
      if (disabled_.load(std::memory_order_relaxed)) {
        std::array watches{pollfd{cancellation_.descriptor(), POLLIN, 0}, pollfd{launch_.cancellation.descriptor(), POLLIN, 0}};
        if (::poll(watches.data(), watches.size(), -1) < 0 && errno != EINTR) { return; }
        continue;
      }
      try {
        if (!session_) {
          prepareTrace();
          session_.emplace(memory_, SessionOptions{.executable = launch_.executable, .entry = entry_.c_str(), .cancellation = cancellation_, .timeout = launch_.timeout, .trace_path = trace_path_.empty() ? nullptr : trace_path_.c_str(), .traffic = true});
          if (bridge_) { bridge_->attach(*session_); }
          else { bridge_ = makeOwned<TrafficBridge<Memory>>(memory_, memory_, specification_, *launch_.traffic, *session_); }
        }
        wake_.drain();
        if (auto request = requests_.tryReceive()) { process(**request); }
        if (!bridge_) { continue; }
        bridge_->step(wake_.descriptor(), cancellation_, [&](SensitiveAllocation<Memory> storage, EffectReply reply) {
          results_.publish(makeOwned<Result<Memory>>(memory_, specification_, std::move(storage), reply, true));
        }, requests_.metrics().queued != 0);
        callback_errors_.store(callback_errors_base_ + bridge_->errors(), std::memory_order_relaxed);
      } catch (const SystemError &error) {
        if (error.code() == ECANCELED) { return; }
        if (error.code() == ETIMEDOUT) { timeouts_.fetch_add(1, std::memory_order_relaxed); }
        restart();
      } catch (...) { restart(); }
    }
  }

  inline void process(const SharedExchange<Memory> &shared) noexcept {
    TELAR_TRACE("plugins.processExchange");
    try {
      if (!session_) {
        prepareTrace();
        session_.emplace(memory_, SessionOptions{.executable = launch_.executable, .entry = entry_.c_str(), .cancellation = cancellation_, .timeout = launch_.timeout, .trace_path = trace_path_.empty() ? nullptr : trace_path_.c_str()});
      }
    } catch (...) {
      restart();
      return;
    }

    try {
      const auto size = SharedExchange<Memory>::capturedBytes(shared.exchange) + Limits::frame_overhead;
      auto charged = budget_.charge(size);
      if (!charged) {
        return;
      }
      const auto encoded_size = Protocol::exchangeBytes(shared.exchange);
      if (encoded_size > size) {
        return;
      }
      SensitiveAllocation frame{memory_, encoded_size};
      const auto payload = Protocol::encodeExchange(frame.bytes(), {shared.event_id, specification_.generation}, shared.exchange);
      exchange(shared.event_id, payload);
    } catch (...) {
    }
  }

  inline void exchange(std::uint64_t event_id, std::span<const Byte> payload) noexcept {
    try {
      auto result = session_->exchange(specification_, event_id, payload);
      if (result) {
        results_.publish(std::move(result));
      }
    } catch (const SystemError &error) {
      if (error.code() == ECANCELED) {
        return;
      }
      if (error.code() == ETIMEDOUT) {
        timeouts_.fetch_add(1, std::memory_order_relaxed);
      }
      restart();
    } catch (...) {
      restart();
    }
  }

  inline void restart() noexcept {
    if (bridge_) {
      bridge_->detach();
      if (bridge_->transportFailed()) { callback_errors_base_ += bridge_->errors(); bridge_.reset(); }
    }
    session_.reset();
    const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch());
    if (restarts_.record(now)) {
      disabled_.store(true, std::memory_order_relaxed);
    }
  }

  inline void prepareTrace() {
#if TELAR_DEBUG
    if (launch_.trace_prefix.empty()) {
      return;
    }
    std::array<char, 64> suffix;
    const auto length = std::snprintf(suffix.data(), suffix.size(), ".tap-%u-%llu.json", static_cast<unsigned>(specification_.package_index), static_cast<unsigned long long>(session_number_++));
    trace_path_ = launch_.trace_prefix;
    trace_path_.append(suffix.data(), static_cast<std::size_t>(length));
#endif
  }

  Memory &memory_;
  ServiceSpec specification_;
  ResultQueue<Memory> &results_;
  TapBudget &budget_;
  WorkerLaunch launch_;
  String<Memory> entry_;
  String<Memory> trace_path_;
  [[maybe_unused]] std::uint64_t session_number_ = 0;
  DropChannel<Shared, Limits::queue_depth, ChannelPolicy::keep_newest> requests_;
  CancellationSignal cancellation_;
  std::optional<Session<Memory>> session_;
  Owned<TrafficBridge<Memory>, Memory> bridge_{nullptr, AllocationDeleter<TrafficBridge<Memory>, Memory>{memory_}};
  CompletionSignal wake_;
  std::uint64_t callback_errors_base_ = 0;
  RestartWindow restarts_;
  std::atomic<std::uint64_t> timeouts_{0};
  std::atomic<bool> disabled_{false};
  std::atomic<bool> revoked_{false};
  std::atomic<std::uint64_t> callback_errors_{0};
  std::jthread thread_;
};

}
}
