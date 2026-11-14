module;
#include <new>
#include <stdlib.h>

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits.h>

#include <arpa/inet.h>
#include <cerrno>

#include <cassert>
#include <pcap/pcap.h>

#include <csignal>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#include <brotli/decode.h>
#include <zlib.h>
#include <zstd.h>
#if (!(defined(__APPLE__)))
#include <cstdlib>

#include <openssl/err.h>

#include <openssl/pem.h>

#include <openssl/x509.h>
#endif
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <openssl/sha.h>
#include <sys/uio.h>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>

#include <sys/syscall.h>
#endif
#include <brotli/encode.h>
#include <ctime>
#include <dirent.h>
#include <netdb.h>
#include <nghttp2/nghttp2.h>
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#include <climits>

#include <sched.h>

#include <sys/epoll.h>

#include <sys/syscall.h>
#endif
#include <ifaddrs.h>
#include <net/if.h>
#include <spawn.h>
#include <sys/resource.h>
#include <sys/wait.h>
#if (defined(__APPLE__))
#include <libproc.h>
#endif

module telar.runtime.traffic.control_backend;

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

  auto InterceptionCodec::rule(tbc::view<std::span<Byte>, tbc::lt::a> output, InterceptionRule rule) -> tbc::view<std::span<const Byte>, tbc::lt::a> {
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

  auto InterceptionCodec::decision(tbc::view<std::span<Byte>, tbc::lt::a> output, std::uint64_t ticket, Verdict verdict, std::span<const Byte> bytes) -> tbc::view<std::span<const Byte>, tbc::lt::a> {
    plugins::FrameWriter writer{output};

    writer.tag(Command::decision);
    writer.integer(ticket);
    writer.tag(verdict);
    writer.bytes(bytes);
    return writer.finish();
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  Interception<Memory, maximum_bytes>::Registration::Registration(Memory& memory, Owner owner, InterceptionRule rule, std::uint64_t generation, std::uint64_t order)
      : route{owner, generation, rule.timeout_ms, rule.fail_closed, order},
        hosts(memory),
        directions(rule.directions),
        visibility(rule.visibility) {
    if (!ProxyHostname::validPattern(rule.host) || rule.directions == 0 || rule.directions > 3 || rule.visibility == 0 || rule.visibility > 3 || rule.timeout_ms == 0 || rule.timeout_ms > maximum_timeout_ms || !hosts.append(rule.host)) {
      throw EncodingError{"Invalid interception rule"};
    }

    hosts.finish();
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  Interception<Memory, maximum_bytes>::Pending::Pending(Secure& memory, std::uint64_t ticket, const FlowEvent& event, std::span<const Route> matches)
      : ticket(ticket),
        decision_ticket(ticket),
        id(event.id),
        offset(event.offset),
        direction(event.direction),
        visibility(event.visibility),
        source(event.source),
        bytes(event.bytes.begin(), event.bytes.end(), AllocatorRef<Byte, Secure>{memory}),
        routes(matches.size()) {
    client.append(event.client);
    server.append(event.server);
    host.append(event.host);
    reason.append(event.reason);
    std::ranges::copy(matches, chain.begin());
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  auto Interception<Memory, maximum_bytes>::Pending::event() const noexcept -> FlowEvent {
    return {.id = id, .direction = direction, .visibility = visibility, .source = source, .offset = offset, .ticket = decision_ticket, .client = client.view(), .server = server.view(), .host = host.view(), .reason = reason.view(), .bytes = bytes};
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  Interception<Memory, maximum_bytes>::Interception(Memory& memory, CompletionSignal* completion, CompletionSignal* requests)
      : upstream_(memory),
        memory_(memory),
        completion_(completion ? *completion : wake_),
        request_signal_(requests ? *requests : requests_) {
    randomBytes(&next_, sizeof(next_));
    next_ >>= 1;
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  void Interception<Memory, maximum_bytes>::configure(InterceptionRule rule) {
    configure(default_owner, rule);
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  auto Interception<Memory, maximum_bytes>::policy(const FlowEvent& event) noexcept -> HttpPolicy {
    if (active_.load(std::memory_order_acquire) == 0) {
      return {};
    }

    std::scoped_lock lock{mutex_};
    HttpPolicy result;

    for (const auto& entry : registrations_) {
      if (entry && entry->hosts.contains(event.host) && (entry->directions & (1 << static_cast<Byte>(event.direction))) && (entry->visibility & (1 << static_cast<Byte>(event.visibility)))) {
        result.enabled = true;
        result.fail_closed |= entry->route.fail_closed;
      }
    }

    return result;
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  void Interception<Memory, maximum_bytes>::configure(Owner owner, InterceptionRule rule, std::uint64_t order) {
    std::scoped_lock lock{mutex_};

    if (owner == 0 || registration(owner)) {
      throw EncodingError{"Interception owner already registered"};
    }

    for (auto& slot : registrations_) {
      if (!slot) {
        slot.emplace(upstream_, owner, rule, ++generation_, order);
        active_.fetch_add(1, std::memory_order_release);
        return;
      }
    }

    throw EncodingError{"Interception registration limit reached"};
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  void Interception<Memory, maximum_bytes>::disconnect(Owner owner) noexcept {
    std::scoped_lock lock{mutex_};

    for (auto& slot : registrations_) {
      if (slot && slot->route.owner == owner) {
        slot.reset();
        active_.fetch_sub(1, std::memory_order_release);
      }
    }

    for (auto& slot : pending_) {
      if (slot && slot->verdict == Verdict::pending && slot->chain[slot->step].owner == owner) {
        advance(*slot, failure(*slot), registrations_, next_, completion_, request_signal_);
      }
    }
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  void Interception<Memory, maximum_bytes>::setAvailable(Owner owner, bool available) noexcept {
    std::scoped_lock lock{mutex_};
    auto* entry = registration(owner);
    if (!entry || (!available && !entry->available)) {
      return;
    }

    entry->available = false;
    for (auto& pending : pending_) {
      if (pending && pending->verdict == Verdict::pending && pending->chain[pending->step].owner == owner) {
        advance(*pending, failure(*pending), registrations_, next_, completion_, request_signal_);
      }
    }

    if (available) {
      entry->route.generation = ++generation_;
      entry->available = true;
    }
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  bool Interception<Memory, maximum_bytes>::pending(Owner owner, std::uint64_t ticket) noexcept {
    std::scoped_lock lock{mutex_};
    const auto* entry = registration(owner);
    if (!entry || !entry->available) {
      return false;
    }

    for (const auto& pending : pending_) {
      if (pending && pending->verdict == Verdict::pending && pending->decision_ticket == ticket && pending->chain[pending->step].owner == owner && pending->chain[pending->step].generation == entry->route.generation && std::chrono::steady_clock::now() < pending->deadline) {
        return true;
      }
    }

    return false;
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  auto Interception<Memory, maximum_bytes>::begin(const FlowEvent& event) noexcept -> std::uint64_t {
    if (active_.load(std::memory_order_acquire) == 0) {
      return 0;
    }

    std::scoped_lock lock{mutex_};
    std::array<Route, Limits::subscribers> matches;
    std::size_t count = 0;
    bool fail_closed = false;

    for (const auto& entry : registrations_) {
      if (entry && entry->hosts.contains(event.host) && (entry->directions & (1 << static_cast<Byte>(event.direction))) && (entry->visibility & (1 << static_cast<Byte>(event.visibility)))) {
        if (!entry->available) {
          if (entry->route.fail_closed) {
            return rejected_ticket;
          }

          continue;
        }

        matches[count++] = entry->route;
        fail_closed |= entry->route.fail_closed;
      }
    }

    if (count == 0) {
      return 0;
    }

    std::ranges::sort(std::span{matches}.first(count), [](const auto& left, const auto& right) {
      return left.order < right.order || (left.order == right.order && left.generation < right.generation);
    });

    for (auto& slot : pending_) {
      if (!slot) {
        try {
          if (event.bytes.size() > maximum_bytes) {
            return fail_closed ? rejected_ticket : 0;
          }

          slot.emplace(memory_, ++next_, event, std::span{matches}.first(count));
          slot->deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds{matches[0].timeout_ms};
          request_signal_.notify();
          return slot->ticket;
        } catch (...) {
          slot.reset();
          return fail_closed ? rejected_ticket : 0;
        }
      }
    }

    return fail_closed ? rejected_ticket : 0;
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  void Interception<Memory, maximum_bytes>::decide(std::uint64_t ticket, Verdict verdict, std::span<const Byte> bytes) {
    decide(default_owner, ticket, verdict, bytes);
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  void Interception<Memory, maximum_bytes>::decide(Owner owner, std::uint64_t ticket, Verdict verdict, std::span<const Byte> bytes) {
    if (verdict == Verdict::pending || bytes.size() > maximum_bytes || (verdict != Verdict::replace && !bytes.empty())) {
      throw EncodingError{"Invalid stream decision"};
    }

    std::scoped_lock lock{mutex_};

    for (auto& slot : pending_) {
      if (slot && slot->decision_ticket == ticket && slot->verdict == Verdict::pending && slot->chain[slot->step].owner == owner) {
        if (std::chrono::steady_clock::now() >= slot->deadline) {
          advance(*slot, failure(*slot), registrations_, next_, completion_, request_signal_);
          return;
        }

        if (verdict == Verdict::replace) {
          slot->bytes.assign(bytes.begin(), bytes.end());
          slot->replaced = true;
        }

        advance(*slot, verdict, registrations_, next_, completion_, request_signal_);
        return;
      }
    }
    // Late responses are harmless and must never apply to a different chunk.
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  auto Interception<Memory, maximum_bytes>::poll(std::uint64_t ticket, std::span<Byte> replacement) noexcept -> FlowControl::Decision {
    if (ticket == rejected_ticket) {
      return {.verdict = Verdict::reject};
    }

    std::scoped_lock lock{mutex_};

    for (auto& slot : pending_) {
      if (slot && slot->ticket == ticket) {
        if (slot->verdict == Verdict::pending && std::chrono::steady_clock::now() >= slot->deadline) {
          advance(*slot, failure(*slot), registrations_, next_, completion_, request_signal_);
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

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  auto Interception<Memory, maximum_bytes>::pending(std::uint64_t ticket) noexcept -> bool {
    std::scoped_lock lock{mutex_};

    for (const auto& slot : pending_) {
      if (slot && slot->ticket == ticket) {
        return slot->verdict == Verdict::pending && std::chrono::steady_clock::now() < slot->deadline;
      }
    }

    return false;
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  int Interception<Memory, maximum_bytes>::requestDescriptor() const noexcept {
    return request_signal_.descriptor();
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  void Interception<Memory, maximum_bytes>::drainRequests() noexcept {
    request_signal_.drain();
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  auto Interception<Memory, maximum_bytes>::completionSignal() noexcept -> CompletionSignal& {
    return completion_;
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  auto Interception<Memory, maximum_bytes>::requestSignal() noexcept -> CompletionSignal& {
    return request_signal_;
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  void Interception<Memory, maximum_bytes>::cancel(std::uint64_t ticket) noexcept {
    std::scoped_lock lock{mutex_};

    for (auto& slot : pending_) {
      if (slot && slot->ticket == ticket) {
        slot.reset();
        return;
      }
    }
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  std::optional<FlowControl::Time> Interception<Memory, maximum_bytes>::deadline(std::uint64_t ticket) noexcept {
    std::lock_guard lock{mutex_};

    for (const auto& slot : pending_) {
      if (slot && slot->ticket == ticket) {
        return slot->deadline;
      }
    }

    return std::chrono::steady_clock::now();
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  int Interception<Memory, maximum_bytes>::descriptor() const noexcept {
    return completion_.descriptor();
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  void Interception<Memory, maximum_bytes>::drain() noexcept {
    completion_.drain();
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  auto Interception<Memory, maximum_bytes>::registration(Owner owner) noexcept -> Registration* {
    for (auto& slot : registrations_) {
      if (slot && slot->route.owner == owner) {
        return &*slot;
      }
    }

    return nullptr;
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  auto Interception<Memory, maximum_bytes>::registration(const Registrations& registrations, Owner owner) noexcept -> const Registration* {
    for (const auto& slot : registrations) {
      if (slot && slot->route.owner == owner) {
        return &*slot;
      }
    }

    return nullptr;
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  Verdict Interception<Memory, maximum_bytes>::failure(const Pending& pending) noexcept {
    return pending.chain[pending.step].fail_closed ? Verdict::reject : Verdict::allow;
  }

  template <ConcurrentAllocator Memory, std::size_t maximum_bytes>
  void Interception<Memory, maximum_bytes>::advance(Pending& pending, Verdict verdict, const Registrations& registrations, std::uint64_t& next, CompletionSignal& completion, CompletionSignal& requests) noexcept {
    for (;;) {
      if (verdict == Verdict::reject || ++pending.step == pending.routes) {
        pending.verdict = verdict == Verdict::reject ? Verdict::reject : pending.replaced ? Verdict::replace
                                                                                          : Verdict::allow;
        completion.notify();
        return;
      }

      const auto& route = pending.chain[pending.step];
      const auto* entry = registration(registrations, route.owner);
      if (entry && entry->available && entry->route.generation == route.generation) {
        pending.decision_ticket = ++next;
        pending.deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds{route.timeout_ms};
        pending.delivered = false;
        requests.notify();
        completion.notify();
        return;
      }

      verdict = failure(pending);
    }
  }

  int PackageChannel::get() const noexcept {
    return socket.get();
  }

  void PackagePort::packageFailure(const plugins::ServiceSpec&, FlowEvent) noexcept {}

  FileDescriptor PackagePort::openControl(const plugins::ServiceSpec&) {
    throw SystemError{"Package control is not available", EAGAIN};
  }

  void PackagePort::revokePackage(const plugins::ServiceSpec&) noexcept {}
}

namespace telar::runtime::traffic::recording {

  Owner Owner::package(const plugins::ServiceSpec& package) {
    return {package.plugin_id, package.digest, package.permission};
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

  template <ConcurrentAllocator Memory>
  Service<Memory>::Peer::Peer(SensitiveMemory& memory, FileDescriptor socket, uid_t uid)
      : socket(std::move(socket)),
        uid(uid),
        input(AllocatorRef<Byte, SensitiveMemory>{memory}) {}

  template <ConcurrentAllocator Memory>
  Service<Memory>::Service(Memory& memory, std::string_view path, bool allow_interception)
      : upstream_(memory),
        memory_(memory),
        listener_(path),
        interception_(memory),
        http_interception_(memory, &interception_.completionSignal(), &interception_.requestSignal()),
        analysis_(memory),
        recordings_(memory),
        allow_interception_(allow_interception) {
    randomBytes(&session_, sizeof(session_));
    thread_ = startThread("Start traffic service", [this] {
      run();
    });
  }

  template <ConcurrentAllocator Memory>
  Service<Memory>::~Service() {
    stopping_.store(true, std::memory_order_release);
    wake_.notify();
    thread_.join();
  }

  template <ConcurrentAllocator Memory>
  bool Service<Memory>::listening() const noexcept {
    return exchange_subscribers_.load(std::memory_order_acquire) != 0 || recordings_.selects(Selection::exchanges);
  }

  template <ConcurrentAllocator Memory>
  tbc::view<std::span<const Byte>, tbc::lt::a> Service<Memory>::recording(const recording::Request& request, tbc::view<std::span<Byte>, tbc::lt::a> output, recording::Owner owner) {
    return recordings_.handle(request, output, std::move(owner));
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::packageControl(control::PackagePort* port) noexcept {
    package_control_.store(port, std::memory_order_release);
  }

  template <ConcurrentAllocator Memory>
  FileDescriptor Service<Memory>::openControl(const plugins::ServiceSpec& package) {
    const auto port = package_control_.load(std::memory_order_acquire);
    if (!port) {
      throw SystemError{"Package control is starting", EAGAIN};
    }

    return port->openPackage(package);
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::revokePackage(const plugins::ServiceSpec& package) noexcept {
    recordings_.revoke(recording::Owner::package(package));
  }

  template <ConcurrentAllocator Memory>
  PackageChannel Service<Memory>::openPackage(const plugins::ServiceSpec& specification, std::uint32_t registration) {
    const bool observe = specification.allows(plugins::Capability::traffic_observe);
    const bool intercept = specification.allows(plugins::Capability::traffic_intercept);
    if ((!observe && !intercept) || specification.plugin_id == 0 || specification.generation == 0) {
      throw EncodingError{"Package has no granted traffic capability"};
    }

    std::array<int, 2> descriptors;
    if (::socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors.data()) != 0) {
      throw SystemError{"Create package traffic channel"};
    }

    FileDescriptor native{descriptors[0]}, client{descriptors[1]};

    configureProxySocket(native.get());
    configureProxySocket(client.get());
    const auto order = (static_cast<std::uint64_t>(specification.package_index) << 32) | registration;
    const auto owner = ++next_owner_;
    if (!attachments_.publish(Attachment{std::move(native), {specification.plugin_id, specification.digest, specification.generation, observe, intercept, order, specification.permission}, owner})) {
      throw SystemError{"Package traffic attachment queue is full", EBUSY};
    }

    wake_.notify();
    return {std::move(client), owner};
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::setPackageAvailable(std::uint64_t owner, bool available) noexcept {
    interception_.setAvailable(owner, available);
    http_interception_.setAvailable(owner, available);
  }

  template <ConcurrentAllocator Memory>
  bool Service<Memory>::packagePending(std::uint64_t owner, std::uint64_t ticket, bool http) noexcept {
    return http ? http_interception_.pending(owner, ticket) : interception_.pending(owner, ticket);
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::packageFailure(const plugins::ServiceSpec& specification, FlowEvent event) noexcept {
    std::array<char, 128> reason;
    const auto name = specification.name.view();
    const auto length = std::snprintf(reason.data(), reason.size(), "app_callback_error:%.*s", static_cast<int>(name.size()), name.data());

    event.reason = {reason.data(), length > 0 ? std::min(static_cast<std::size_t>(length), reason.size() - 1) : 0};
    event.bytes = {};
    observeFlow(Kind::flow_error, event);
  }

  template <ConcurrentAllocator Memory>
  auto Service<Memory>::captureStatus() const noexcept -> CaptureStatus {
    std::lock_guard lock{capture_mutex_};

    return capture_status_;
  }

  template <ConcurrentAllocator Memory>
  std::uint64_t Service<Memory>::stopCapture() noexcept {
    const auto revision = capture_stop_.fetch_add(1, std::memory_order_release) + 1;

    wake_.notify();
    return revision;
  }

  template <ConcurrentAllocator Memory>
  bool Service<Memory>::captureStopped(std::uint64_t revision) const noexcept {
    return capture_stopped_.load(std::memory_order_acquire) >= revision;
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::submit(CapturedExchange<Memory>& exchange) noexcept {
    if (!listening()) {
      return;
    }

    try {
      SensitiveBuffer<Limits::frame_bytes> output;
      const auto sequence = next_exchange_.fetch_add(1, std::memory_order_relaxed);
      const auto payload = plugins::Protocol::encodeExchange(output.bytes(), {sequence, session_}, exchange, Limits::http_part_bytes);
      auto frame = encode(Event{.kind = Kind::exchange, .session = session_, .sequence = sequence, .bytes = payload});

      injections_.publish(std::move(frame));
      wake_.notify();
    } catch (const std::exception&) {
      allocation_drops_.fetch_add(1, std::memory_order_relaxed);
    }
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::observeFlow(Kind kind, const FlowEvent& flow) noexcept {
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

  template <ConcurrentAllocator Memory>
  std::uint64_t Service<Memory>::intercept(const FlowEvent& event) noexcept {
    return interception_.begin(event);
  }

  template <ConcurrentAllocator Memory>
  auto Service<Memory>::poll(std::uint64_t ticket, std::span<Byte> replacement) noexcept -> Decision {
    return interception_.poll(ticket, replacement);
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::cancel(std::uint64_t ticket) noexcept {
    interception_.cancel(ticket);
  }

  template <ConcurrentAllocator Memory>
  auto Service<Memory>::deadline(std::uint64_t ticket) noexcept -> std::optional<Time> {
    return interception_.deadline(ticket);
  }

  template <ConcurrentAllocator Memory>
  int Service<Memory>::descriptor() const noexcept {
    return interception_.descriptor();
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::drain() noexcept {
    interception_.drain();
  }

  template <ConcurrentAllocator Memory>
  HttpControl* Service<Memory>::http() noexcept {
    return allow_interception_ ? this : nullptr;
  }

  template <ConcurrentAllocator Memory>
  HttpPolicy Service<Memory>::policy(const FlowEvent& context) noexcept {
    return http_interception_.policy(context);
  }

  template <ConcurrentAllocator Memory>
  std::uint64_t Service<Memory>::interceptHttp(const FlowEvent& event) noexcept {
    return http_interception_.begin(event);
  }

  template <ConcurrentAllocator Memory>
  auto Service<Memory>::pollHttp(std::uint64_t ticket, std::span<Byte> replacement) noexcept -> Decision {
    return http_interception_.poll(ticket, replacement);
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::cancelHttp(std::uint64_t ticket) noexcept {
    http_interception_.cancel(ticket);
  }

  template <ConcurrentAllocator Memory>
  auto Service<Memory>::httpDeadline(std::uint64_t ticket) noexcept -> std::optional<Time> {
    return http_interception_.deadline(ticket);
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::httpUnavailable(const FlowEvent& event) noexcept {
    observeFlow(Kind::flow_error, event);
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::run() noexcept {
    while (!stopping_.load(std::memory_order_acquire)) {
      try {
        step();
      } catch (const std::exception& error) {
        std::fprintf(stderr, "telar traffic: %s\n", error.what());
      }
    }
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::step() {
    std::array<pollfd, maximum_peers + 3> descriptors{};

    descriptors[0] = {.fd = listener_.descriptor(), .events = POLLIN, .revents = 0};
    descriptors[1] = {.fd = wake_.descriptor(), .events = POLLIN, .revents = 0};
    descriptors[2] = {.fd = interception_.requestDescriptor(), .events = POLLIN, .revents = 0};
    for (std::size_t index = 0; index < peers_.size(); ++index) {
      const auto& peer = peers_[index];

      descriptors[index + 3] = {.fd = peer ? peer->socket.get() : -1, .events = static_cast<short>(POLLIN | (peer && peer->count ? POLLOUT : 0)), .revents = 0};
    }

    constexpr int heartbeat_ms = 1000;
    const auto result = ::poll(descriptors.data(), descriptors.size(), heartbeat_ms);
    if (result < 0 && sys::lastError() != EINTR) {
      throw SystemError{"Poll traffic sockets"};
    }

    if (stopping_.load(std::memory_order_acquire)) {
      return;
    }

    const auto stop_capture = capture_stop_.load(std::memory_order_acquire);
    if (stop_capture != capture_stopped_.load(std::memory_order_relaxed)) {
      for (auto& peer : peers_) {
        if (peer && (peer->role == Role::live_capture || peer->role == Role::offline_capture)) {
          peer->failed = true;
        }
      }
    }

    if (descriptors[1].revents & POLLIN) {
      wake_.drain();
      while (auto attachment = attachments_.tryReceive()) {
        for (auto& slot : peers_) {
          if (!slot) {
            slot.emplace(memory_, std::move(attachment->socket), ::geteuid());
            slot->package = attachment->package;
            slot->owner = attachment->owner;
            break;
          }
        }
      }

      while (auto frame = injections_.tryReceive()) {
        const auto event = Protocol::decode((*frame)->bytes.bytes());

        publish(event, std::move(*frame));
      }
    }

    if (descriptors[2].revents & POLLIN) {
      interception_.drainRequests();
    }

    for (std::size_t index = 0; index < peers_.size(); ++index) {
      auto& peer = peers_[index];
      if (!peer) {
        continue;
      }

      const auto ready = descriptors[index + 3].revents;

      try {
        if (ready & (POLLIN | POLLHUP)) {
          read(*peer);
        }

        if (ready & POLLOUT) {
          write(*peer);
        }
      } catch (const std::exception&) {
        peer->failed = true;
      }

      constexpr auto handshake_timeout = std::chrono::seconds{5};
      const bool expired = !peer->role && std::chrono::steady_clock::now() - peer->connected >= handshake_timeout;
      if (peer->failed || expired || (ready & (POLLERR | POLLNVAL))) {
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
        if (producer) {
          producer_ = false;
          {
            std::lock_guard lock{capture_mutex_};

            capture_status_ = {};
          }

          analysis_.expire([&](const Event& event) {
            publish(event);
          },
              true);
          publish(Event{.kind = Kind::capture_stopped});
        }
      }
    }

    capture_stopped_.store(stop_capture, std::memory_order_release);

    if (descriptors[0].revents & POLLIN) {
      accept();
    }

    for (auto& peer : peers_) {
      if (!peer || peer->failed || !peer->configured || peer->role != Role::intercept) {
        continue;
      }

      auto deliver = [&](const FlowEvent& flow) {
        if (peer->count == peer->queue.size()) {
          return false;
        }

        SensitiveAllocation output{upstream_, flow.bytes.size() + Limits::metadata_bytes};
        const auto payload = FlowCodec::encode(output.bytes(), flow);
        const auto now = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::system_clock::now().time_since_epoch()).count();

        enqueue(*peer, encode(Event{.kind = peer->http ? Kind::http_intercept_request : Kind::intercept_request, .session = session_, .sequence = next_exchange_.fetch_add(1, std::memory_order_relaxed), .timestamp_us = static_cast<std::uint64_t>(now), .bytes = payload}));
        return true;
      };

      if (peer->http) {
        http_interception_.deliver(peer->owner, deliver);
      } else {
        interception_.deliver(peer->owner, deliver);
      }
    }

    const auto now = std::chrono::steady_clock::now();
    if (now - heartbeat_ >= std::chrono::seconds{1}) {
      analysis_.expire([&](const Event& event) {
        publish(event);
      });

      recordings_.expire();
      publish(Event{.kind = Kind::statistics, .runtime_drops = injections_.metrics().dropped + allocation_drops_.load(std::memory_order_relaxed)});
      heartbeat_ = now;
    }
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::accept() {
    auto socket = listener_.accept(LocalPeerPolicy::same_user_or_root);
    if (!socket) {
      return;
    }

    const auto credentials = peerCredentials(socket.get());
    if (!credentials) {
      return;
    }

    for (auto& slot : peers_) {
      if (!slot) {
        slot.emplace(memory_, std::move(socket), credentials->user);
        return;
      }
    }
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::read(Peer& peer) {
    constexpr std::size_t frames_per_tick = 32;

    for (std::size_t frame = 0; frame < frames_per_tick; ++frame) {
      const auto previous = peer.input.size();

      peer.input.resize(peer.expected);
      const auto count = ::recv(peer.socket.get(), peer.input.data() + previous, peer.expected - previous, 0);
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

      if (!peer.role) {
        if (!greet(peer)) {
          continue;
        }
      } else {
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
          continue;
        }

        if (*peer.role == Role::intercept) {
          control(peer);
          peer.input.clear();
          peer.expected = Protocol::prefix_bytes;
          continue;
        }

        auto event = Protocol::decode(peer.input);
        if (event.kind >= Kind::exchange) {
          throw EncodingError{"Capture helpers cannot publish decrypted exchanges"};
        }

        event.offline = *peer.role == Role::offline_capture;
        if (event.kind != Kind::packet) {
          std::lock_guard lock{capture_mutex_};

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
        if (event.kind == Kind::packet) {
          const bool flows = flow_subscribers_.load(std::memory_order_acquire) != 0 || recordings_.selects(Selection::flows);
          const bool datagrams = datagram_subscribers_.load(std::memory_order_acquire) != 0 || recordings_.selects(Selection::datagrams);
          if (flows || datagrams) {
            const auto selected = static_cast<Selection>((flows ? static_cast<Byte>(Selection::flows) : 0) | (datagrams ? static_cast<Byte>(Selection::datagrams) : 0));

            analysis_.packet(event, selected, [&](const Event& item) {
              publish(item);
            });
          }
        }
      }

      peer.input.clear();
      peer.expected = Protocol::prefix_bytes;
    }
  }

  template <ConcurrentAllocator Memory>
  bool Service<Memory>::greet(Peer& peer) {
    if (peer.package && peer.package->permission && !peer.package->permission->load(std::memory_order_acquire)) {
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
    if (peer.package && !((selected == Role::subscribe && peer.package->observe) || (selected == Role::intercept && peer.package->intercept))) {
      throw EncodingError{"Package traffic capability denied"};
    }

    peer.selection = static_cast<Selection>(selection);
    if (selected == Role::subscribe) {
      const auto subscribers = std::ranges::count_if(peers_, [](const auto& slot) {
        return slot && slot->role == Role::subscribe;
      });
      if (static_cast<std::size_t>(subscribers) >= Limits::subscribers || peer.uid != ::geteuid()) {
        throw EncodingError{"Traffic subscription is unavailable"};
      }

      peer.filter.emplace(std::string_view{reinterpret_cast<const char*>(input.data()), input.size()});
      if (selects(peer.selection, Selection::flows)) {
        flow_subscribers_.fetch_add(1, std::memory_order_release);
      }

      if (selects(peer.selection, Selection::datagrams)) {
        datagram_subscribers_.fetch_add(1, std::memory_order_release);
      }

      if (selects(peer.selection, Selection::exchanges)) {
        exchange_subscribers_.fetch_add(1, std::memory_order_release);
      }
    } else if (selected == Role::intercept) {
      const auto controllers = std::ranges::count_if(peers_, [](const auto& slot) {
        return slot && slot->role == Role::intercept;
      });
      if (!allow_interception_ || static_cast<std::size_t>(controllers) >= Limits::subscribers || size != 0 || peer.uid != ::geteuid()) {
        throw EncodingError{"Stream interception is unavailable"};
      }

      if (peer.owner == 0) {
        peer.owner = ++next_owner_;
      }
    } else {
      if (producer_ || size != 0 || (selected == Role::live_capture && peer.uid != 0)) {
        throw EncodingError{"Traffic capture requires one authorized helper"};
      }

      producer_ = true;
    }

    peer.role = selected;
    enqueue(peer, encode(Event{.kind = Kind::ready}));
    if (selected == Role::live_capture || selected == Role::offline_capture) {
      {
        std::lock_guard lock{capture_mutex_};

        capture_status_ = {.state = selected == Role::live_capture ? CaptureState::live : CaptureState::offline};
      }

      publish(Event{.kind = Kind::capture_started, .offline = selected == Role::offline_capture});
    }

    return true;
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::control(Peer& peer) {
    if (peer.package && peer.package->permission && !peer.package->permission->load(std::memory_order_acquire)) {
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

  template <ConcurrentAllocator Memory>
  auto Service<Memory>::encode(const Event& event) -> std::shared_ptr<Frame> {
    auto frame = std::allocate_shared<Frame>(AllocatorRef<Frame, SensitiveMemory>{memory_}, upstream_, Protocol::encodedSize(event));

    Protocol::encode(frame->bytes.bytes(), event);
    return frame;
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::publish(const Event& event, std::shared_ptr<Frame> shared) {
    shared = recordings_.record(event, std::move(shared));
    for (auto& peer : peers_) {
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

        if (peer->filter && !peer->filter->matches(event)) {
          continue;
        }

        if (!shared) {
          shared = encode(event);
        }

        enqueue(*peer, shared);
      } catch (const std::exception&) {
        peer->failed = true;
      }
    }
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::enqueue(Peer& peer, std::shared_ptr<Frame> frame) {
    if (peer.count == peer.queue.size()) {
      ++peer.dropped;
      return;
    }

    auto& delivery = peer.queue[(peer.head + peer.count) % peer.queue.size()];

    delivery.prefix = Protocol::prefix(frame->bytes.bytes().size(), peer.dropped);
    delivery.frame = std::move(frame);
    delivery.offset = 0;
    ++peer.count;
  }

  template <ConcurrentAllocator Memory>
  void Service<Memory>::write(Peer& peer) {
    for (std::size_t round = 0; round < Limits::pending_frames && peer.count != 0; ++round) {
      auto& delivery = peer.queue[peer.head];
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

  template <Allocator Memory>
  TrustCommand<Memory>::TrustCommand(Memory& memory, const std::atomic<bool>& cancelled) noexcept
      : memory_(memory),
        cancelled_(cancelled) {}

  template <Allocator Memory>
  void TrustCommand<Memory>::run(std::span<const std::string_view> arguments) {
    bool allowed = !arguments.empty() && arguments.front() == "/usr/bin/security";
#if defined(__linux__)
    constexpr std::array executables{"/usr/bin/trust", "/usr/bin/install", "/usr/bin/rm", "/usr/sbin/update-ca-certificates"};
    allowed = arguments.size() >= 3 && arguments[0] == "/usr/bin/sudo" && arguments[1] == "--" && std::ranges::find(executables, arguments[2]) != executables.end();
#endif
    if (!allowed) {
      throw std::invalid_argument{"Invalid trust operation"};
    }

    Command command{memory_, Launch{.arguments = arguments}, CommandPurpose::administration};
    CommandOutput output{memory_, Limits::reply_bytes, &cancelled_};
    if (output.run(command, std::chrono::steady_clock::now() + std::chrono::seconds{10}, true) != 0) {
      throw SystemError{"Certificate store operation failed", EACCES};
    }
  }
}

namespace telar::runtime::traffic {

  template class Service<ConcurrentMemory>;
  template class Interception<ConcurrentMemory>;

}

namespace telar::runtime::traffic::control {

  template class TrustCommand<ConcurrentMemory>;

}

namespace telar::runtime::traffic {

  template class Interception<ConcurrentMemory, HttpMessageLimits::message_bytes>;

}
