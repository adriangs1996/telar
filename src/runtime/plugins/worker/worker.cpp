module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.plugins.worker;

import telar.sys.socket;
import telar.sys.process;
import telar.runtime.traffic.http.message;
import telar.base.ds;

namespace telar::runtime::plugins {

  namespace {

    // The longest frame a connection of `stage` may hand the bridge.
    std::size_t frameLimit(TrafficStage stage) noexcept {
      if (stage == TrafficStage::control) {
        return traffic::control::Limits::reply_bytes;
      }

      return stage == TrafficStage::http ? traffic::Limits::http_frame_bytes : traffic::Limits::frame_bytes;
    }

  }

  template <Allocator Memory>
  Result<Memory>::Result(const ServiceSpec& specification, tbc::val_a<SensitiveAllocation<Memory>> owned, std::size_t effects_offset, std::size_t effects_size, bool from_traffic)
      : package_index(specification.package_index),
        plugin_id(specification.plugin_id),
        digest(specification.digest),
        generation(specification.generation),
        storage(std::move(owned)),
        traffic(from_traffic),
        effects{.offset = effects_offset, .size = effects_size} {
    const auto decoded = Protocol::decodeEffects(effectBytes());

    event_id = decoded.event_id;
    batch_count = decoded.batch.count;
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
    return storage.bytes().subspan(effects.offset, effects.size);
  }

  template <Allocator Memory>
  void ResultQueue<Memory>::activate() {
    ready_.emplace();
  }

  template <Allocator Memory>
  void ResultQueue<Memory>::publish(tbc::val_a<OwnedResult<Memory>> result) noexcept {
    if (results_.publish(std::move(result))) {
      ready_.getMut().notify();
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
      ds::Array watches{
          pollfd{.fd = descriptor, .events = events, .revents = 0},
          pollfd{.fd = process_.error(), .events = POLLIN, .revents = 0},
          pollfd{.fd = cancellation_.descriptor(), .events = POLLIN, .revents = 0},
      };

      const auto timeout = remainingMilliseconds();
      if (timeout == 0) {
        sys::setLastError(ETIMEDOUT);
        return false;
      }

      const auto count = ::poll(watches.dataMut(), watches.size(), timeout);
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
    ds::Array<char, error_chunk_bytes> bytes{};
    std::size_t drained = 0;

    while (process_.error() >= 0 && drained < maximum_error_drain_bytes) {
      const auto count = ::read(process_.error(), bytes.dataMut(), bytes.size());
      if (count < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (count <= 0) {
        if (count == 0 || !socketWouldBlock(sys::lastError())) {
          process_.closeError();
        }

        return;
      }

      const auto received = static_cast<std::size_t>(count);
      const auto retained = std::min(received, Limits::stderr_bytes - error_.view().size());

      // What is retained is cut to the room left, so the append never throws.
      try {
        error_.append({bytes.data(), retained});
      } catch (...) {
        std::abort();
      }

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

  tbc::val_a<ds::Array<char*, TapWorkerOptions::argument_capacity>> TapWorkerOptions::arguments(tbc::ref_a<TapWorkerOptions> options, tbc::val_a<const char*> executable) noexcept {
    ds::Array<char*, argument_capacity> words{const_cast<char*>(executable), const_cast<char*>(command.data()), const_cast<char*>(options.entry)}; // NOLINT(cppcoreguidelines-pro-type-const-cast): execve takes argv as char* const[], and never writes the words
    std::size_t count = 3;

    if (options.traffic) {
      words.atMut(count++) = const_cast<char*>("--traffic"); // NOLINT(cppcoreguidelines-pro-type-const-cast): execve takes argv as char* const[], and never writes the words
    }

#if TELAR_DEBUG
    if (options.trace_path != nullptr) {
      words.atMut(count++) = const_cast<char*>("--trace");          // NOLINT(cppcoreguidelines-pro-type-const-cast): execve takes argv as char* const[], and never writes the words
      words.atMut(count++) = const_cast<char*>(options.trace_path); // NOLINT(cppcoreguidelines-pro-type-const-cast): execve takes argv as char* const[], and never writes the words
    }

#endif
    words.atMut(count) = nullptr;
    return words;
  }

  template <Allocator Memory>
  Session<Memory>::Session(Memory& memory, const SessionOptions& options)
      : memory_(memory),
        process_(spawn(options)),
        stream_(PipeEnds{.input = process_.output(), .output = process_.input()}, SessionIo{process_, options.cancellation}),
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
    stream_.waitMut().drainError();
    const auto error = stream_.wait().retainedError();
    if (error.empty()) {
      return;
    }

    try {
      std::println(stderr, "tap worker stderr: {}", error);
    } catch (...) {
      // A stderr that cannot be written loses the worker's output, as it would any line.
      return;
    }
  }

  template <Allocator Memory>
  OwnedResult<Memory> Session<Memory>::exchange(const ServiceSpec& specification, std::uint64_t event_id, std::span<const Byte> frame) {
    TELAR_TRACE("plugins.workerExchange");
    auto received = request(frame, Limits::effect_bytes);

    if (received.bytes().front() == static_cast<Byte>(FrameKind::error)) {
      const auto failure = Protocol::decodeError(received.bytes());

      requireEvent(event_id, failure.event_id);
      return {};
    }

    const auto size = received.bytes().size();
    auto result = ds::makeBox<Result<Memory>>(memory_, specification, std::move(received), 0, size);

    requireEvent(event_id, result->event_id);
    return result;
  }

  template <Allocator Memory>
  SensitiveAllocation<Memory> Session<Memory>::request(std::span<const Byte> frame, std::size_t maximum_bytes) {
    stream_.waitMut().deadline(timeout_);
    channel_.send(frame);
    stream_.waitMut().deadline(timeout_);
    auto received = channel_.receive(memory_, maximum_bytes);
    if (!received) {
      throw SystemError{"Tap worker closed", EPIPE};
    }

    if (!stream_.wait().active()) {
      throw SystemError{"Tap worker request cancelled or expired"};
    }

    return std::move(received.getMut());
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
    const auto arguments = TapWorkerOptions::arguments(worker, options.executable);
    const ds::Array<char*, 1> environment{nullptr};

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
      stream_.waitMut().drainError();
      std::this_thread::sleep_for(std::chrono::milliseconds{1});
    }
  }
#endif

  std::span<const Byte> TrafficRegistration::requestBytes() const noexcept {
    return byteView(request.view());
  }

  traffic::InterceptionRule TrafficRegistration::rule() const noexcept {
    return {.host = host.view(), .directions = directions, .visibility = visibility, .timeout_ms = timeout_ms, .fail_closed = fail_closed, .http = stage == TrafficStage::http};
  }

  tbc::val_a<std::span<const Byte>> TrafficProtocol::setup(tbc::val_a<std::span<Byte>> output, const ServiceSpec& specification) {
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

    std::ranges::copy(digest, specification.digest.viewMut().begin());
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

  tbc::val_a<std::span<const Byte>> TrafficProtocol::event(tbc::val_a<std::span<Byte>> output, TrafficEventId id, std::span<const Byte> frame, std::uint64_t dropped) {
    traffic::Protocol::decode(frame);
    FrameWriter writer{output};

    writer.tag(FrameKind::traffic_event);
    writer.integer(id.event_id);
    writer.integer(id.registration);
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
      if (event.error.size() > TrafficLimits::error_bytes || (event.error.empty() == event.control.empty())) {
        throw EncodingError{"Invalid worker control result"};
      }

      if (!event.control.empty()) {
        traffic::control::Protocol::reply(event.control);
      }
    }

    reader.finish();
    return event;
  }

  tbc::val_a<std::span<const Byte>> TrafficProtocol::controlEvent(tbc::val_a<std::span<Byte>> output, TrafficEventId id, std::span<const Byte> frame, std::string_view error) {
    FrameWriter writer{output};

    writer.tag(FrameKind::traffic_control_event);
    writer.integer(id.event_id);
    writer.integer(id.registration);
    writer.text(error);
    writer.bytes(frame);
    return writer.finish();
  }

  tbc::val_a<std::span<const Byte>> TrafficProtocol::reply(tbc::val_a<std::span<Byte>> output, const TrafficReply& reply, const TrafficOutcome& outcome) {
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

  tbc::val_a<TrafficOutcome> TrafficProtocol::readReply(tbc::val_a<std::span<const Byte>> input, TrafficReply& reply) {
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

    for (auto& registration : reply.registrations.viewMut().first(reply.registration_count)) {
      registration = read(reader);
    }

    TrafficOutcome outcome;

    outcome.decision_count = reader.integer<Byte>();
    if (outcome.decision_count > outcome.decisions.size()) {
      throw EncodingError{"Invalid traffic decision count"};
    }

    for (auto& decision : outcome.decisions.viewMut().first(outcome.decision_count)) {
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

  TrafficBridge::Connection::Connection(tbc::mut_a<Secure> memory, TrafficRegistration declared, traffic::PackageChannel channel)
      : registration(std::move(declared)),
        socket(std::move(channel.socket)),
        owner(channel.owner),
        output(memory, 2 * traffic::Limits::http_frame_bytes),
        registration_ack(this->registration.stage == TrafficStage::stream || this->registration.stage == TrafficStage::http) {}

  TrafficBridge::TrafficBridge(tbc::mut_a<ConcurrentMemory> memory, ServiceSpec specification, tbc::mut_a<traffic::PackagePort> port)
      : memory_(memory),
        secure_(memory),
        specification_(std::move(specification)),
        port_(port),
        reply_(ds::makeBox<TrafficReply>(memory)) {}

  void TrafficBridge::attach(Session<ConcurrentMemory>& session) {
    // Room for the setup frame: the package's identity, digest and name, and its capabilities.
    constexpr std::size_t setup_bytes = 1024;

    ds::Array<Byte, setup_bytes> output{};
    const auto initialized = session.request(TrafficProtocol::setup(output.viewMut(), specification_), TrafficLimits::reply_bytes);

    apply(0, initialized.bytes());
    for (auto& connection : connections_.viewMut()) {
      if (connection && connection->registration.stage != TrafficStage::control) {
        port_.setPackageAvailable(connection->owner, true);
        connection.getMut().notify_ready = connection->ready;
      }
    }
  }

  void TrafficBridge::detach() noexcept {
    for (auto& connection : connections_.viewMut()) {
      if (connection && connection->registration.stage == TrafficStage::control) {
        connection.reset();
      } else if (connection) {
        port_.setPackageAvailable(connection->owner, false);
        connection.getMut().notify_ready = false;
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
    // Room for a decision that carries no replacement.
    constexpr std::size_t decision_bytes = 32;

    ds::Array<Byte, decision_bytes> decision{};

    enqueue(connection, traffic::InterceptionCodec::decision(decision.viewMut(), flow.ticket, connection.registration.fail_closed ? traffic::Verdict::reject : traffic::Verdict::allow));
  }

  auto TrafficBridge::find(std::span<ds::Option<Connection>> connections, std::uint32_t id) noexcept -> Connection* {
    for (auto& connection : connections) {
      if (connection && connection->registration.id == id) {
        return &connection.getMut();
      }
    }

    return nullptr;
  }

  tbc::val_a<TrafficOutcome> TrafficBridge::apply(std::uint64_t event_id, tbc::val_a<std::span<const Byte>> input) {
    const auto outcome = TrafficProtocol::readReply(input, reply_.getMut());

    if (reply_->event_id != event_id) {
      throw EncodingError{"Stale traffic worker reply"};
    }

    if (reply_->changed) {
      checkRegistrations();
      dropUnregistered();
      openRegistered();
    }

    applyDecisions(outcome);
    return outcome;
  }

  void TrafficBridge::checkRegistrations() const {
    const auto registrations = std::span{reply_->registrations}.first(reply_->registration_count);
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
  }

  void TrafficBridge::dropUnregistered() noexcept {
    const auto registrations = std::span{reply_->registrations}.first(reply_->registration_count);

    for (auto& connection : connections_.viewMut()) {
      if (connection && !std::ranges::any_of(registrations, [&](const auto& registration) {
            return registration.id == connection->registration.id;
          })) {
        connection.reset();
      }
    }
  }

  void TrafficBridge::openRegistered() {
    const auto registrations = std::span{reply_->registrations}.first(reply_->registration_count);

    for (const auto& registration : registrations) {
      if (const auto* existing = find(connections_.viewMut(), registration.id)) {
        const auto& before = existing->registration;
        if (before != registration) {
          throw EncodingError{"Traffic registrations are immutable"};
        }

        continue;
      }

      for (auto& connection : connections_.viewMut()) {
        if (connection) {
          continue;
        }

        if (registration.stage == TrafficStage::control) {
          connection.emplace(secure_, registration, traffic::PackageChannel{.socket = FileDescriptor{}, .owner = 0});
          connection.getMut().output.append(traffic::control::Protocol::prefix(registration.requestBytes().size()));
          connection.getMut().output.append(registration.requestBytes());
          break;
        }

        connection.emplace(secure_, registration, port_.openPackage(specification_, registration.id));
        ds::Array<Byte, traffic::Protocol::greeting_bytes + traffic::Limits::filter_bytes> greeting{};
        const auto hello = traffic::Protocol::greeting(greeting.viewMut(), registration.stage == TrafficStage::observe ? traffic::Role::subscribe : traffic::Role::intercept, registration.filter.view(), registration.selection);

        connection.getMut().output.append(hello);
        if (registration.stage != TrafficStage::observe) {
          const auto rule = traffic::InterceptionCodec::rule(greeting.viewMut(), registration.rule());

          enqueue(connection.getMut(), rule);
        }

        break;
      }
    }
  }

  void TrafficBridge::applyDecisions(const TrafficOutcome& outcome) {
    for (const auto& decision : std::span{outcome.decisions}.first(outcome.decision_count)) {
      auto* connection = find(connections_.viewMut(), decision.registration);
      if (connection == nullptr) {
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
  }

  void TrafficBridge::openControl(traffic::PackagePort& port, const ServiceSpec& specification, Connection& connection) {
    try {
      connection.socket = port.openControl(specification);
    } catch (const SystemError& failure) {
      if (failure.code() != EAGAIN) {
        connection.error.assign(std::string_view{failure.what()}.substr(0, TrafficLimits::error_bytes));
      }
    } catch (const std::exception& failure) {
      connection.error.assign(std::string_view{failure.what()}.substr(0, TrafficLimits::error_bytes));
    }
  }

  void TrafficBridge::watchConnections(std::span<pollfd> descriptors, std::span<std::uint32_t> identities) const noexcept {
    for (std::size_t index = 0; index < connections_.size(); ++index) {
      const auto& connection = connections_[index];
      const bool writing = connection && !connection->output.empty();

      identities[index] = connection ? connection->registration.id : 0;
      descriptors[index] = {.fd = connection ? connection->socket.get() : -1, .events = static_cast<short>(combineFlags(POLLIN, writing ? POLLOUT : 0)), .revents = 0};
    }
  }

  bool TrafficBridge::due(std::size_t index, Priority priority, std::uint32_t identity) const noexcept {
    const auto& connection = connections_[index];

    return connection && priorityOf(connection->registration.stage) == priority && connection->registration.id == identity;
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

  tbc::val_a<ds::Option<SensitiveAllocation<ConcurrentMemory>>> TrafficBridge::read(tbc::mut_a<ConcurrentMemory> memory, Connection& connection) {
    if (!connection.input) {
      const auto prefix_bytes = connection.registration.stage == TrafficStage::control ? traffic::control::Protocol::prefix_bytes : traffic::Protocol::prefix_bytes;
      const auto pending = connection.prefix.viewMut().subspan(connection.prefix_bytes, prefix_bytes - connection.prefix_bytes);
      const auto count = ::recv(connection.socket.get(), pending.data(), pending.size(), 0);
      if (count < 0 && socketWouldBlock(sys::lastError())) {
        return ds::none;
      }

      if (count <= 0) {
        throw SystemError{"Read package traffic prefix", EPIPE};
      }

      connection.prefix_bytes += static_cast<std::size_t>(count);
      if (connection.prefix_bytes != prefix_bytes) {
        return ds::none;
      }

      FrameReader prefix{std::span<const Byte>{connection.prefix}.first(prefix_bytes)};
      const auto size = prefix.integer<std::uint32_t>();

      if (connection.registration.stage != TrafficStage::control) {
        connection.dropped = prefix.integer<std::uint64_t>();
      }

      if (size == 0 || size > frameLimit(connection.registration.stage)) {
        throw EncodingError{"Invalid package traffic frame size"};
      }

      connection.input.emplace(memory, size);
      connection.received = 0;
    }

    const auto bytes = connection.input.getMut().bytesMut();
    const auto rest = bytes.subspan(connection.received);
    const auto count = ::recv(connection.socket.get(), rest.data(), rest.size(), 0);
    if (count < 0 && socketWouldBlock(sys::lastError())) {
      return ds::none;
    }

    if (count <= 0) {
      throw SystemError{"Read package traffic frame", EPIPE};
    }

    connection.received += static_cast<std::size_t>(count);
    if (connection.received != bytes.size()) {
      return ds::none;
    }

    auto frame = std::move(connection.input);

    connection.input.reset();
    connection.prefix_bytes = 0;
    return frame;
  }

  template <WorkerClock Clock>
  Worker<Clock>::Worker(ConcurrentMemory& memory, const ServiceSpec& specification, ResultQueue<ConcurrentMemory>& results, TapBudget& budget, WorkerLaunch launch)
      : memory_(memory),
        specification_(bindPermissions(memory, specification)),
        results_(results),
        budget_(budget),
        launch_(launch),
        entry_(memory, specification.entry.view()),
        trace_path_(memory),
        thread_([this] {
          run();
        }) {}

  template <WorkerClock Clock>
  Worker<Clock>::~Worker() {
    stop();
  }

  template <WorkerClock Clock>
  void Worker<Clock>::stop() noexcept {
    cancellation_.request();
    requests_.close();
    if (thread_.joinable()) {
      thread_.join();
    }

    bridge_.reset();
    session_.reset();
  }

  template <WorkerClock Clock>
  void Worker<Clock>::revoke() noexcept {
    specification_.permission->store(false, std::memory_order_release);
    if (revoked_.exchange(true, std::memory_order_acq_rel)) {
      return;
    }

    disabled_.store(true, std::memory_order_relaxed);
    cancellation_.request();
    requests_.close();
    if (launch_.traffic != nullptr) {
      launch_.traffic->revokePackage(specification_);
    }
  }

  template <WorkerClock Clock>
  bool Worker<Clock>::revoked() const noexcept {
    return revoked_.load(std::memory_order_acquire);
  }

  template <WorkerClock Clock>
  void Worker<Clock>::submit(tbc::val_a<Shared> exchange) noexcept {
    if (specification_.allows(Capability::proxy_tap) && !disabled_.load(std::memory_order_relaxed)) {
      requests_.publish(std::move(exchange));
      wake_.notify();
    }
  }

  template <WorkerClock Clock>
  WorkerMetrics Worker<Clock>::metrics() const noexcept {
    return {.dropped = requests_.metrics().dropped, .timeouts = timeouts_.load(std::memory_order_relaxed), .disabled = disabled_.load(std::memory_order_relaxed), .callback_errors = callback_errors_.load(std::memory_order_relaxed)};
  }

  template <WorkerClock Clock>
  const ServiceSpec& Worker<Clock>::specification() const noexcept {
    return specification_;
  }

  template <WorkerClock Clock>
  ServiceSpec Worker<Clock>::bindPermissions(ConcurrentMemory& memory, const ServiceSpec& specification) {
    auto bound = specification;
    if (!bound.permission) {
      bound.permission = std::allocate_shared<std::atomic<bool>>(AllocatorRef<std::atomic<bool>, ConcurrentMemory>{memory}, true);
    }

    return bound;
  }

  template <WorkerClock Clock>
  void Worker<Clock>::run() noexcept {
    if ((launch_.traffic != nullptr) && specification_.traffic()) {
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

  template <WorkerClock Clock>
  void Worker<Clock>::runTraffic() noexcept {
    while (!launch_.cancellation.requested() && !cancellation_.requested()) {
      if (disabled_.load(std::memory_order_relaxed)) {
        if (!awaitCancellation()) {
          return;
        }

        continue;
      }

      try {
        if (!session_) {
          startTraffic();
        }

        wake_.drain();
        if (auto request = requests_.tryReceive()) {
          process(**request);
        }

        if (!bridge_) {
          continue;
        }

        bridge_.getMut().step(session_ ? &session_.getMut() : nullptr, wake_.descriptor(), cancellation_, [&](OwnedResult<ConcurrentMemory> result) {
          results_.publish(std::move(result));
        },
            requests_.metrics().queued != 0);

        callback_errors_.store(callback_errors_base_ + bridge_->errors(), std::memory_order_relaxed);
      } catch (const SystemError& error) {
        if (!recover(error)) {
          return;
        }
      } catch (...) {
        restart();
      }
    }
  }

  template <WorkerClock Clock>
  bool Worker<Clock>::awaitCancellation() noexcept {
    ds::Array watches{pollfd{.fd = cancellation_.descriptor(), .events = POLLIN, .revents = 0}, pollfd{.fd = launch_.cancellation.descriptor(), .events = POLLIN, .revents = 0}};

    return ::poll(watches.dataMut(), watches.size(), -1) >= 0 || sys::lastError() == EINTR;
  }

  template <WorkerClock Clock>
  void Worker<Clock>::startTraffic() {
    ensureSession(true);
    if (!bridge_) {
      bridge_ = ds::makeBox<TrafficBridge>(memory_, memory_, specification_, *launch_.traffic);
    }

    bridge_.getMut().attach(session_.getMut());
  }

  template <WorkerClock Clock>
  void Worker<Clock>::process(const SharedExchange& shared) noexcept {
    TELAR_TRACE("plugins.processExchange");
    try {
      ensureSession(false);
    } catch (...) {
      restart();
      return;
    }

    try {
      const auto size = SharedExchange::capturedBytes(shared.exchange) + Limits::frame_overhead;
      auto charged = budget_.charge(size);
      if (!charged) {
        return;
      }

      const auto encoded_size = Protocol::exchangeBytes(shared.exchange);
      if (encoded_size > size) {
        return;
      }

      SensitiveAllocation frame{memory_, encoded_size};
      const auto payload = Protocol::encodeExchange(frame.bytesMut(), {.id = shared.event_id, .generation = specification_.generation}, shared.exchange);

      exchange(shared.event_id, payload);
    } catch (...) {
      // An exchange that cannot be framed is dropped, as one over the budget is.
      return;
    }
  }

  template <WorkerClock Clock>
  void Worker<Clock>::exchange(std::uint64_t event_id, std::span<const Byte> payload) noexcept {
    try {
      auto result = session_.getMut().exchange(specification_, event_id, payload);
      if (result) {
        results_.publish(std::move(result));
      }
    } catch (const SystemError& error) {
      static_cast<void>(recover(error));
    } catch (...) {
      restart();
    }
  }

  template <WorkerClock Clock>
  void Worker<Clock>::ensureSession(bool traffic) {
    if (session_) {
      return;
    }

    prepareTrace();
    session_.emplace(memory_, SessionOptions{.executable = launch_.executable, .entry = entry_.data(), .cancellation = cancellation_, .timeout = launch_.timeout, .trace_path = trace_path_.empty() ? nullptr : trace_path_.data(), .traffic = traffic});
  }

  template <WorkerClock Clock>
  bool Worker<Clock>::recover(const SystemError& error) noexcept {
    if (error.code() == ECANCELED) {
      return false;
    }

    if (error.code() == ETIMEDOUT) {
      timeouts_.fetch_add(1, std::memory_order_relaxed);
    }

    restart();
    return true;
  }

  template <WorkerClock Clock>
  void Worker<Clock>::restart() noexcept {
    if (bridge_) {
      bridge_.getMut().detach();
      if (bridge_->transportFailed()) {
        callback_errors_base_ += bridge_->errors();
        bridge_.reset();
      }
    }

    session_.reset();
    const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch());
    if (restarts_.record(now)) {
      disabled_.store(true, std::memory_order_relaxed);
    }
  }

  template <WorkerClock Clock>
  void Worker<Clock>::prepareTrace() {
#if TELAR_DEBUG
    if (launch_.trace_prefix.empty()) {
      return;
    }

    // Room for the package's index and the session's number around the suffix's text.
    constexpr std::size_t suffix_capacity = 64;

    ds::Array<char, suffix_capacity> suffix{};
    const auto written = std::format_to_n(suffix.dataMut(), static_cast<std::ptrdiff_t>(suffix.size() - 1), ".tap-{}-{}.json", static_cast<unsigned>(specification_.package_index), session_number_++);

    trace_path_.assign(launch_.trace_prefix);
    trace_path_.append(std::string_view{suffix.data(), static_cast<std::size_t>(std::min<std::ptrdiff_t>(written.size, static_cast<std::ptrdiff_t>(suffix.size() - 1)))});
#endif
  }

  template struct Result<Memory>;
  template struct Result<ConcurrentMemory>;
  template class ResultQueue<Memory>;
  template class ResultQueue<ConcurrentMemory>;
  template class Session<Memory>;
  template class Session<ConcurrentMemory>;
  template class Worker<std::chrono::steady_clock>;

}
