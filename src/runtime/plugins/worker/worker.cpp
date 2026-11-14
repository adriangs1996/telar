module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.plugins.worker;

import telar.sys.socket;
import telar.sys.process;

namespace telar::runtime::plugins {

  template <Allocator Memory>
  Result<Memory>::Result(const ServiceSpec& specification, tbc::view<SensitiveAllocation<Memory>, tbc::lt::a> storage, std::size_t effects_offset, std::size_t effects_size, bool traffic)
      : package_index(specification.package_index),
        plugin_id(specification.plugin_id),
        digest(specification.digest),
        generation(specification.generation),
        storage(std::move(storage)),
        traffic(traffic),
        effects_offset_(effects_offset),
        effects_size_(effects_size) {
    const auto effects = Protocol::decodeEffects(effectBytes());

    event_id = effects.event_id;
    batch_count = effects.batch.count;
  }

  template <Allocator Memory>
  EffectBatch Result<Memory>::batch() const {
    return Protocol::decodeEffects(effectBytes()).batch;
  }

  template <Allocator Memory>
  bool Result<Memory>::authorized(const ServiceSpec& specification) const noexcept {
    const bool source = traffic ? specification.traffic() : specification.allows(Capability::proxy_tap);

    return package_index == specification.package_index && plugin_id == specification.plugin_id && digest == specification.digest && generation == specification.generation && source && (batch_count == 0 || specification.allows(Capability::notifications));
  }

  template <Allocator Memory>
  std::span<const Byte> Result<Memory>::effectBytes() const {
    return storage.bytes().subspan(effects_offset_, effects_size_);
  }

  template <Allocator Memory>
  void ResultQueue<Memory>::activate() {
    ready_.emplace();
  }

  template <Allocator Memory>
  void ResultQueue<Memory>::publish(tbc::view<OwnedResult<Memory>, tbc::lt::a> result) noexcept {
    if (results_.publish(std::move(result))) {
      ready_->notify();
    }
  }

  template <Allocator Memory>
  void ResultQueue<Memory>::close() noexcept {
    results_.close();
  }

  template <Allocator Memory>
  int ResultQueue<Memory>::descriptor() const noexcept {
    return ready_ ? ready_->descriptor() : -1;
  }

  SessionIo::SessionIo(PipeProcess& process, const CancellationSignal& cancellation) noexcept
      : process_(process),
        cancellation_(cancellation) {}

  void SessionIo::deadline(std::chrono::milliseconds timeout) noexcept {
    deadline_ = Clock::now() + timeout;
  }

  bool SessionIo::active() const noexcept {
    if (cancellation_.requested()) {
      sys::setLastError(ECANCELED);
      return false;
    }

    if (deadline_ != Clock::time_point::max() && Clock::now() >= deadline_) {
      sys::setLastError(ETIMEDOUT);
      return false;
    }

    return true;
  }

  bool SessionIo::ready(int descriptor, short events) noexcept {
    for (;;) {
      std::array watches{
          pollfd{descriptor, events, 0},
          pollfd{process_.error(), POLLIN, 0},
          pollfd{cancellation_.descriptor(), POLLIN, 0},
      };

      const auto timeout = remainingMilliseconds();
      if (timeout == 0) {
        sys::setLastError(ETIMEDOUT);
        return false;
      }

      const auto count = ::poll(watches.data(), watches.size(), timeout);
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count <= 0) {
        if (count == 0) {
          sys::setLastError(ETIMEDOUT);
        }

        return false;
      }

      if (watches[2].revents != 0) {
        sys::setLastError(ECANCELED);
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

  void SessionIo::drainError() noexcept {
    std::array<char, error_chunk_bytes> bytes;
    std::size_t drained = 0;

    while (process_.error() >= 0 && drained < maximum_error_drain_bytes) {
      const auto count = ::read(process_.error(), bytes.data(), bytes.size());
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count <= 0) {
        if (count == 0 || (sys::lastError() != EAGAIN && sys::lastError() != EWOULDBLOCK)) {
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

  std::string_view SessionIo::retainedError() const noexcept {
    return error_.view();
  }

  int SessionIo::remainingMilliseconds() const noexcept {
    if (deadline_ == Clock::time_point::max()) {
      return -1;
    }

    const auto remaining = std::chrono::ceil<std::chrono::milliseconds>(deadline_ - Clock::now()).count();

    return static_cast<int>(std::clamp<decltype(remaining)>(remaining, 0, std::numeric_limits<int>::max()));
  }

  TapWorkerOptions TapWorkerOptions::parse(std::span<char* const> words) {
    if (words.empty()) {
      throw std::invalid_argument{"Expected tap-worker ENTRY [--traffic] [--trace PATH]"};
    }

    TapWorkerOptions options{.entry = words.front()};

    for (std::size_t index = 1; index < words.size(); ++index) {
      const std::string_view option{words[index]};
      if (option == "--traffic" && !options.traffic) {
        options.traffic = true;
      } else if (option == "--trace" && options.trace_path == nullptr && index + 1 < words.size()) {
        options.trace_path = words[++index];
      } else {
        throw std::invalid_argument{"Expected tap-worker ENTRY [--traffic] [--trace PATH]"};
      }
    }

    return options;
  }

  tbc::view<std::array<char*, 7>, tbc::lt::a> TapWorkerOptions::arguments(tbc::view<const TapWorkerOptions&, tbc::lt::a> options, tbc::view<const char*, tbc::lt::a> executable) noexcept {
    std::array<char*, 7> words{const_cast<char*>(executable), const_cast<char*>(command.data()), const_cast<char*>(options.entry)};
    std::size_t count = 3;

    if (options.traffic) {
      words[count++] = const_cast<char*>("--traffic");
    }

#if TELAR_DEBUG
    if (options.trace_path != nullptr) {
      words[count++] = const_cast<char*>("--trace");
      words[count++] = const_cast<char*>(options.trace_path);
    }

#endif
    words[count] = nullptr;
    return words;
  }

  template <Allocator Memory>
  Session<Memory>::Session(Memory& memory, const SessionOptions& options)
      : memory_(memory),
        process_(spawn(options)),
        stream_(process_.output(), process_.input(), SessionIo{process_, options.cancellation}),
        channel_(stream_),
        timeout_(options.timeout),
        tracing_(options.trace_path != nullptr) {}

  template <Allocator Memory>
  Session<Memory>::~Session() {
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

  template <Allocator Memory>
  OwnedResult<Memory> Session<Memory>::exchange(const ServiceSpec& specification, std::uint64_t event_id, std::span<const Byte> frame) {
    TELAR_TRACE("plugins.workerExchange");
    auto received = request(frame, Limits::effect_bytes);

    if (received.bytes().front() == static_cast<Byte>(FrameKind::error)) {
      const auto failure = Protocol::decodeError(received.bytes());

      requireEvent(event_id, failure.event_id);
      return {nullptr, AllocationDeleter<Result<Memory>, Memory>{memory_}};
    }

    const auto size = received.bytes().size();
    auto result = makeOwned<Result<Memory>>(memory_, specification, std::move(received), 0, size);

    requireEvent(event_id, result->event_id);
    return result;
  }

  template <Allocator Memory>
  SensitiveAllocation<Memory> Session<Memory>::request(std::span<const Byte> frame, std::size_t maximum_bytes) {
    stream_.wait().deadline(timeout_);
    channel_.send(frame);
    stream_.wait().deadline(timeout_);
    auto received = channel_.receive(memory_, maximum_bytes);
    if (!received) {
      throw SystemError{"Tap worker closed", EPIPE};
    }

    if (!stream_.wait().active()) {
      throw SystemError{"Tap worker request cancelled or expired"};
    }

    return std::move(*received);
  }

  template <Allocator Memory>
  std::string_view Session<Memory>::retainedError() const noexcept {
    return stream_.wait().retainedError();
  }

  template <Allocator Memory>
  pid_t Session<Memory>::processId() const noexcept {
    return process_.processId();
  }

  template <Allocator Memory>
  int Session<Memory>::outputDescriptor() const noexcept {
    return process_.output();
  }

  template <Allocator Memory>
  PipeProcess Session<Memory>::spawn(const SessionOptions& options) {
    const TapWorkerOptions worker{.entry = options.entry, .traffic = options.traffic, .trace_path = options.trace_path};
    auto arguments = TapWorkerOptions::arguments(worker, options.executable);
    std::array<char*, 1> environment{nullptr};

    return PipeProcess{SpawnSpec{.executable = options.executable, .cwd = "/", .arguments = arguments.data(), .environment = environment.data(), .size = {}}, ProcessInput::buffered_socket};
  }

  template <Allocator Memory>
  void Session<Memory>::requireEvent(std::uint64_t expected, std::uint64_t received) {
    if (expected != received) {
      throw EncodingError{"Stale tap worker reply"};
    }
  }

#if TELAR_DEBUG

  template <Allocator Memory>
  void Session<Memory>::finishTrace() noexcept {
    process_.closeInput();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds{100};

    while (!process_.reap() && std::chrono::steady_clock::now() < deadline) {
      stream_.wait().drainError();
      std::this_thread::sleep_for(std::chrono::milliseconds{1});
    }
  }
#endif

  std::span<const Byte> TrafficRegistration::requestBytes() const noexcept {
    const auto bytes = request.view();

    return {reinterpret_cast<const Byte*>(bytes.data()), bytes.size()};
  }

  traffic::InterceptionRule TrafficRegistration::rule() const noexcept {
    return {host.view(), directions, visibility, timeout_ms, fail_closed, stage == TrafficStage::http};
  }

  tbc::view<std::span<const Byte>, tbc::lt::a> TrafficProtocol::setup(tbc::view<std::span<Byte>, tbc::lt::a> output, const ServiceSpec& specification) {
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

  ServiceSpec TrafficProtocol::setup(std::span<const Byte> input) {
    FrameReader reader{input};

    reader.require(FrameKind::traffic_setup);
    ServiceSpec specification;

    specification.plugin_id = reader.integer<std::uint64_t>();
    const auto digest = reader.bytes();
    if (digest.size() != specification.digest.size()) {
      throw EncodingError{"Invalid traffic package digest"};
    }

    std::ranges::copy(digest, specification.digest.begin());
    specification.generation = reader.integer<std::uint64_t>();
    specification.name.assign(reader.text());
    for (const auto capability : {Capability::traffic_observe, Capability::traffic_intercept, Capability::traffic_control, Capability::traffic_record}) {
      if (reader.boolean()) {
        specification.declared.insert(capability);
        specification.granted.insert(capability);
      }
    }

    reader.finish();
    if (specification.plugin_id == 0 || specification.generation == 0) {
      throw EncodingError{"Invalid traffic package identity"};
    }

    return specification;
  }

  tbc::view<std::span<const Byte>, tbc::lt::a> TrafficProtocol::event(tbc::view<std::span<Byte>, tbc::lt::a> output, std::uint64_t event_id, std::uint32_t registration, std::span<const Byte> frame, std::uint64_t dropped) {
    traffic::Protocol::decode(frame);
    FrameWriter writer{output};

    writer.tag(FrameKind::traffic_event);
    writer.integer(event_id);
    writer.integer(registration);
    writer.integer(dropped);
    writer.bytes(frame);
    return writer.finish();
  }

  TrafficEvent TrafficProtocol::event(std::span<const Byte> input) {
    FrameReader reader{input};
    const auto kind = reader.tag(FrameKind::traffic_control_event);
    if (kind != FrameKind::traffic_event && kind != FrameKind::traffic_control_event) {
      throw EncodingError{"Unexpected worker event"};
    }

    TrafficEvent event{.event_id = reader.integer<std::uint64_t>(), .registration = reader.integer<std::uint32_t>(), .dropped = 0, .event = {}};

    if (kind == FrameKind::traffic_event) {
      event.dropped = reader.integer<std::uint64_t>();
      event.event = traffic::Protocol::decode(reader.bytes());
    } else {
      event.error = reader.text();
      event.control = reader.bytes();
      if (event.error.size() > 1024 || (event.error.empty() == event.control.empty())) {
        throw EncodingError{"Invalid worker control result"};
      }

      if (!event.control.empty()) {
        traffic::control::Protocol::reply(event.control);
      }
    }

    reader.finish();
    return event;
  }

  tbc::view<std::span<const Byte>, tbc::lt::a> TrafficProtocol::controlEvent(tbc::view<std::span<Byte>, tbc::lt::a> output, std::uint64_t event_id, std::uint32_t registration, std::span<const Byte> frame, std::string_view error) {
    FrameWriter writer{output};

    writer.tag(FrameKind::traffic_control_event);
    writer.integer(event_id);
    writer.integer(registration);
    writer.text(error);
    writer.bytes(frame);
    return writer.finish();
  }

  tbc::view<std::span<const Byte>, tbc::lt::a> TrafficProtocol::reply(tbc::view<std::span<Byte>, tbc::lt::a> output, const TrafficReply& reply, const TrafficOutcome& outcome) {
    if (reply.registration_count > reply.registrations.size() || outcome.decision_count > outcome.decisions.size() || (!reply.changed && reply.registration_count != 0)) {
      throw EncodingError{"Invalid traffic worker reply"};
    }

    FrameWriter writer{output};

    writer.tag(FrameKind::traffic_reply);
    writer.integer(reply.event_id);
    writer.boolean(reply.changed);
    writer.integer(static_cast<Byte>(reply.registration_count));
    for (const auto& registration : std::span{reply.registrations}.first(reply.registration_count)) {
      write(writer, registration);
    }

    writer.integer(static_cast<Byte>(outcome.decision_count));
    for (const auto& decision : std::span{outcome.decisions}.first(outcome.decision_count)) {
      writer.integer(decision.registration);
      writer.bytes(decision.payload);
    }

    writer.bytes(outcome.effects);
    return writer.finish();
  }

  TrafficReply TrafficProtocol::reply(std::span<const Byte> input) {
    TrafficReply reply;

    readReply(input, reply);
    return reply;
  }

  tbc::view<TrafficOutcome, tbc::lt::a> TrafficProtocol::readReply(tbc::view<std::span<const Byte>, tbc::lt::a> input, TrafficReply& reply) {
    if (input.size() > TrafficLimits::reply_bytes) {
      throw EncodingError{"Traffic worker reply exceeds its bound"};
    }

    FrameReader reader{input};

    reader.require(FrameKind::traffic_reply);
    reply.event_id = reader.integer<std::uint64_t>();
    reply.changed = reader.boolean();
    reply.registration_count = reader.integer<Byte>();
    if (reply.registration_count > reply.registrations.size() || (!reply.changed && reply.registration_count != 0)) {
      throw EncodingError{"Invalid traffic registration count"};
    }

    for (auto& registration : std::span{reply.registrations}.first(reply.registration_count)) {
      registration = read(reader);
    }

    TrafficOutcome outcome;

    outcome.decision_count = reader.integer<Byte>();
    if (outcome.decision_count > outcome.decisions.size()) {
      throw EncodingError{"Invalid traffic decision count"};
    }

    for (auto& decision : std::span{outcome.decisions}.first(outcome.decision_count)) {
      decision.registration = reader.integer<std::uint32_t>();
      decision.payload = reader.bytes();
    }

    outcome.effects = reader.bytes();
    reader.finish();
    return outcome;
  }

  void TrafficProtocol::write(FrameWriter& writer, const TrafficRegistration& registration) {
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

  TrafficRegistration TrafficProtocol::read(FrameReader& reader) {
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
    if (registration.id == 0 || static_cast<Byte>(registration.selection) == 0 || registration.filter.view().contains('\0')) {
      throw EncodingError{"Invalid traffic registration"};
    }

    if (registration.stage == TrafficStage::control) {
      traffic::control::Protocol::request(registration.requestBytes());
    } else if (!registration.request.view().empty()) {
      throw EncodingError{"Only control registrations carry requests"};
    }

    if ((registration.stage == TrafficStage::stream || registration.stage == TrafficStage::http) && (!registration.filter.view().empty() || !ProxyHostname::validPattern(registration.host.view()) || registration.directions == 0 || registration.directions > 3 || registration.visibility == 0 || registration.visibility > 3 || registration.timeout_ms == 0 || registration.timeout_ms > traffic::maximum_timeout_ms)) {
      throw EncodingError{"Invalid worker interception rule"};
    }

    return registration;
  }

  TrafficBridge::Connection::Connection(tbc::view<Secure&, tbc::lt::a> memory, TrafficRegistration registration, traffic::PackageChannel channel)
      : registration(std::move(registration)),
        socket(std::move(channel.socket)),
        owner(channel.owner),
        output(memory, 2 * traffic::Limits::http_frame_bytes),
        registration_ack(this->registration.stage == TrafficStage::stream || this->registration.stage == TrafficStage::http) {}

  TrafficBridge::TrafficBridge(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, const ServiceSpec& specification, tbc::view<traffic::PackagePort&, tbc::lt::a> port)
      : memory_(memory),
        secure_(memory),
        specification_(specification),
        port_(port),
        reply_(makeOwned<TrafficReply>(memory)) {}

  void TrafficBridge::attach(Session<ConcurrentMemory>& session) {
    std::array<Byte, 1024> output;
    auto initialized = session.request(TrafficProtocol::setup(output, specification_), TrafficLimits::reply_bytes);

    apply(0, initialized.bytes());
    for (auto& connection : connections_) {
      if (connection && connection->registration.stage != TrafficStage::control) {
        port_.setPackageAvailable(connection->owner, true);
        connection->notify_ready = connection->ready;
      }
    }
  }

  void TrafficBridge::detach() noexcept {
    for (auto& connection : connections_) {
      if (connection && connection->registration.stage == TrafficStage::control) {
        connection.reset();
      } else if (connection) {
        port_.setPackageAvailable(connection->owner, false);
        connection->notify_ready = false;
      }
    }
  }

  std::uint64_t TrafficBridge::errors() const noexcept {
    return errors_;
  }

  bool TrafficBridge::transportFailed() const noexcept {
    return transport_failed_;
  }

  void TrafficBridge::fail(Connection& connection, const traffic::FlowEvent& flow) {
    std::array<Byte, 32> decision;

    enqueue(connection, traffic::InterceptionCodec::decision(decision, flow.ticket, connection.registration.fail_closed ? traffic::Verdict::reject : traffic::Verdict::allow));
  }

  auto TrafficBridge::find(std::uint32_t id) noexcept -> Connection* {
    for (auto& connection : connections_) {
      if (connection && connection->registration.id == id) {
        return &*connection;
      }
    }

    return nullptr;
  }

  tbc::view<TrafficOutcome, tbc::lt::a> TrafficBridge::apply(std::uint64_t event_id, tbc::view<std::span<const Byte>, tbc::lt::a> input) {
    const auto outcome = TrafficProtocol::readReply(input, *reply_);

    if (reply_->event_id != event_id) {
      throw EncodingError{"Stale traffic worker reply"};
    }

    const auto registrations = std::span{reply_->registrations}.first(reply_->registration_count);

    if (reply_->changed) {
      std::size_t controls = 0;

      for (std::size_t index = 0; index < registrations.size(); ++index) {
        const auto& registration = registrations[index];
        if (registration.stage == TrafficStage::control) {
          if (++controls > TrafficLimits::controls || !traffic::control::authorized(specification_, traffic::control::Protocol::request(registration.requestBytes()))) {
            throw EncodingError{"Package control capability denied"};
          }
        } else if (!specification_.allows(registration.stage == TrafficStage::observe ? Capability::traffic_observe : Capability::traffic_intercept)) {
          throw EncodingError{"Package traffic capability denied"};
        }

        if (std::ranges::any_of(registrations.first(index), [&](const auto& other) {
              return other.id == registration.id;
            })) {
          throw EncodingError{"Duplicate traffic registration"};
        }
      }

      for (auto& connection : connections_) {
        if (connection && !std::ranges::any_of(registrations, [&](const auto& registration) {
              return registration.id == connection->registration.id;
            })) {
          connection.reset();
        }
      }

      for (const auto& registration : registrations) {
        if (auto* existing = find(registration.id)) {
          const auto& before = existing->registration;
          if (before != registration) {
            throw EncodingError{"Traffic registrations are immutable"};
          }

          continue;
        }

        for (auto& connection : connections_) {
          if (connection) {
            continue;
          }

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

    for (const auto& decision : std::span{outcome.decisions}.first(outcome.decision_count)) {
      auto* connection = find(decision.registration);
      if (!connection) {
        continue;
      }

      if (connection->registration.stage != TrafficStage::stream && connection->registration.stage != TrafficStage::http) {
        throw EncodingError{"Only interceptors can decide traffic"};
      }

      FrameReader reader{decision.payload};

      reader.require(traffic::InterceptionCodec::Command::decision);
      reader.integer<std::uint64_t>();
      const auto verdict = reader.tag(traffic::Verdict::reject);
      const auto bytes = reader.bytes();

      reader.finish();
      if (verdict == traffic::Verdict::pending || (verdict != traffic::Verdict::replace && !bytes.empty())) {
        throw EncodingError{"Invalid worker decision"};
      }

      if (connection->registration.stage == TrafficStage::http && verdict == traffic::Verdict::replace) {
        HttpMessageCodec::decode(bytes);
      } else if (bytes.size() > traffic::FlowControl::chunk_bytes) {
        throw EncodingError{"Worker stream decision exceeds its bound"};
      }

      enqueue(*connection, decision.payload);
    }

    return outcome;
  }

  void TrafficBridge::enqueue(Connection& connection, std::span<const Byte> frame) {
    connection.output.append(traffic::Protocol::prefix(frame.size()));
    connection.output.append(frame);
  }

  void TrafficBridge::write(Connection& connection) {
    const auto bytes = connection.output.readable();
    const auto count = ::send(connection.socket.get(), bytes.data(), bytes.size(), 0);
    if (count < 0 && socketWouldBlock(sys::lastError())) {
      return;
    }

    if (count <= 0) {
      throw SystemError{"Write package traffic", EPIPE};
    }

    connection.output.consume(static_cast<std::size_t>(count));
  }

  tbc::view<std::optional<SensitiveAllocation<ConcurrentMemory>>, tbc::lt::a> TrafficBridge::read(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, Connection& connection) {
    if (!connection.input) {
      const auto prefix_bytes = connection.registration.stage == TrafficStage::control ? traffic::control::Protocol::prefix_bytes : traffic::Protocol::prefix_bytes;
      const auto count = ::recv(connection.socket.get(), connection.prefix.data() + connection.prefix_bytes, prefix_bytes - connection.prefix_bytes, 0);
      if (count < 0 && socketWouldBlock(sys::lastError())) {
        return std::nullopt;
      }

      if (count <= 0) {
        throw SystemError{"Read package traffic prefix", EPIPE};
      }

      connection.prefix_bytes += static_cast<std::size_t>(count);
      if (connection.prefix_bytes != prefix_bytes) {
        return std::nullopt;
      }

      FrameReader prefix{std::span<const Byte>{connection.prefix}.first(prefix_bytes)};
      const auto size = prefix.integer<std::uint32_t>();

      if (connection.registration.stage != TrafficStage::control) {
        connection.dropped = prefix.integer<std::uint64_t>();
      }

      const auto maximum = connection.registration.stage == TrafficStage::control ? traffic::control::Limits::reply_bytes : connection.registration.stage == TrafficStage::http ? traffic::Limits::http_frame_bytes
                                                                                                                                                                                : traffic::Limits::frame_bytes;
      if (size == 0 || size > maximum) {
        throw EncodingError{"Invalid package traffic frame size"};
      }

      connection.input.emplace(memory, size);
      connection.received = 0;
    }

    const auto bytes = connection.input->bytes();
    const auto count = ::recv(connection.socket.get(), bytes.data() + connection.received, bytes.size() - connection.received, 0);
    if (count < 0 && socketWouldBlock(sys::lastError())) {
      return std::nullopt;
    }

    if (count <= 0) {
      throw SystemError{"Read package traffic frame", EPIPE};
    }

    connection.received += static_cast<std::size_t>(count);
    if (connection.received != bytes.size()) {
      return std::nullopt;
    }

    auto frame = std::move(connection.input);

    connection.input.reset();
    connection.prefix_bytes = 0;
    return frame;
  }

  template struct Result<Memory>;
  template struct Result<ConcurrentMemory>;
  template class ResultQueue<Memory>;
  template class ResultQueue<ConcurrentMemory>;
  template class Session<Memory>;
  template class Session<ConcurrentMemory>;

}
