module telar.runtime.traffic.control_backend;

import telar.sys.socket;
import telar.tls;
import telar.platform.thread;
import telar.base.ds;

namespace telar::runtime::traffic::control {

  bool authorized(const plugins::ServiceSpec& package, const Request& request) noexcept {
    if (!package.authorized()) {
      return false;
    }

    if (request.operation == Operation::recording) {
      return package.allows(plugins::Capability::traffic_record);
    }

    if (request.operation == Operation::status || request.operation == Operation::ca_certificate) {
      return package.traffic();
    }

    return package.allows(plugins::Capability::traffic_control);
  }
}

namespace telar::runtime::traffic {
  namespace {

    // Whether the mask sets the bit an enumerator's value names.
    template <typename Enum>
      requires std::is_enum_v<Enum>
    bool hasBit(Byte mask, Enum value) noexcept {
      return (mask & (1U << static_cast<Byte>(value))) != 0;
    }

  }

  auto InterceptionCodec::rule(tbc::val_a<std::span<Byte>> output, InterceptionRule rule) -> tbc::val_a<std::span<const Byte>> {
    plugins::FrameWriter writer{output};

    writer.tag(rule.http ? Command::http_rule : Command::rule);
    writer.text(rule.host);
    writer.integer(rule.directions);
    writer.integer(rule.visibility);
    writer.integer(rule.timeout_ms);
    writer.boolean(rule.fail_closed);
    return writer.finish();
  }

  auto InterceptionCodec::readRule(plugins::FrameReader& reader) -> InterceptionRule {
    InterceptionRule rule{.host = reader.text(), .directions = reader.integer<Byte>(), .visibility = reader.integer<Byte>(), .timeout_ms = reader.integer<std::uint32_t>(), .fail_closed = reader.boolean()};

    reader.finish();

    if (!ProxyHostname::validPattern(rule.host) || rule.directions == 0 || rule.directions > 3 || rule.visibility == 0 || rule.visibility > 3 || rule.timeout_ms == 0 || rule.timeout_ms > maximum_timeout_ms) {
      throw EncodingError{"Invalid interception rule"};
    }

    return rule;
  }

  auto InterceptionCodec::decision(tbc::val_a<std::span<Byte>> output, std::uint64_t ticket, Verdict verdict, std::span<const Byte> bytes) -> tbc::val_a<std::span<const Byte>> {
    plugins::FrameWriter writer{output};

    writer.tag(Command::decision);
    writer.integer(ticket);
    writer.tag(verdict);
    writer.bytes(bytes);
    return writer.finish();
  }

  template <std::size_t maximum_bytes>
  Interception<maximum_bytes>::Registration::Registration(ConcurrentMemory& memory, Owner owner, InterceptionRule rule, std::uint64_t generation, std::uint64_t order)
      : route{owner, generation, rule.timeout_ms, rule.fail_closed, order},
        hosts(memory),
        directions(rule.directions),
        visibility(rule.visibility) {
    if (!ProxyHostname::validPattern(rule.host) || rule.directions == 0 || rule.directions > 3 || rule.visibility == 0 || rule.visibility > 3 || rule.timeout_ms == 0 || rule.timeout_ms > maximum_timeout_ms || !hosts.append(rule.host)) {
      throw EncodingError{"Invalid interception rule"};
    }

    hosts.finish();
  }

  template <std::size_t maximum_bytes>
  Interception<maximum_bytes>::Pending::Pending(Secure& memory, std::uint64_t issued, const FlowEvent& event, std::span<const Route> matches)
      : ticket(issued),
        decision_ticket(issued),
        id(event.id),
        offset(event.offset),
        direction(event.direction),
        visibility(event.visibility),
        source(event.source),
        bytes(memory, event.bytes),
        routes(matches.size()) {
    client.append(event.client);
    server.append(event.server);
    host.append(event.host);
    reason.append(event.reason);
    std::ranges::copy(matches, chain.viewMut().begin());
  }

  template <std::size_t maximum_bytes>
  auto Interception<maximum_bytes>::Pending::event() const noexcept -> FlowEvent {
    return {.id = id, .direction = direction, .visibility = visibility, .source = source, .offset = offset, .ticket = decision_ticket, .client = client.view(), .server = server.view(), .host = host.view(), .reason = reason.view(), .bytes = bytes};
  }

  template <std::size_t maximum_bytes>
  Interception<maximum_bytes>::Interception(ConcurrentMemory& memory, InterceptionSignals signals)
      : upstream_(memory),
        memory_(memory),
        completion_((signals.completion != nullptr) ? *signals.completion : wake_),
        request_signal_((signals.requests != nullptr) ? *signals.requests : requests_) {
    randomBytes(&next_, sizeof(next_));
    next_ >>= 1U;
  }

  template <std::size_t maximum_bytes>
  void Interception<maximum_bytes>::configure(InterceptionRule rule) {
    configure(default_owner, rule);
  }

  template <std::size_t maximum_bytes>
  auto Interception<maximum_bytes>::policy(const FlowEvent& event) noexcept -> HttpPolicy {
    if (active_.load(std::memory_order_acquire) == 0) {
      return {};
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wthread-safety-negative" // asks each locking method to require the mutex not held, an annotation Clang rejects on libc++'s std::mutex here
    std::scoped_lock lock{mutex_};
#pragma clang diagnostic pop
    HttpPolicy result;

    for (const auto& entry : registrations_) {
      if (entry && serves(*entry, event)) {
        result.enabled = true;
        result.fail_closed |= entry->route.fail_closed;
      }
    }

    return result;
  }

  template <std::size_t maximum_bytes>
  void Interception<maximum_bytes>::configure(Owner owner, InterceptionRule rule, std::uint64_t order) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wthread-safety-negative" // asks each locking method to require the mutex not held, an annotation Clang rejects on libc++'s std::mutex here
    std::scoped_lock lock{mutex_};
#pragma clang diagnostic pop

    if (owner == 0 || registration(owner)) {
      throw EncodingError{"Interception owner already registered"};
    }

    for (auto& slot : registrations_.viewMut()) {
      if (!slot) {
        slot.emplace(upstream_, owner, rule, ++generation_, order);
        active_.fetch_add(1, std::memory_order_release);
        return;
      }
    }

    throw EncodingError{"Interception registration limit reached"};
  }

  template <std::size_t maximum_bytes>
  void Interception<maximum_bytes>::disconnect(Owner owner) noexcept {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wthread-safety-negative" // asks each locking method to require the mutex not held, an annotation Clang rejects on libc++'s std::mutex here
    std::scoped_lock lock{mutex_};
#pragma clang diagnostic pop

    for (auto& slot : registrations_.viewMut()) {
      if (slot && slot->route.owner == owner) {
        slot.reset();
        active_.fetch_sub(1, std::memory_order_release);
      }
    }

    for (auto& slot : pending_.viewMut()) {
      if (slot && slot->verdict == Verdict::pending && slot->chain[slot->step].owner == owner) {
        advance(slot.getMut(), failure(*slot), registrations_, next_, {.completion = completion_, .requests = request_signal_});
      }
    }
  }

  template <std::size_t maximum_bytes>
  void Interception<maximum_bytes>::setAvailable(Owner owner, bool available) noexcept {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wthread-safety-negative" // asks each locking method to require the mutex not held, an annotation Clang rejects on libc++'s std::mutex here
    std::scoped_lock lock{mutex_};
#pragma clang diagnostic pop
    auto* entry = registration(owner);
    if ((entry == nullptr) || (!available && !entry->available)) {
      return;
    }

    entry->available = false;
    for (auto& pending : pending_.viewMut()) {
      if (pending && pending->verdict == Verdict::pending && pending->chain[pending->step].owner == owner) {
        advance(pending.getMut(), failure(*pending), registrations_, next_, {.completion = completion_, .requests = request_signal_});
      }
    }

    if (available) {
      entry->route.generation = ++generation_;
      entry->available = true;
    }
  }

  template <std::size_t maximum_bytes>
  bool Interception<maximum_bytes>::pending(Owner owner, std::uint64_t ticket) noexcept {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wthread-safety-negative" // asks each locking method to require the mutex not held, an annotation Clang rejects on libc++'s std::mutex here
    std::scoped_lock lock{mutex_};
#pragma clang diagnostic pop
    const auto* entry = registration(owner);
    if ((entry == nullptr) || !entry->available) {
      return false;
    }

    for (const auto& pending : pending_) {
      if (pending && pending->verdict == Verdict::pending && pending->decision_ticket == ticket && pending->chain[pending->step].owner == owner && pending->chain[pending->step].generation == entry->route.generation && std::chrono::steady_clock::now() < pending->deadline) {
        return true;
      }
    }

    return false;
  }

  template <std::size_t maximum_bytes>
  auto Interception<maximum_bytes>::begin(const FlowEvent& event) noexcept -> std::uint64_t {
    if (active_.load(std::memory_order_acquire) == 0) {
      return 0;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wthread-safety-negative" // asks each locking method to require the mutex not held, an annotation Clang rejects on libc++'s std::mutex here
    std::scoped_lock lock{mutex_};
#pragma clang diagnostic pop
    ds::Array<Route, Limits::subscribers> matches;
    std::size_t count = 0;
    bool fail_closed = false;

    for (const auto& entry : registrations_) {
      if (!entry || !serves(*entry, event)) {
        continue;
      }

      if (!entry->available) {
        if (entry->route.fail_closed) {
          return rejected_ticket;
        }

        continue;
      }

      matches.atMut(count++) = entry->route;
      fail_closed |= entry->route.fail_closed;
    }

    if (count == 0) {
      return 0;
    }

    std::ranges::sort(matches.viewMut().first(count), [](const auto& left, const auto& right) {
      return left.order < right.order || (left.order == right.order && left.generation < right.generation);
    });

    return queue(event, std::span{matches}.first(count), fail_closed);
  }

  template <std::size_t maximum_bytes>
  auto Interception<maximum_bytes>::queue(const FlowEvent& event, std::span<const Route> routes, bool fail_closed) noexcept -> std::uint64_t {
    const std::uint64_t refused = fail_closed ? rejected_ticket : 0;

    for (auto& slot : pending_.viewMut()) {
      if (slot) {
        continue;
      }

      try {
        if (event.bytes.size() > maximum_bytes) {
          return refused;
        }

        slot.emplace(memory_, ++next_, event, routes);
        slot.getMut().deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds{routes.front().timeout_ms};
        request_signal_.notify();
        return slot->ticket;
      } catch (...) {
        slot.reset();
        return refused;
      }
    }

    return refused;
  }

  template <std::size_t maximum_bytes>
  void Interception<maximum_bytes>::decide(std::uint64_t ticket, Verdict verdict, std::span<const Byte> bytes) {
    decide(default_owner, ticket, verdict, bytes);
  }

  template <std::size_t maximum_bytes>
  void Interception<maximum_bytes>::decide(Owner owner, std::uint64_t ticket, Verdict verdict, std::span<const Byte> bytes) {
    if (verdict == Verdict::pending || bytes.size() > maximum_bytes || (verdict != Verdict::replace && !bytes.empty())) {
      throw EncodingError{"Invalid stream decision"};
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wthread-safety-negative" // asks each locking method to require the mutex not held, an annotation Clang rejects on libc++'s std::mutex here
    std::scoped_lock lock{mutex_};
#pragma clang diagnostic pop

    for (auto& slot : pending_.viewMut()) {
      if (slot && slot->decision_ticket == ticket && slot->verdict == Verdict::pending && slot->chain[slot->step].owner == owner) {
        if (std::chrono::steady_clock::now() >= slot->deadline) {
          advance(slot.getMut(), failure(*slot), registrations_, next_, {.completion = completion_, .requests = request_signal_});
          return;
        }

        if (verdict == Verdict::replace) {
          slot.getMut().bytes.clear();
          slot.getMut().bytes.extend(bytes);
          slot.getMut().replaced = true;
        }

        advance(slot.getMut(), verdict, registrations_, next_, {.completion = completion_, .requests = request_signal_});
        return;
      }
    }
    // Late responses are harmless and must never apply to a different chunk.
  }

  template <std::size_t maximum_bytes>
  auto Interception<maximum_bytes>::poll(std::uint64_t ticket, std::span<Byte> replacement) noexcept -> FlowControl::Decision {
    if (ticket == rejected_ticket) {
      return {.verdict = Verdict::reject};
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wthread-safety-negative" // asks each locking method to require the mutex not held, an annotation Clang rejects on libc++'s std::mutex here
    std::scoped_lock lock{mutex_};
#pragma clang diagnostic pop

    for (auto& slot : pending_.viewMut()) {
      if (slot && slot->ticket == ticket) {
        if (slot->verdict == Verdict::pending && std::chrono::steady_clock::now() >= slot->deadline) {
          advance(slot.getMut(), failure(*slot), registrations_, next_, {.completion = completion_, .requests = request_signal_});
        }

        const auto verdict = slot->verdict;
        if (verdict == Verdict::pending) {
          return {verdict};
        }

        const auto count = verdict == Verdict::replace ? slot->bytes.size() : 0;
        if (count > replacement.size()) {
          slot.reset();
          return {.verdict = Verdict::reject};
        }

        if (count != 0) {
          std::ranges::copy(slot->bytes, replacement.begin());
        }

        slot.reset();
        return {verdict, count};
      }
    }

    return {.verdict = Verdict::reject};
  }

  template <std::size_t maximum_bytes>
  auto Interception<maximum_bytes>::pending(std::uint64_t ticket) noexcept -> bool {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wthread-safety-negative" // asks each locking method to require the mutex not held, an annotation Clang rejects on libc++'s std::mutex here
    std::scoped_lock lock{mutex_};
#pragma clang diagnostic pop

    for (const auto& slot : pending_) {
      if (slot && slot->ticket == ticket) {
        return slot->verdict == Verdict::pending && std::chrono::steady_clock::now() < slot->deadline;
      }
    }

    return false;
  }

  template <std::size_t maximum_bytes>
  int Interception<maximum_bytes>::requestDescriptor() const noexcept {
    return request_signal_.descriptor();
  }

  template <std::size_t maximum_bytes>
  void Interception<maximum_bytes>::drainRequests() noexcept {
    request_signal_.drain();
  }

  template <std::size_t maximum_bytes>
  auto Interception<maximum_bytes>::completionSignal() noexcept -> CompletionSignal& {
    return completion_;
  }

  template <std::size_t maximum_bytes>
  auto Interception<maximum_bytes>::requestSignal() noexcept -> CompletionSignal& {
    return request_signal_;
  }

  template <std::size_t maximum_bytes>
  void Interception<maximum_bytes>::cancel(std::uint64_t ticket) noexcept {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wthread-safety-negative" // asks each locking method to require the mutex not held, an annotation Clang rejects on libc++'s std::mutex here
    std::scoped_lock lock{mutex_};
#pragma clang diagnostic pop

    for (auto& slot : pending_.viewMut()) {
      if (slot && slot->ticket == ticket) {
        slot.reset();
        return;
      }
    }
  }

  template <std::size_t maximum_bytes>
  ds::Option<FlowControl::Time> Interception<maximum_bytes>::deadline(std::uint64_t ticket) noexcept {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wthread-safety-negative" // asks each locking method to require the mutex not held, an annotation Clang rejects on libc++'s std::mutex here
    const std::scoped_lock lock{mutex_};
#pragma clang diagnostic pop

    for (const auto& slot : pending_) {
      if (slot && slot->ticket == ticket) {
        return slot->deadline;
      }
    }

    return std::chrono::steady_clock::now();
  }

  template <std::size_t maximum_bytes>
  int Interception<maximum_bytes>::descriptor() const noexcept {
    return completion_.descriptor();
  }

  template <std::size_t maximum_bytes>
  void Interception<maximum_bytes>::drain() noexcept {
    completion_.drain();
  }

  template <std::size_t maximum_bytes>
  auto Interception<maximum_bytes>::registration(Owner owner) noexcept -> Registration* {
    for (auto& slot : registrations_.viewMut()) {
      if (slot && slot->route.owner == owner) {
        return &slot.getMut();
      }
    }

    return nullptr;
  }

  template <std::size_t maximum_bytes>
  auto Interception<maximum_bytes>::registration(const Registrations& registrations, Owner owner) noexcept -> const Registration* {
    for (const auto& slot : registrations) {
      if (slot && slot->route.owner == owner) {
        return &*slot;
      }
    }

    return nullptr;
  }

  template <std::size_t maximum_bytes>
  bool Interception<maximum_bytes>::serves(const Registration& registration, const FlowEvent& event) noexcept {
    return registration.hosts.contains(event.host) && hasBit(registration.directions, event.direction) && hasBit(registration.visibility, event.visibility);
  }

  template <std::size_t maximum_bytes>
  Verdict Interception<maximum_bytes>::failure(const Pending& pending) noexcept {
    return pending.chain[pending.step].fail_closed ? Verdict::reject : Verdict::allow;
  }

  template <std::size_t maximum_bytes>
  void Interception<maximum_bytes>::advance(Pending& pending, Verdict verdict, const Registrations& registrations, std::uint64_t& next, Wakes wakes) noexcept {
    for (;;) {
      if (verdict == Verdict::reject || ++pending.step == pending.routes) {
        if (verdict != Verdict::reject) {
          verdict = pending.replaced ? Verdict::replace : Verdict::allow;
        }

        pending.verdict = verdict;
        wakes.completion.notify();
        return;
      }

      const auto& route = pending.chain[pending.step];
      const auto* entry = registration(registrations, route.owner);
      if (entry && entry->available && entry->route.generation == route.generation) {
        pending.decision_ticket = ++next;
        pending.deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds{route.timeout_ms};
        pending.delivered = false;
        wakes.requests.notify();
        wakes.completion.notify();
        return;
      }

      verdict = failure(pending);
    }
  }

  void reportFailure(std::string_view component, const std::exception& error) noexcept {
    constexpr std::size_t line_bytes = 1024;
    ds::Array<char, line_bytes> line{};
    const std::string_view message{error.what()};
    std::span<char> output = line.viewMut();
    // The line is cut to the buffer, and written in one call so that lines from threads do not mix.
    const auto append = [&](std::string_view part) {
      const auto count = std::min(part.size(), output.size());

      std::ranges::copy(std::span<const char>{part}.first(count), output.begin());
      output = output.subspan(count);
    };

    append(component);
    append(": ");
    append(message);
    append("\n");
    static_cast<void>(::write(STDERR_FILENO, line.data(), line.size() - output.size()));
  }

  int PackageChannel::get() const noexcept {
    return socket.get();
  }

  void PackagePort::packageFailure(const plugins::ServiceSpec& /*specification*/, FlowEvent /*event*/) noexcept {}

  FileDescriptor PackagePort::openControl(const plugins::ServiceSpec& /*specification*/) {
    throw SystemError{"Package control is not available", EAGAIN};
  }

  void PackagePort::revokePackage(const plugins::ServiceSpec& /*specification*/) noexcept {}
}

namespace telar::runtime::traffic::recording {

  Owner Owner::package(const plugins::ServiceSpec& package) {
    return {.id = package.plugin_id, .digest = package.digest, .permission = package.permission};
  }

  bool Owner::authorized() const noexcept {
    return !permission || permission->load(std::memory_order_acquire);
  }

  bool Owner::matches(const Owner& other) const noexcept {
    return id == other.id && digest == other.digest;
  }

  bool Owner::canRead(const Owner& other) const noexcept {
    return id == 0 || matches(other);
  }
}

namespace telar::runtime::traffic {

  Service::Peer::Peer(SensitiveMemory& memory, FileDescriptor channel, uid_t user)
      : socket(std::move(channel)),
        uid(user),
        input(memory) {}

  Service::Service(ConcurrentMemory& memory, std::string_view path, bool allow_interception)
      : upstream_(memory),
        memory_(memory),
        listener_(path),
        interception_(memory),
        http_interception_(memory, {.completion = &interception_.completionSignal(), .requests = &interception_.requestSignal()}),
        analysis_(memory),
        recordings_(memory),
        allow_interception_(allow_interception) {
    randomBytes(&session_, sizeof(session_));
    thread_ = startThread("Start traffic service", [this] {
      run();
    });
  }

  Service::~Service() {
    stopping_.store(true, std::memory_order_release);
    wake_.notify();
    thread_.join();
  }

  bool Service::listening() const noexcept {
    return exchange_subscribers_.load(std::memory_order_acquire) != 0 || recordings_.selects(Selection::exchanges);
  }

  tbc::val_a<std::span<const Byte>> Service::recording(const recording::Request& request, tbc::val_a<std::span<Byte>> output, recording::Owner owner) {
    return recordings_.handle(request, output, std::move(owner));
  }

  void Service::packageControl(control::PackagePort* port) noexcept {
    package_control_.store(port, std::memory_order_release);
  }

  FileDescriptor Service::openControl(const plugins::ServiceSpec& package) {
    auto* const port = package_control_.load(std::memory_order_acquire);
    if (port == nullptr) {
      throw SystemError{"Package control is starting", EAGAIN};
    }

    return port->openPackage(package);
  }

  void Service::revokePackage(const plugins::ServiceSpec& package) noexcept {
    recordings_.revoke(recording::Owner::package(package));
  }

  PackageChannel Service::openPackage(const plugins::ServiceSpec& specification, std::uint32_t registration) {
    const bool observe = specification.allows(plugins::Capability::traffic_observe);
    const bool intercept = specification.allows(plugins::Capability::traffic_intercept);
    if ((!observe && !intercept) || specification.plugin_id == 0 || specification.generation == 0) {
      throw EncodingError{"Package has no granted traffic capability"};
    }

    ds::Array<int, 2> descriptors{};
    if (::socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors.dataMut()) != 0) {
      throw SystemError{"Create package traffic channel"};
    }

    FileDescriptor native{descriptors[0]};
    FileDescriptor client{descriptors[1]};

    configureProxySocket(native.get());
    configureProxySocket(client.get());
    // A package's registrations order after every registration of the packages before it.
    constexpr unsigned registration_bits = 32;
    const auto order = (static_cast<std::uint64_t>(specification.package_index) << registration_bits) | registration;
    const auto owner = ++next_owner_;
    if (!attachments_.publish(Attachment{.socket = std::move(native), .package = {.id = specification.plugin_id, .digest = specification.digest, .generation = specification.generation, .observe = observe, .intercept = intercept, .order = order, .permission = specification.permission}, .owner = owner})) {
      throw SystemError{"Package traffic attachment queue is full", EBUSY};
    }

    wake_.notify();
    return {.socket = std::move(client), .owner = owner};
  }

  void Service::setPackageAvailable(std::uint64_t owner, bool available) noexcept {
    interception_.setAvailable(owner, available);
    http_interception_.setAvailable(owner, available);
  }

  bool Service::packagePending(std::uint64_t owner, std::uint64_t ticket, bool http) noexcept {
    return http ? http_interception_.pending(owner, ticket) : interception_.pending(owner, ticket);
  }

  void Service::packageFailure(const plugins::ServiceSpec& specification, FlowEvent event) noexcept {
    constexpr std::size_t reason_bytes = 128;
    constexpr std::string_view prefix = "app_callback_error:";
    ds::Array<char, reason_bytes> reason{};
    const std::span<const char> name{specification.name.view()};
    // The reason keeps a byte free, as the C string it was written as did.
    const auto kept = name.first(std::min(name.size(), reason.size() - 1 - prefix.size()));

    std::ranges::copy(kept, std::ranges::copy(prefix, reason.viewMut().begin()).out);
    event.reason = {reason.data(), prefix.size() + kept.size()};
    event.bytes = {};
    observeFlow(Kind::flow_error, event);
  }

  auto Service::captureStatus() const noexcept -> CaptureStatus {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wthread-safety-negative" // asks each locking method to require the mutex not held, an annotation Clang rejects on libc++'s std::mutex here
    const std::scoped_lock lock{capture_mutex_};
#pragma clang diagnostic pop

    return capture_status_;
  }

  std::uint64_t Service::stopCapture() noexcept {
    const auto revision = capture_stop_.fetch_add(1, std::memory_order_release) + 1;

    wake_.notify();
    return revision;
  }

  bool Service::captureStopped(std::uint64_t revision) const noexcept {
    return capture_stopped_.load(std::memory_order_acquire) >= revision;
  }

  void Service::submit(CapturedExchange& exchange) noexcept {
    if (!listening()) {
      return;
    }

    try {
      SensitiveBuffer<Limits::frame_bytes> output;
      const auto sequence = next_exchange_.fetch_add(1, std::memory_order_relaxed);
      const auto payload = plugins::Protocol::encodeExchange(output.bytes(), {.id = sequence, .generation = session_}, exchange, Limits::http_part_bytes);
      auto frame = encode(Event{.kind = Kind::exchange, .session = session_, .sequence = sequence, .bytes = payload});

      injections_.publish(std::move(frame));
      wake_.notify();
    } catch (const std::exception&) {
      allocation_drops_.fetch_add(1, std::memory_order_relaxed);
    }
  }

  void Service::observeFlow(Kind kind, const FlowEvent& flow) noexcept {
    if (kind != Kind::intercept_request && flow_subscribers_.load(std::memory_order_acquire) == 0 && !recordings_.selects(Selection::flows)) {
      return;
    }

    try {
      SensitiveBuffer<FlowControl::chunk_bytes + Limits::metadata_bytes> output;
      const auto payload = FlowCodec::encode(output.bytes(), flow);
      const auto now = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
      auto frame = encode(Event{.kind = kind, .session = session_, .sequence = next_exchange_.fetch_add(1, std::memory_order_relaxed), .timestamp_us = static_cast<std::uint64_t>(now), .bytes = payload});

      injections_.publish(std::move(frame));
      wake_.notify();
    } catch (const std::exception&) {
      allocation_drops_.fetch_add(1, std::memory_order_relaxed);
    }
  }

  std::uint64_t Service::intercept(const FlowEvent& event) noexcept {
    return interception_.begin(event);
  }

  auto Service::poll(std::uint64_t ticket, std::span<Byte> replacement) noexcept -> Decision {
    return interception_.poll(ticket, replacement);
  }

  void Service::cancel(std::uint64_t ticket) noexcept {
    interception_.cancel(ticket);
  }

  auto Service::deadline(std::uint64_t ticket) noexcept -> ds::Option<Time> {
    return interception_.deadline(ticket);
  }

  int Service::descriptor() const noexcept {
    return interception_.descriptor();
  }

  void Service::drain() noexcept {
    interception_.drain();
  }

  HttpControl* Service::http() noexcept {
    return allow_interception_ ? this : nullptr;
  }

  HttpPolicy Service::policy(const FlowEvent& context) noexcept {
    return http_interception_.policy(context);
  }

  std::uint64_t Service::interceptHttp(const FlowEvent& event) noexcept {
    return http_interception_.begin(event);
  }

  auto Service::pollHttp(std::uint64_t ticket, std::span<Byte> replacement) noexcept -> Decision {
    return http_interception_.poll(ticket, replacement);
  }

  void Service::cancelHttp(std::uint64_t ticket) noexcept {
    http_interception_.cancel(ticket);
  }

  auto Service::httpDeadline(std::uint64_t ticket) noexcept -> ds::Option<Time> {
    return http_interception_.deadline(ticket);
  }

  void Service::httpUnavailable(const FlowEvent& event) noexcept {
    observeFlow(Kind::flow_error, event);
  }

  void Service::run() noexcept {
    while (!stopping_.load(std::memory_order_acquire)) {
      try {
        step();
      } catch (const std::exception& error) {
        reportFailure("telar traffic", error);
      }
    }
  }

  void Service::step() {
    ds::Array<pollfd, maximum_peers + 3> descriptors{};

    descriptors.atMut(0) = {.fd = listener_.descriptor(), .events = POLLIN, .revents = 0};
    descriptors.atMut(1) = {.fd = wake_.descriptor(), .events = POLLIN, .revents = 0};
    descriptors.atMut(2) = {.fd = interception_.requestDescriptor(), .events = POLLIN, .revents = 0};
    for (std::size_t index = 0; index < peers_.size(); ++index) {
      const auto& peer = peers_[index];
      const bool writable = peer && peer->count != 0;

      descriptors.atMut(index + 3) = {.fd = peer ? peer->socket.get() : -1, .events = static_cast<short>(writable ? combineFlags(POLLIN, POLLOUT) : POLLIN), .revents = 0};
    }

    constexpr int heartbeat_ms = 1000;
    const auto result = ::poll(descriptors.dataMut(), descriptors.size(), heartbeat_ms);
    if (result < 0 && sys::lastError() != EINTR) {
      throw SystemError{"Poll traffic sockets"};
    }

    if (stopping_.load(std::memory_order_acquire)) {
      return;
    }

    const auto stop_capture = capture_stop_.load(std::memory_order_acquire);
    if (stop_capture != capture_stopped_.load(std::memory_order_relaxed)) {
      for (auto& peer : peers_.viewMut()) {
        if (peer && (peer->role == Role::live_capture || peer->role == Role::offline_capture)) {
          peer.getMut().failed = true;
        }
      }
    }

    if (pollReady(descriptors[1], POLLIN)) {
      wake_.drain();
      receive();
    }

    if (pollReady(descriptors[2], POLLIN)) {
      interception_.drainRequests();
    }

    for (std::size_t index = 0; index < peers_.size(); ++index) {
      auto& peer = peers_.atMut(index);
      if (peer && exchange(peer.getMut(), descriptors[index + 3])) {
        retire(index);
      }
    }

    capture_stopped_.store(stop_capture, std::memory_order_release);

    if (pollReady(descriptors[0], POLLIN)) {
      accept();
    }

    deliverRequests();
    heartbeat();
  }

  void Service::receive() {
    while (auto attachment = attachments_.tryReceive()) {
      for (auto& slot : peers_.viewMut()) {
        if (!slot) {
          slot.emplace(memory_, std::move(attachment.getMut().socket), ::geteuid());
          slot.getMut().package = attachment->package;
          slot.getMut().owner = attachment->owner;
          break;
        }
      }
    }

    while (const auto frame = injections_.tryReceive()) {
      const auto event = Protocol::decode((*frame)->bytes.bytes());

      // A share of the frame, as Rust clones an Arc: the event views the bytes this one keeps.
      publish(event, *frame);
    }
  }

  bool Service::exchange(Peer& peer, const pollfd& descriptor) {
    try {
      if (pollReady(descriptor, combineFlags(POLLIN, POLLHUP))) {
        read(peer);
      }

      if (pollReady(descriptor, POLLOUT)) {
        write(peer);
      }
    } catch (const std::exception&) {
      peer.failed = true;
    }

    constexpr auto handshake_timeout = std::chrono::seconds{5};
    const bool expired = !peer.role && std::chrono::steady_clock::now() - peer.connected >= handshake_timeout;

    return peer.failed || expired || pollReady(descriptor, combineFlags(POLLERR, POLLNVAL));
  }

  void Service::retire(std::size_t slot) {
    auto& peer = peers_.atMut(slot);
    const bool producer = peer->role == Role::live_capture || peer->role == Role::offline_capture;

    if (peer->role == Role::intercept) {
      interception_.disconnect(peer->owner);
      http_interception_.disconnect(peer->owner);
    }

    if (peer->role == Role::subscribe && selects(peer->selection, Selection::exchanges)) {
      exchange_subscribers_.fetch_sub(1, std::memory_order_release);
    }

    if (peer->role == Role::subscribe && selects(peer->selection, Selection::flows)) {
      flow_subscribers_.fetch_sub(1, std::memory_order_release);
    }

    if (peer->role == Role::subscribe && selects(peer->selection, Selection::datagrams)) {
      datagram_subscribers_.fetch_sub(1, std::memory_order_release);
    }

    peer.reset();
    if (!producer) {
      return;
    }

    producer_ = false;
    {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wthread-safety-negative" // asks each locking method to require the mutex not held, an annotation Clang rejects on libc++'s std::mutex here
      const std::scoped_lock lock{capture_mutex_};
#pragma clang diagnostic pop

      capture_status_ = {};
    }

    analysis_.expire([&](const Event& event) {
      publish(event);
    },
        true);
    publish(Event{.kind = Kind::capture_stopped});
  }

  void Service::deliverRequests() {
    for (auto& peer : peers_.viewMut()) {
      if (!peer || peer->failed || !peer->configured || peer->role != Role::intercept) {
        continue;
      }

      const auto deliver = [&](const FlowEvent& flow) {
        if (peer->count == peer->queue.size()) {
          return false;
        }

        SensitiveAllocation output{upstream_, flow.bytes.size() + Limits::metadata_bytes};
        const auto payload = FlowCodec::encode(output.bytesMut(), flow);
        const auto now = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::system_clock::now().time_since_epoch()).count();

        enqueue(peer.getMut(), encode(Event{.kind = peer->http ? Kind::http_intercept_request : Kind::intercept_request, .session = session_, .sequence = next_exchange_.fetch_add(1, std::memory_order_relaxed), .timestamp_us = static_cast<std::uint64_t>(now), .bytes = payload}));
        return true;
      };

      if (peer->http) {
        http_interception_.deliver(peer->owner, deliver);
      } else {
        interception_.deliver(peer->owner, deliver);
      }
    }
  }

  void Service::heartbeat() {
    const auto now = std::chrono::steady_clock::now();
    if (now - heartbeat_ < std::chrono::seconds{1}) {
      return;
    }

    analysis_.expire([&](const Event& event) {
      publish(event);
    });

    recordings_.expire();
    publish(Event{.kind = Kind::statistics, .runtime_drops = injections_.metrics().dropped + allocation_drops_.load(std::memory_order_relaxed)});
    heartbeat_ = now;
  }

  void Service::accept() {
    auto socket = listener_.accept(LocalPeerPolicy::same_user_or_root);
    if (!socket) {
      return;
    }

    const auto credentials = peerCredentials(socket.get());
    if (!credentials) {
      return;
    }

    for (auto& slot : peers_.viewMut()) {
      if (!slot) {
        slot.emplace(memory_, std::move(socket), credentials->user);
        return;
      }
    }
  }

  void Service::read(Peer& peer) {
    constexpr std::size_t frames_per_tick = 32;

    for (std::size_t frame = 0; frame < frames_per_tick; ++frame) {
      const auto previous = peer.input.size();

      peer.input.resize(peer.expected);
      const auto space = peer.input.viewMut().subspan(previous);
      const auto count = ::recv(peer.socket.get(), space.data(), space.size(), 0);
      if (count <= 0) {
        peer.input.resize(previous);
        if (count == 0 || !socketWouldBlock(sys::lastError())) {
          peer.failed = true;
        }

        return;
      }

      peer.input.resize(previous + static_cast<std::size_t>(count));
      if (peer.input.size() != peer.expected) {
        return;
      }

      const bool whole = peer.role ? consume(peer) : greet(peer);
      if (!whole) {
        continue;
      }

      peer.input.clear();
      peer.expected = Protocol::prefix_bytes;
    }
  }

  bool Service::consume(Peer& peer) {
    if (*peer.role == Role::subscribe) {
      throw EncodingError{"Subscribers cannot publish traffic"};
    }

    if (peer.expected == Protocol::prefix_bytes) {
      plugins::FrameReader reader{peer.input};
      const auto size = reader.integer<std::uint32_t>();
      const auto limit = peer.http ? Limits::http_frame_bytes : Limits::frame_bytes;
      if (size == 0 || size > limit || reader.integer<std::uint64_t>() != 0) {
        throw EncodingError{"Invalid capture frame prefix"};
      }

      peer.expected = size;
      peer.input.clear();
      return false;
    }

    if (*peer.role == Role::intercept) {
      control(peer);
    } else {
      ingest(peer);
    }

    return true;
  }

  void Service::ingest(Peer& peer) {
    auto event = Protocol::decode(peer.input);
    if (event.kind >= Kind::exchange) {
      throw EncodingError{"Capture helpers cannot publish decrypted exchanges"};
    }

    event.offline = *peer.role == Role::offline_capture;
    if (event.kind != Kind::packet) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wthread-safety-negative" // asks each locking method to require the mutex not held, an annotation Clang rejects on libc++'s std::mutex here
      const std::scoped_lock lock{capture_mutex_};
#pragma clang diagnostic pop

      capture_status_.session = event.session;
      if (event.kind == Kind::interface_open) {
        ++capture_status_.interfaces;
      } else if (event.kind == Kind::interface_closed && capture_status_.interfaces != 0) {
        --capture_status_.interfaces;
      } else if (event.kind == Kind::interface_error) {
        ++capture_status_.interface_errors;
      }
    }

    publish(event);
    if (event.kind != Kind::packet) {
      return;
    }

    const bool flows = flow_subscribers_.load(std::memory_order_acquire) != 0 || recordings_.selects(Selection::flows);
    const bool datagrams = datagram_subscribers_.load(std::memory_order_acquire) != 0 || recordings_.selects(Selection::datagrams);
    if (!flows && !datagrams) {
      return;
    }

    // Analysis reads only the flow and datagram bits, so both wanted is every bit.
    auto selected = Selection::all;

    if (!datagrams) {
      selected = Selection::flows;
    } else if (!flows) {
      selected = Selection::datagrams;
    }

    analysis_.packet(event, selected, [&](const Event& item) {
      publish(item);
    });
  }

  bool Service::greet(Peer& peer) {
    if (revoked(peer)) {
      throw EncodingError{"Package traffic permission revoked"};
    }

    std::span<const Byte> input{peer.input};
    if (LittleEndian<std::uint32_t>::decode(input) != Protocol::magic) {
      throw EncodingError{"Incompatible traffic protocol"};
    }

    const auto role = LittleEndian<Byte>::decode(input);
    const auto selection = LittleEndian<Byte>::decode(input);
    const auto size = LittleEndian<std::uint32_t>::decode(input);
    if (role < static_cast<Byte>(Role::subscribe) || role > static_cast<Byte>(Role::intercept) || selection < static_cast<Byte>(Selection::packets) || selection > static_cast<Byte>(Selection::all) || size > Limits::filter_bytes) {
      throw EncodingError{"Invalid traffic greeting"};
    }

    if (peer.expected == Protocol::greeting_bytes && size != 0) {
      peer.expected += size;
      return false;
    }

    if (input.size() != size) {
      throw EncodingError{"Truncated traffic filter"};
    }

    const auto selected = static_cast<Role>(role);
    if (peer.package && !grants(*peer.package, selected)) {
      throw EncodingError{"Package traffic capability denied"};
    }

    peer.selection = static_cast<Selection>(selection);
    admit(peer, selected, size);
    if (selected == Role::subscribe) {
      peer.filter.emplace(textView(input));
      enroll(peer);
    }

    if (selected == Role::intercept && peer.owner == 0) {
      peer.owner = ++next_owner_;
    }

    peer.role = selected;
    enqueue(peer, encode(Event{.kind = Kind::ready}));
    if (selected == Role::live_capture || selected == Role::offline_capture) {
      {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wthread-safety-negative" // asks each locking method to require the mutex not held, an annotation Clang rejects on libc++'s std::mutex here
        const std::scoped_lock lock{capture_mutex_};
#pragma clang diagnostic pop

        capture_status_ = {.state = selected == Role::live_capture ? CaptureState::live : CaptureState::offline};
      }

      publish(Event{.kind = Kind::capture_started, .offline = selected == Role::offline_capture});
    }

    return true;
  }

  void Service::admit(const Peer& peer, Role role, std::uint32_t filter_bytes) {
    if (role == Role::subscribe) {
      const auto subscribers = std::ranges::count_if(peers_, [](const auto& slot) {
        return slot && slot->role == Role::subscribe;
      });
      if (std::cmp_greater_equal(subscribers, Limits::subscribers) || peer.uid != ::geteuid()) {
        throw EncodingError{"Traffic subscription is unavailable"};
      }

      return;
    }

    if (role == Role::intercept) {
      const auto controllers = std::ranges::count_if(peers_, [](const auto& slot) {
        return slot && slot->role == Role::intercept;
      });
      if (!allow_interception_ || std::cmp_greater_equal(controllers, Limits::subscribers) || filter_bytes != 0 || peer.uid != ::geteuid()) {
        throw EncodingError{"Stream interception is unavailable"};
      }

      return;
    }

    if (producer_ || filter_bytes != 0 || (role == Role::live_capture && peer.uid != 0)) {
      throw EncodingError{"Traffic capture requires one authorized helper"};
    }

    producer_ = true;
  }

  void Service::enroll(const Peer& peer) noexcept {
    if (selects(peer.selection, Selection::flows)) {
      flow_subscribers_.fetch_add(1, std::memory_order_release);
    }

    if (selects(peer.selection, Selection::datagrams)) {
      datagram_subscribers_.fetch_add(1, std::memory_order_release);
    }

    if (selects(peer.selection, Selection::exchanges)) {
      exchange_subscribers_.fetch_add(1, std::memory_order_release);
    }
  }

  bool Service::revoked(const Peer& peer) noexcept {
    return peer.package && peer.package->permission && !peer.package->permission->load(std::memory_order_acquire);
  }

  bool Service::grants(const Peer::PackageIdentity& package, Role role) noexcept {
    return (role == Role::subscribe && package.observe) || (role == Role::intercept && package.intercept);
  }

  void Service::control(Peer& peer) {
    if (revoked(peer)) {
      throw EncodingError{"Package traffic permission revoked"};
    }

    plugins::FrameReader reader{peer.input};
    const auto command = reader.tag(InterceptionCodec::Command::http_rule);
    if (command == InterceptionCodec::Command::rule || command == InterceptionCodec::Command::http_rule) {
      if (peer.configured) {
        throw EncodingError{"Interception rule already registered"};
      }

      const auto rule = InterceptionCodec::readRule(reader);

      peer.http = command == InterceptionCodec::Command::http_rule;
      const auto order = peer.package ? peer.package->order : std::numeric_limits<std::uint64_t>::max();

      if (peer.http) {
        http_interception_.configure(peer.owner, rule, order);
      } else {
        interception_.configure(peer.owner, rule, order);
      }

      peer.configured = true;
      enqueue(peer, encode(Event{.kind = Kind::ready}));
    } else if (command == InterceptionCodec::Command::decision && peer.configured) {
      const auto ticket = reader.integer<std::uint64_t>();
      const auto verdict = reader.tag(Verdict::reject);
      const auto bytes = reader.bytes();

      reader.finish();
      if (peer.http) {
        if (verdict == Verdict::replace) {
          HttpMessageCodec::decode(bytes);
        }

        http_interception_.decide(peer.owner, ticket, verdict, bytes);
      } else {
        interception_.decide(peer.owner, ticket, verdict, bytes);
      }
    } else {
      throw EncodingError{"Interception requires a rule before decisions"};
    }
  }

  auto Service::encode(const Event& event) -> std::shared_ptr<Frame> {
    auto frame = std::allocate_shared<Frame>(AllocatorRef<Frame, SensitiveMemory>{memory_}, upstream_, Protocol::encodedSize(event));

    Protocol::encode(frame->bytes.bytesMut(), event);
    return frame;
  }

  void Service::publish(const Event& event, std::shared_ptr<Frame> shared) {
    shared = recordings_.record(event, std::move(shared));
    for (auto& peer : peers_.viewMut()) {
      if (!peer || peer->failed) {
        continue;
      }

      if (peer->role != Role::subscribe || event.kind == Kind::intercept_request || event.kind == Kind::http_intercept_request) {
        continue;
      }

      try {
        if ((event.kind == Kind::packet && !selects(peer->selection, Selection::packets)) || (event.kind == Kind::exchange && !selects(peer->selection, Selection::exchanges)) || (isFlow(event.kind) && !selects(peer->selection, Selection::flows)) || (event.kind == Kind::datagram && !selects(peer->selection, Selection::datagrams))) {
          continue;
        }

        if (peer.getMut().filter && !peer.getMut().filter.getMut().matches(event)) {
          continue;
        }

        if (!shared) {
          shared = encode(event);
        }

        enqueue(peer.getMut(), shared);
      } catch (const std::exception&) {
        peer.getMut().failed = true;
      }
    }
  }

  void Service::enqueue(Peer& peer, std::shared_ptr<Frame> frame) {
    if (peer.count == peer.queue.size()) {
      ++peer.dropped;
      return;
    }

    auto& delivery = peer.queue.atMut((peer.head + peer.count) % peer.queue.size());

    delivery.prefix = Protocol::prefix(frame->bytes.bytes().size(), {.frames = peer.dropped});
    delivery.frame = std::move(frame);
    delivery.offset = 0;
    ++peer.count;
  }

  void Service::write(Peer& peer) {
    for (std::size_t round = 0; round < Limits::pending_frames && peer.count != 0; ++round) {
      auto& delivery = peer.queue.atMut(peer.head);
      const auto prefix = std::span<const Byte>{delivery.prefix};
      const auto body = std::span<const Byte>{delivery.frame->bytes.bytes()};
      const auto bytes = delivery.offset < prefix.size() ? prefix.subspan(delivery.offset) : body.subspan(delivery.offset - prefix.size());
      const auto count = ::send(peer.socket.get(), bytes.data(), bytes.size(), 0);
      if (count <= 0) {
        if (count == 0 || !socketWouldBlock(sys::lastError())) {
          peer.failed = true;
        }

        return;
      }

      delivery.offset += static_cast<std::size_t>(count);
      if (delivery.offset == prefix.size() + body.size()) {
        delivery.frame.reset();
        peer.head = (peer.head + 1) % peer.queue.size();
        --peer.count;
      }
    }
  }
}

namespace telar::runtime::traffic::control {

  TrustCommand::TrustCommand(ConcurrentMemory& memory, const std::atomic<bool>& cancelled) noexcept
      : memory_(memory),
        cancelled_(cancelled) {}

  void TrustCommand::run(std::span<const std::string_view> arguments) {
#ifdef __linux__
    constexpr ds::Array executables{"/usr/bin/trust", "/usr/bin/install", "/usr/bin/rm", "/usr/sbin/update-ca-certificates"};
    const bool allowed = arguments.size() >= 3 && arguments[0] == "/usr/bin/sudo" && arguments[1] == "--" && std::ranges::find(executables, arguments[2]) != executables.end();
#else
    const bool allowed = !arguments.empty() && arguments.front() == "/usr/bin/security";
#endif
    if (!allowed) {
      throw std::invalid_argument{"Invalid trust operation"};
    }

    constexpr auto store_timeout = std::chrono::seconds{10};
    Command command{memory_, Launch{.arguments = arguments}, CommandPurpose::administration};
    CommandOutput<ConcurrentMemory> output{memory_, Limits::reply_bytes, &cancelled_};
    if (output.run(command, std::chrono::steady_clock::now() + store_timeout, true) != 0) {
      throw SystemError{"Certificate store operation failed", EACCES};
    }
  }
}

namespace telar::runtime::traffic {

  template class Interception<>;

}

namespace telar::runtime::traffic::control {

}

namespace telar::runtime::traffic {

  template class Interception<HttpMessageLimits::message_bytes>;

}
