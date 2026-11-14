module;
#include "tbc/annotations.hpp"

export module telar.runtime.traffic.control_backend;

import std;
import telar.native.brotli;
import telar.native.nghttp2;
import telar.native.pcap;
import telar.native.zlib;
import telar.native.zstd;
import telar.platform.sha256;
import telar.sys.socket;
import telar.sys.process;
import telar.sys.posix;
import telar.tbc;

export import telar.runtime.traffic.control_protocol;

export import telar.base.memory.allocators;
export import telar.base.memory.containers;
export import telar.base.memory.sensitive;
export import telar.config.runtime;

export import telar.runtime.vocabulary.traffic;
export import telar.runtime.traffic.capture;

export import telar.runtime.platform.local_listener;
export import telar.runtime.platform.signals;
export import telar.runtime.traffic.capture_analysis;

export import telar.runtime.redirect.socket_owners;
export import telar.runtime.redirect.ingress;
import telar.base.diagnostics;
import telar.tls;
import telar.wire.vocabulary;
import telar.platform.primitives;
import telar.platform.error;
import telar.platform.net;
import telar.platform.process;
import telar.platform.thread;
import telar.runtime.platform.request_worker;
import telar.base.text;

// Interface: traffic/control_access.cppm
export {
  namespace telar::runtime::traffic::control {

    bool authorized(const plugins::ServiceSpec& package, const Request& request) noexcept;

    class PackagePort {
    public:
      virtual ~PackagePort() = default;
      virtual FileDescriptor openPackage(const plugins::ServiceSpec& package) = 0;
    };

  }
}

// Interface: traffic/interception.cppm
export {
  namespace telar::runtime::traffic {

    inline constexpr std::uint32_t default_timeout_ms = 1000;
    inline constexpr std::uint32_t maximum_timeout_ms = 30000;

    struct InterceptionRule {
      std::string_view host;
      Byte directions = 3;
      Byte visibility = 2;
      std::uint32_t timeout_ms = default_timeout_ms;
      bool fail_closed = false;
      bool http = false;
    };

    class InterceptionCodec {
    public:
      enum class Command : Byte {
        rule = 1,
        decision = 2,
        http_rule = 3,
      };

      static auto rule(tbc::view<std::span<Byte>, tbc::lt::a> output, InterceptionRule rule) -> tbc::view<std::span<const Byte>, tbc::lt::a>;

      static auto readRule(plugins::FrameReader& reader) -> InterceptionRule;

      static auto decision(tbc::view<std::span<Byte>, tbc::lt::a> output, std::uint64_t ticket, Verdict verdict, std::span<const Byte> bytes = {}) -> tbc::view<std::span<const Byte>, tbc::lt::a>;
    };

    // Each chunk snapshots registration order. A new ticket authenticates every step of the chain.
    // Decides intercepted exchanges with the hooks registered for them. Proxy threads offer exchanges and
    // the control thread decides them, at once, under its mutex.
    template <std::size_t maximum_bytes = FlowControl::chunk_bytes>
    class TBC_SHARED Interception {
      using Secure = ErasingAllocator<ConcurrentMemory>;
      using Owner = std::uint64_t;

      struct Route {
        Owner owner;
        std::uint64_t generation;
        std::uint32_t timeout_ms;
        bool fail_closed;
        std::uint64_t order;
      };

      struct Registration {
        Registration(ConcurrentMemory& memory, Owner owner, InterceptionRule rule, std::uint64_t generation, std::uint64_t order);

        Route route;
        ProxyHostPolicy<ConcurrentMemory> hosts;
        Byte directions;
        Byte visibility;
        bool available = true;
      };

      struct Pending {
        Pending(Secure& memory, std::uint64_t ticket, const FlowEvent& event, std::span<const Route> matches);

        auto event() const noexcept -> FlowEvent;

        std::uint64_t ticket;
        std::uint64_t decision_ticket;
        std::uint64_t id;
        std::uint64_t offset;
        Direction direction;
        Visibility visibility;
        FlowSource source;
        FlowControl::Time deadline{};
        SensitiveText<128> client, server, reason;
        SensitiveText<253> host;
        Verdict verdict = Verdict::pending;
        Vector<Byte, Secure> bytes;
        std::array<Route, Limits::subscribers> chain;
        std::size_t routes;
        std::size_t step = 0;
        bool replaced = false;
        bool delivered = false;
      };

      using Registrations = std::array<std::optional<Registration>, Limits::subscribers>;

    public:
      explicit Interception(ConcurrentMemory& memory, CompletionSignal* completion = nullptr, CompletionSignal* requests = nullptr);

      void configure(InterceptionRule rule);

      auto policy(const FlowEvent& event) noexcept -> HttpPolicy;

      void configure(Owner owner, InterceptionRule rule, std::uint64_t order = std::numeric_limits<std::uint64_t>::max());

      void disconnect(Owner owner = default_owner) noexcept;

      void setAvailable(Owner owner, bool available) noexcept;

      bool pending(Owner owner, std::uint64_t ticket) noexcept;

      auto begin(const FlowEvent& event) noexcept -> std::uint64_t;

      void decide(std::uint64_t ticket, Verdict verdict, std::span<const Byte> bytes);

      void decide(Owner owner, std::uint64_t ticket, Verdict verdict, std::span<const Byte> bytes);

      auto poll(std::uint64_t ticket, std::span<Byte> replacement) noexcept -> FlowControl::Decision;

      auto pending(std::uint64_t ticket) noexcept -> bool;

      // The service queues requests on its own thread, without a lossy cross-thread channel.
      template <typename Consumer>
      TBC_HOT_PATH void deliver(Owner owner, Consumer&& consumer) noexcept {
        std::scoped_lock lock{mutex_};

        for (auto& slot : pending_) {
          if (!slot || slot->verdict != Verdict::pending || slot->chain[slot->step].owner != owner || slot->delivered) {
            continue;
          }

          if (std::chrono::steady_clock::now() >= slot->deadline) {
            advance(*slot, failure(*slot), registrations_, next_, completion_, request_signal_);
            continue;
          }

          try {
            if (consumer(slot->event())) {
              slot->delivered = true;
            } else {
              advance(*slot, failure(*slot), registrations_, next_, completion_, request_signal_);
            }
          } catch (...) {
            advance(*slot, failure(*slot), registrations_, next_, completion_, request_signal_);
          }
        }
      }

      int requestDescriptor() const noexcept;

      void drainRequests() noexcept;

      auto completionSignal() noexcept -> CompletionSignal&;

      auto requestSignal() noexcept -> CompletionSignal&;

      void cancel(std::uint64_t ticket) noexcept;

      std::optional<FlowControl::Time> deadline(std::uint64_t ticket) noexcept;

      int descriptor() const noexcept;

      void drain() noexcept;

      static constexpr std::uint64_t rejected_ticket = std::numeric_limits<std::uint64_t>::max();

    private:
      auto registration(Owner owner) noexcept -> Registration*;

      static auto registration(const Registrations& registrations, Owner owner) noexcept -> const Registration*;

      static Verdict failure(const Pending& pending) noexcept;

      // Moves an exchange to its next hook, or settles it. The tables it reads are lent apart from it.
      static void advance(Pending& pending, Verdict verdict, const Registrations& registrations, std::uint64_t& next, CompletionSignal& completion, CompletionSignal& requests) noexcept;

      static constexpr Owner default_owner = 1;
      ConcurrentMemory& upstream_;
      Secure memory_;
      std::mutex mutex_;
      Registrations registrations_;
      std::array<std::optional<Pending>, 64> pending_;
      CompletionSignal wake_;
      CompletionSignal requests_;
      CompletionSignal& completion_;
      CompletionSignal& request_signal_;
      std::uint64_t generation_ = 0;
      std::uint64_t next_ = 0;
      std::atomic<std::size_t> active_{0};
    };

    extern template class Interception<HttpMessageLimits::message_bytes>;

    extern template class Interception<>;

  }
}

// Interface: traffic/package_port.cppm
export {
  namespace telar::runtime::traffic {

    struct PackageChannel {
      FileDescriptor socket;
      std::uint64_t owner;

      int get() const noexcept;
    };

    // Only native runtime code can attach a package. Lua never supplies this grant
    // or opens the authenticated endpoint; each registration gets its own channel.
    // Package workers call it from their own threads, so an implementation is synchronized.
    class TBC_SHARED PackagePort {
    public:
      virtual ~PackagePort() = default;
      virtual PackageChannel openPackage(const plugins::ServiceSpec& specification, std::uint32_t registration = 0) = 0;
      virtual void setPackageAvailable(std::uint64_t owner, bool available) noexcept = 0;
      virtual bool packagePending(std::uint64_t owner, std::uint64_t ticket, bool http) noexcept = 0;

      virtual void packageFailure(const plugins::ServiceSpec&, FlowEvent) noexcept;

      virtual FileDescriptor openControl(const plugins::ServiceSpec&);

      virtual void revokePackage(const plugins::ServiceSpec&) noexcept;
    };

  }
}

// Interface: traffic/recording_owner.cppm
export {
  namespace telar::runtime::traffic::recording {

    struct Owner {
      std::uint64_t id = 0;
      plugins::PackageDigest digest{};
      std::shared_ptr<std::atomic<bool>> permission;

      static Owner package(const plugins::ServiceSpec& package);

      bool authorized() const noexcept;

      bool matches(const Owner& other) const noexcept;

      bool canRead(const Owner& other) const noexcept;
    };

  }
}

// Interface: traffic/recordings.cppm
export {
  namespace telar::runtime::traffic {

    // Recording sessions proxy threads append to and clients page through, under its mutex.
    // Generic over the caller's clock.
    template <typename Clock = std::chrono::steady_clock>
    class TBC_SHARED TBC_HOT_PATH Recordings {
      using Request = recording::Request;

      struct Entry {
        std::uint64_t cursor;
        typename Clock::time_point created;
        std::shared_ptr<EventFrame> frame;
      };

      struct Session {
        inline explicit Session(ConcurrentMemory& memory, const Request& request, std::uint64_t id, recording::Owner owner)
            : id(id),
              owner(std::move(owner)),
              budget(request.max_bytes),
              age(request.max_age_ms),
              selection(request.selection),
              filter(request.filter),
              host(memory),
              entries(AllocatorRef<std::optional<Entry>, ConcurrentMemory>{memory}) {
          if (!request.host.empty() && !host.append(request.host)) {
            throw EncodingError{"Invalid recording host scope"};
          }

          host.finish();
          entries.resize(request.max_events);
          bytes = entries.capacity() * sizeof(std::optional<Entry>);
          if (bytes >= budget) {
            throw EncodingError{"Recording budget cannot hold its event index"};
          }
        }

        inline Entry& at(std::size_t index) {
          return *entries[(head + index) % entries.size()];
        }

        inline void evict() noexcept {
          bytes -= at(0).frame->bytes.bytes().size();
          entries[head].reset();
          head = (head + 1) % entries.size();
          --count;
          ++evicted;
        }

        inline void expire(typename Clock::time_point now) noexcept {
          while (count != 0 && now - at(0).created >= age) {
            evict();
          }
        }

        std::uint64_t id;
        recording::Owner owner;
        std::size_t budget;
        std::chrono::milliseconds age;
        Selection selection;
        Filter filter;
        ProxyHostPolicy<ConcurrentMemory> host;
        Vector<std::optional<Entry>, ConcurrentMemory> entries;
        std::size_t bytes = 0;
        std::size_t head = 0;
        std::size_t count = 0;
        std::uint64_t next = 1;
        std::uint64_t evicted = 0;
        std::uint64_t dropped = 0;
        bool active = true;
      };

    public:
      // Frames it records come from its allocator, region `a`.
      inline explicit Recordings(tbc::view<ConcurrentMemory&, tbc::lt::a> memory) noexcept
          : memory_(memory) {
        randomBytes(&next_id_, sizeof(next_id_));
      }

      inline bool selects(Selection selection) const noexcept {
        return (interest_.load(std::memory_order_acquire) & static_cast<Byte>(selection)) != 0;
      }

      // The frame recorded: the one given, or one allocated here.
      inline tbc::view<std::shared_ptr<EventFrame>, tbc::lt::a> record(const Event& event, tbc::view<std::shared_ptr<EventFrame>, tbc::lt::a> shared = {}) noexcept {
        if (!selected(Selection::all, event.kind) || interest_.load(std::memory_order_acquire) == 0) {
          return shared;
        }

        const std::unique_lock lock{mutex_, std::try_to_lock};
        if (!lock.owns_lock()) {
          contention_drops_.fetch_add(1, std::memory_order_relaxed);
          return shared;
        }

        const auto now = Clock::now();

        for (auto& slot : sessions_) {
          if (!slot || !slot->active || !slot->owner.authorized() || !selected(slot->selection, event.kind)) {
            continue;
          }

          auto& session = *slot;

          session.expire(now);
          try {
            if (!session.filter.matches(event) || !matches(session.host, event)) {
              continue;
            }

            const auto size = Protocol::encodedSize(event);
            const auto index_bytes = session.entries.capacity() * sizeof(std::optional<Entry>);
            if (size > session.budget - index_bytes || session.next == std::numeric_limits<std::uint64_t>::max()) {
              ++session.dropped;
              continue;
            }

            while (session.count != 0 && (session.count == session.entries.size() || size > session.budget - session.bytes)) {
              session.evict();
            }

            if (!shared) {
              shared = std::allocate_shared<EventFrame>(AllocatorRef<EventFrame, ConcurrentMemory>{memory_}, memory_, size);
              Protocol::encode(shared->bytes.bytes(), event);
            }

            session.entries[(session.head + session.count) % session.entries.size()].emplace(Entry{session.next++, now, shared});
            ++session.count;
            session.bytes += size;
          } catch (...) {
            ++session.dropped;
          }
        }

        return shared;
      }

      inline void expire() noexcept {
        const std::unique_lock lock{mutex_, std::try_to_lock};
        if (!lock.owns_lock()) {
          return;
        }

        for (auto& session : sessions_) {
          if (session) {
            session->expire(Clock::now());
          }
        }
      }

      inline void revoke(const recording::Owner& owner) noexcept {
        const std::lock_guard lock{mutex_};

        for (auto& session : sessions_) {
          if (session && owner.matches(session->owner)) {
            session->active = false;
          }
        }

        refreshInterest();
      }

      // The page written views the output, region `b`; the recordings keep none of it.
      inline tbc::view<std::span<const Byte>, tbc::lt::b> handle(const Request& request, tbc::view<std::span<Byte>, tbc::lt::b> output, recording::Owner owner = {}) {
        if (output.size() < recording::Protocol::page_header_bytes) {
          throw EncodingError{"Recording output is too small"};
        }

        std::array<Byte, 8192> validation;
        plugins::FrameWriter validated{validation};

        recording::Protocol::write(validated, request);
        ProxyHostPolicy scope{memory_};
        if (!request.host.empty() && !scope.append(request.host)) {
          throw EncodingError{"Invalid recording query host"};
        }

        scope.finish();
        const std::lock_guard lock{mutex_};

        if (!owner.authorized()) {
          throw EncodingError{"Recording package permission has been revoked"};
        }

        if (request.operation == recording::Operation::list) {
          output = output.first(std::min(output.size(), recording::Limits::page_bytes));
          plugins::FrameWriter rows{output.subspan(recording::Protocol::page_header_bytes)};
          recording::Page page{.format = recording::Format::list};

          for (auto& slot : sessions_) {
            if (!slot || !owner.canRead(slot->owner)) {
              continue;
            }

            slot->expire(Clock::now());
            std::array<Byte, recording::Protocol::page_header_bytes> bytes;
            plugins::FrameWriter child{bytes};

            recording::Protocol::header(child, describe(*slot, contention_drops_.load(std::memory_order_relaxed)));
            rows.bytes(child.finish());
            ++page.count;
          }

          plugins::FrameWriter header{output.first(recording::Protocol::page_header_bytes)};

          recording::Protocol::header(header, page);
          return output.first(header.finish().size() + rows.finish().size());
        }

        Session* session = nullptr;

        if (request.operation == recording::Operation::start) {
          std::uint64_t reserved = request.max_bytes;

          for (const auto& existing : sessions_) {
            if (existing) {
              reserved += existing->budget;
            }
          }

          if (reserved > recording::Limits::total_bytes) {
            throw EncodingError{"Recording runtime budget exhausted"};
          }

          for (auto& slot : sessions_) {
            if (slot) {
              continue;
            }

            if (++next_id_ == 0) {
              ++next_id_;
            }

            slot.emplace(memory_, request, next_id_, owner);
            session = &*slot;
            break;
          }

          if (!session) {
            throw EncodingError{"Recording session limit reached"};
          }

          refreshInterest();
        } else {
          for (auto& slot : sessions_) {
            if (slot && slot->id == request.id && owner.canRead(slot->owner)) {
              session = &*slot;
              break;
            }
          }

          if (!session) {
            throw EncodingError{"Unknown or expired recording identity"};
          }
        }

        session->expire(Clock::now());
        if (request.operation == recording::Operation::stop) {
          session->active = false;
          refreshInterest();
        }

        auto page = describe(*session, contention_drops_.load(std::memory_order_relaxed));

        output = output.first(std::min(output.size(), recording::Limits::page_bytes));
        if (output.size() < recording::Protocol::page_header_bytes) {
          throw EncodingError{"Recording output is too small"};
        }

        plugins::FrameWriter rows{output.subspan(recording::Protocol::page_header_bytes)};

        if (request.operation == recording::Operation::query || request.operation == recording::Operation::pcapng) {
          if (request.cursor > session->next) {
            throw EncodingError{"Recording cursor is beyond the current end"};
          }

          page.gap = request.cursor != 0 && request.cursor < page.oldest;
          page.next = request.cursor == 0 ? page.oldest : std::max(request.cursor, page.oldest);
          const bool pcapng = request.operation == recording::Operation::pcapng;

          page.format = pcapng ? recording::Format::pcapng : recording::Format::events;
          if (pcapng) {
            Pcapng::section(rows);
          }

          for (std::size_t index = 0; index < session->count; ++index) {
            auto& entry = session->at(index);
            if (entry.cursor < page.next) {
              continue;
            }

            const auto event = Protocol::decode(entry.frame->bytes.bytes());
            if (!selected(request.selection, event.kind) || !matches(scope, event) || (pcapng && event.kind != Kind::packet)) {
              page.next = entry.cursor + 1;
              continue;
            }

            const auto size = pcapng ? Pcapng::packetBytes(event) : sizeof(std::uint64_t) + sizeof(std::uint32_t) + entry.frame->bytes.bytes().size();
            if (size > output.size() - recording::Protocol::page_header_bytes - rows.finish().size() || page.count == request.limit) {
              break;
            }

            if (pcapng) {
              Pcapng::packet(rows, event, page.count);
            } else {
              rows.integer(entry.cursor);
              rows.bytes(entry.frame->bytes.bytes());
            }

            ++page.count;
            page.next = entry.cursor + 1;
          }
        }

        if (request.operation == recording::Operation::erase) {
          page.active = false;
          page.bytes = 0;
          for (auto& slot : sessions_) {
            if (slot && &*slot == session) {
              slot.reset();
              break;
            }
          }

          refreshInterest();
        }

        plugins::FrameWriter header{output.first(recording::Protocol::page_header_bytes)};

        recording::Protocol::header(header, page);
        return output.first(header.finish().size() + rows.finish().size());
      }

    private:
      inline static recording::Page describe(Session& session, std::uint64_t contention_drops) noexcept {
        return {
            .id = session.id,
            .active = session.active,
            .oldest = session.count ? session.at(0).cursor : session.next,
            .next = session.next,
            .end = session.next,
            .evicted = session.evicted,
            .dropped = session.dropped,
            .contention_drops = contention_drops,
            .bytes = session.bytes,
        };
      }

      inline static bool selected(Selection selection, Kind kind) noexcept {
        const auto mask = static_cast<Byte>(selection);
        const auto bit = kind == Kind::packet ? Selection::packets : kind == Kind::exchange ? Selection::exchanges
                                                                 : kind == Kind::datagram   ? Selection::datagrams
                                                                                            : Selection::flows;
        const bool public_event = kind == Kind::packet || kind == Kind::exchange || kind == Kind::datagram || (kind >= Kind::flow_open && kind <= Kind::flow_gap);

        return public_event && (mask & static_cast<Byte>(bit)) != 0;
      }

      inline static bool matches(const ProxyHostPolicy<ConcurrentMemory>& scope, const Event& event) {
        if (scope.patterns().empty()) {
          return true;
        }

        if (event.kind == Kind::exchange) {
          return scope.contains(plugins::Protocol::decodeExchange(event.bytes).host);
        }

        if (event.kind >= Kind::flow_open && event.kind <= Kind::flow_gap) {
          return scope.contains(FlowCodec::decode(event.bytes).host);
        }

        return false;
      }

      inline void refreshInterest() noexcept {
        Byte mask = 0;

        for (const auto& session : sessions_) {
          if (session && session->active) {
            mask |= static_cast<Byte>(session->selection);
          }
        }

        interest_.store(mask, std::memory_order_release);
      }

      tbc::view<ConcurrentMemory&, tbc::lt::a> memory_;
      tbc::view<std::array<std::optional<Session>, recording::Limits::sessions>, tbc::lt::a> sessions_;
      std::uint64_t next_id_;
      std::mutex mutex_;
      std::atomic<Byte> interest_{0};
      std::atomic<std::uint64_t> contention_drops_{0};
    };

  }
}

// Interface: traffic/service.cppm
export {
  namespace telar::runtime::traffic {

    // The traffic control service: its own thread serves clients while proxy threads report flows to it.
    class TBC_SHARED Service : public FlowControl, public HttpControl, public PackagePort {
      using SensitiveMemory = ErasingAllocator<ConcurrentMemory>;
      using Bytes = Vector<Byte, SensitiveMemory>;
      static constexpr std::size_t maximum_peers = Limits::subscribers * 2 + 1;

      using Frame = EventFrame;

      struct Delivery {
        std::shared_ptr<Frame> frame;
        std::array<Byte, Protocol::prefix_bytes> prefix;
        std::size_t offset = 0;
      };

      struct Peer {
        explicit Peer(SensitiveMemory& memory, FileDescriptor socket, uid_t uid);

        FileDescriptor socket;
        uid_t uid;
        Bytes input;
        std::optional<Role> role;
        Selection selection = Selection::both;
        std::optional<Filter> filter;
        std::array<Delivery, Limits::pending_frames> queue;
        std::size_t head = 0;
        std::size_t count = 0;
        std::size_t expected = Protocol::greeting_bytes;
        std::uint64_t dropped = 0;
        bool failed = false;
        bool configured = false;
        bool http = false;
        std::uint64_t owner = 0;

        struct PackageIdentity {
          std::uint64_t id;
          plugins::PackageDigest digest;
          std::uint64_t generation;
          bool observe;
          bool intercept;
          std::uint64_t order;
          std::shared_ptr<std::atomic<bool>> permission;
        };

        std::optional<PackageIdentity> package;
        std::chrono::steady_clock::time_point connected = std::chrono::steady_clock::now();
      };

      struct Attachment {
        FileDescriptor socket;
        typename Peer::PackageIdentity package;
        std::uint64_t owner;
      };

    public:
      explicit Service(ConcurrentMemory& memory, std::string_view path, bool allow_interception = false);

      ~Service();

      Service(const Service&) = delete;
      Service& operator=(const Service&) = delete;

      bool listening() const noexcept;

      tbc::view<std::span<const Byte>, tbc::lt::a> recording(const recording::Request& request, tbc::view<std::span<Byte>, tbc::lt::a> output, recording::Owner owner = {});

      void packageControl(control::PackagePort* port) noexcept;

      FileDescriptor openControl(const plugins::ServiceSpec& package) override;

      void revokePackage(const plugins::ServiceSpec& package) noexcept override;

      PackageChannel openPackage(const plugins::ServiceSpec& specification, std::uint32_t registration = 0) override;

      void setPackageAvailable(std::uint64_t owner, bool available) noexcept override;

      bool packagePending(std::uint64_t owner, std::uint64_t ticket, bool http) noexcept override;

      void packageFailure(const plugins::ServiceSpec& specification, FlowEvent event) noexcept override;

      enum class CaptureState : Byte {
        idle,
        live,
        offline,
      };

      struct CaptureStatus {
        CaptureState state;
        std::uint64_t session;
        std::uint32_t interfaces;
        std::uint32_t interface_errors;
      };

      CaptureStatus captureStatus() const noexcept;

      std::uint64_t stopCapture() noexcept;

      bool captureStopped(std::uint64_t revision) const noexcept;

      void submit(CapturedExchange& exchange) noexcept;

      void observeFlow(Kind kind, const FlowEvent& flow) noexcept override;

      std::uint64_t intercept(const FlowEvent& event) noexcept override;

      Decision poll(std::uint64_t ticket, std::span<Byte> replacement) noexcept override;

      void cancel(std::uint64_t ticket) noexcept override;

      std::optional<Time> deadline(std::uint64_t ticket) noexcept override;

      int descriptor() const noexcept override;

      void drain() noexcept override;

      HttpControl* http() noexcept override;

      HttpPolicy policy(const FlowEvent& context) noexcept override;

      std::uint64_t interceptHttp(const FlowEvent& event) noexcept override;

      Decision pollHttp(std::uint64_t ticket, std::span<Byte> replacement) noexcept override;

      void cancelHttp(std::uint64_t ticket) noexcept override;

      std::optional<Time> httpDeadline(std::uint64_t ticket) noexcept override;

      void httpUnavailable(const FlowEvent& event) noexcept override;

    private:
      void run() noexcept;

      void step();

      void accept();

      void read(Peer& peer);

      bool greet(Peer& peer);

      void control(Peer& peer);

      std::shared_ptr<Frame> encode(const Event& event);

      void publish(const Event& event, std::shared_ptr<Frame> shared = {});

      static void enqueue(Peer& peer, std::shared_ptr<Frame> frame);

      static void write(Peer& peer);

      ConcurrentMemory& upstream_;
      SensitiveMemory memory_;
      LocalListener listener_;
      CompletionSignal wake_;
      std::atomic<bool> stopping_{false};
      std::array<std::optional<Peer>, maximum_peers> peers_{};
      std::jthread thread_;
      std::chrono::steady_clock::time_point heartbeat_ = std::chrono::steady_clock::now();
      bool producer_ = false;
      std::atomic<std::uint64_t> next_owner_{0};
      Interception<> interception_;
      Interception<HttpMessageLimits::message_bytes> http_interception_;
      CaptureAnalysis analysis_;
      Recordings<> recordings_;
      bool allow_interception_;
      DropChannel<std::shared_ptr<Frame>, Limits::pending_frames> injections_;
      DropChannel<Attachment, Limits::subscribers, ChannelPolicy::keep_oldest> attachments_;
      std::atomic<std::uint64_t> exchange_subscribers_{0};
      std::atomic<std::uint64_t> flow_subscribers_{0};
      std::atomic<std::uint64_t> datagram_subscribers_{0};
      std::atomic<std::uint64_t> allocation_drops_{0};
      std::atomic<std::uint64_t> next_exchange_{1};
      mutable std::mutex capture_mutex_;
      CaptureStatus capture_status_{};
      std::atomic<std::uint64_t> capture_stop_{0};
      std::atomic<std::uint64_t> capture_stopped_{0};
      std::uint64_t session_ = 0;
      std::atomic<control::PackagePort*> package_control_{nullptr};
    };

  }
}

// Interface: traffic/control_backend.cppm
export {
  namespace telar::runtime::traffic::control {

    class TrustCommand : public proxy_trust::TrustCommandRunner {
    public:
      explicit TrustCommand(ConcurrentMemory& memory, const std::atomic<bool>& cancelled) noexcept;

      void run(std::span<const std::string_view> arguments) override;

    private:
      ConcurrentMemory& memory_;
      const std::atomic<bool>& cancelled_;
    };

    struct Configuration {
      std::string_view endpoint;
      std::string_view executable;
      bool proxy = false;
      bool redirect = false;
      bool transparent_tls = false;
      bool interception = false;
      bool administration = false;
    };

    // Generic over the caller's proxy.
    template <typename Proxy>
    class TBC_HOT_PATH Backend {
      using Clock = std::chrono::steady_clock;

    public:
      // What it keeps of its owner, and what its replies view of it, is region `a`.
      inline explicit Backend(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, tbc::view<Proxy&, tbc::lt::a> proxy, tbc::view<traffic::Service*, tbc::lt::a> capture, tbc::view<Configuration, tbc::lt::a> configuration)
          : memory_(memory),
            proxy_(proxy),
            capture_(capture),
            configuration_(configuration) {}

      inline ~Backend() {
        capture_cancelled_ = true;
        redirect_cancelled_ = true;
        if (capture_child_ > 0 && capture_) {
          capture_->stopCapture();
        }

        if (redirect_child_ > 0) {
          proxy_.stopRedirect();
        }

        const auto deadline = Clock::now() + std::chrono::seconds{5};

        while ((capture_child_ > 0 || redirect_child_ > 0) && Clock::now() < deadline) {
          tick();
          ::poll(nullptr, 0, 5);
        }
      }

      inline void tick() noexcept {
        reap(capture_child_);
        reap(redirect_child_);
        if (capture_cancelled_ && capture_child_ > 0 && capture_ && capture_->captureStatus().state != traffic::Service::CaptureState::idle) {
          capture_->stopCapture();
        }

        if (redirect_cancelled_ && redirect_child_ > 0) {
          const auto state = proxy_.redirectStatus();
          if (state == redirect::MonitorState::starting || state == redirect::MonitorState::active) {
            proxy_.stopRedirect();
          }
        }
      }

      inline tbc::view<std::span<const Byte>, tbc::lt::a> handle(const Request& request, tbc::view<std::span<Byte>, tbc::lt::a> output, const std::atomic<bool>& cancelled, const plugins::ServiceSpec* package = nullptr) {
        Reply reply;
        std::optional<SensitiveAllocation<ConcurrentMemory>> recording_output;
        std::array<char, 1025> error{};

        try {
          if (package && !authorized(*package, request)) {
            reply.result = Result::disabled;
            reply.message = "Package traffic capability denied or revoked";
          } else if (request.operation != Operation::status && request.operation != Operation::ca_certificate && request.operation != Operation::recording && !configuration_.administration) {
            reply.result = Result::disabled;
            reply.message = "Runtime proxy.network_control permission is disabled";
          } else {
            switch (request.operation) {
            case Operation::status:
            case Operation::ca_certificate:
              break;
            case Operation::capture_start:
            case Operation::redirect_start:
              start(request, reply, cancelled);
              break;
            case Operation::capture_stop:
              if (!capture_) {
                reply.result = Result::disabled;
              } else {
                capture_cancelled_ = true;
                const auto revision = capture_->stopCapture();
                if (!wait([&] {
                      return capture_->captureStopped(revision) && capture_child_ <= 0;
                    },
                        cancelled)) {
                  reply.result = Result::busy;
                  reply.message = "Capture is stopping";
                }
              }

              break;
            case Operation::redirect_stop:
              if (!configuration_.redirect) {
                reply.result = Result::disabled;
              } else {
                redirect_cancelled_ = true;
                proxy_.stopRedirect();
                if (!wait([&] {
                      const auto state = proxy_.redirectStatus();

                      return redirect_child_ <= 0 && (state == redirect::MonitorState::idle || state == redirect::MonitorState::cleanup_required);
                    },
                        cancelled)) {
                  reply.result = Result::busy;
                  reply.message = "Redirect cleanup is still running";
                } else if (proxy_.redirectStatus() == redirect::MonitorState::cleanup_required) {
                  reply.result = Result::cleanup_required;
                  reply.message = "The helper disconnected without confirming PF cleanup";
                  authorization(request, reply, "redirect-cleanup");
                }
              }

              break;
            case Operation::ca_install:
            case Operation::ca_uninstall:
            case Operation::ca_rotate:
              if (!configuration_.proxy) {
                reply.result = Result::disabled;
              } else {
                TrustCommand command{memory_, cancelled};

                proxy_.manageAuthority(request.operation == Operation::ca_install ? proxy_trust::Action::install : request.operation == Operation::ca_uninstall ? proxy_trust::Action::uninstall
                                                                                                                                                                : proxy_trust::Action::rotate,
                    command);
              }

              break;
            case Operation::recording:
              if (!capture_) {
                reply.result = Result::disabled;
              } else {
                recording_output.emplace(memory_, recording::Limits::page_bytes);
                reply.recording = capture_->recording(*request.recording, recording_output->bytes(), package ? recording::Owner::package(*package) : recording::Owner{});
              }

              break;
            }
          }
        } catch (const std::exception& failure) {
          reply.result = Result::failed;
          const auto message = std::string_view{failure.what()}.substr(0, error.size() - 1);

          std::ranges::copy(message, error.begin());
          reply.message = {error.data(), message.size()};
        }

        reply.status = status();
        if (package && !package->allows(plugins::Capability::traffic_control)) {
          reply.status.administration = false;
        }

        const auto authority = proxy_.authorityStatus(request.operation == Operation::ca_certificate);

        reply.status.tls_accepting = authority.accepting;
        reply.status.trust = static_cast<TrustState>(authority.trust);
        if (authority.active) {
          reply.fingerprint_sha1 = {authority.fingerprint_sha1.data(), authority.fingerprint_sha1.size()};
          reply.fingerprint_sha256 = {authority.fingerprint_sha256.data(), authority.fingerprint_sha256.size()};
          reply.certificate = std::span{authority.certificate}.first(authority.certificate_bytes);
        } else if (request.operation == Operation::ca_certificate) {
          reply.result = Result::disabled;
        }

        return Protocol::encode(output, reply);
      }

    private:
      inline Status status() const noexcept {
        Status status{.proxy = configuration_.proxy, .transparent_tls = configuration_.transparent_tls, .interception = configuration_.interception, .administration = configuration_.administration};
        const auto proxy = proxy_.clientConfiguration().status();

        status.port = proxy.port.value_or(0);
        if (capture_) {
          const auto capture = capture_->captureStatus();

          switch (capture.state) {
          case traffic::Service::CaptureState::idle:
            status.capture = CaptureState::idle;
            break;
          case traffic::Service::CaptureState::live:
            status.capture = CaptureState::live;
            break;
          case traffic::Service::CaptureState::offline:
            status.capture = CaptureState::offline;
            break;
          }

          status.capture_session = capture.session;
          status.interfaces = capture.interfaces;
          status.interface_errors = capture.interface_errors;
        }

        if (configuration_.redirect) {
          switch (proxy_.redirectStatus()) {
          case redirect::MonitorState::idle:
            status.redirect = RedirectState::idle;
            break;
          case redirect::MonitorState::starting:
            status.redirect = RedirectState::starting;
            break;
          case redirect::MonitorState::active:
            status.redirect = RedirectState::active;
            break;
          case redirect::MonitorState::stopping:
            status.redirect = RedirectState::stopping;
            break;
          case redirect::MonitorState::cleanup_required:
            status.redirect = RedirectState::cleanup_required;
            break;
          }
        }

        return status;
      }

      inline void authorization(const Request& request, tbc::view<Reply&, tbc::lt::a> reply, tbc::view<std::string_view, tbc::lt::a> action) const {
        reply.authorization[0] = "/usr/bin/sudo";
        reply.authorization[1] = "--";
        reply.authorization[2] = configuration_.executable;
        reply.authorization[3] = "traffic";
        reply.authorization[4] = action;
        reply.authorization[5] = "--socket";
        reply.authorization[6] = configuration_.endpoint;
        reply.argument_count = 7;
        if (action == "redirect") {
          for (std::size_t index = 0; index < selection_->targets().size(); ++index) {
            reply.authorization[reply.argument_count++] = "--target";
            reply.authorization[reply.argument_count++] = selection_->argument(index);
          }

          for (std::size_t index = 0; index < request.process_count; ++index) {
            reply.authorization[reply.argument_count++] = "--process";
            reply.authorization[reply.argument_count++] = process_arguments_[index].view();
          }

          if (request.direction != redirect::Direction::outbound) {
            reply.authorization[reply.argument_count++] = "--direction";
            reply.authorization[reply.argument_count++] = redirect::directionName(request.direction);
          }
        }
      }

      inline void start(const Request& request, Reply& reply, const std::atomic<bool>& cancelled) {
        const bool capture = request.operation == Operation::capture_start;
        if (capture ? capture_ == nullptr : !configuration_.redirect) {
          reply.result = Result::disabled;
          return;
        }

        if (capture && capture_->captureStatus().state == traffic::Service::CaptureState::live) {
          return;
        }

        if ((capture && capture_->captureStatus().state == traffic::Service::CaptureState::offline) || (!capture && proxy_.redirectStatus() != redirect::MonitorState::idle && proxy_.redirectStatus() != redirect::MonitorState::cleanup_required)) {
          reply.result = Result::busy;
          reply.message = "An existing helper must stop before its selection changes";
          return;
        }

        if (!capture) {
          const ProcessInspector inspector;

          for (std::size_t index = 0; index < request.process_count; ++index) {
            const auto process = inspector.identity(static_cast<pid_t>(request.processes[index]));
            if (!process) {
              throw std::invalid_argument{"Selected process must be running under the runtime account"};
            }

            process_arguments_[index] = redirect::ProcessToken::format(*process);
          }

          selection_.emplace(std::span{request.targets}.first(request.target_count), cancelled, Clock::now() + std::chrono::seconds{3});
          redirect::LocalAddresses::selection(selection_->targets(), request.direction);
        }

        auto& child = capture ? capture_child_ : redirect_child_;

        tick();
        if (child > 0) {
          reply.result = Result::busy;
          reply.message = "The previous helper is still stopping";
          return;
        }

        (capture ? capture_cancelled_ : redirect_cancelled_) = false;
        authorization(request, reply, capture ? "capture" : "redirect");
        std::array<std::string_view, Limits::arguments> arguments;

        arguments[0] = "/usr/bin/sudo";
        arguments[1] = "-n";
        arguments[2] = "-l";
        std::ranges::copy(std::span{reply.authorization}.subspan(1, reply.argument_count - 1), arguments.begin() + 3);
        const auto count = reply.argument_count + 2;
        Command preflight{memory_, Launch{.arguments = std::span{arguments}.first(count)}, CommandPurpose::administration};
        CommandOutput result{memory_, Limits::reply_bytes, &cancelled};
        if (result.run(preflight, Clock::now() + std::chrono::seconds{3}, true) != 0) {
          reply.result = Result::authorization_required;
          reply.message = "Run authorization_argv in a terminal to authorize this native helper";
          return;
        }

        arguments[2] = "--";
        std::ranges::copy(std::span{reply.authorization}.subspan(2, reply.argument_count - 2), arguments.begin() + 3);
        Command command{memory_, Launch{.arguments = std::span{arguments}.first(count - 1)}, CommandPurpose::administration};
        const auto specification = command.specification({});
        SpawnOptions spawn{0};
        FileDescriptor input{::open("/dev/null", O_RDONLY | O_CLOEXEC)};
        if (!input) {
          throw SystemError{"Prepare privileged helper input"};
        }

        spawn.redirect(input.get(), STDIN_FILENO);
        spawn.keepStandardStreams();

        pid_t started;

        checkSpawn(::posix_spawn(&started, specification.executable, &spawn.actions, &spawn.attributes, specification.arguments, specification.environment));
        child = started;
        const auto ready = [&] {
          return capture ? capture_->captureStatus().state == traffic::Service::CaptureState::live : proxy_.redirectStatus() == redirect::MonitorState::active;
        };

        wait([&] {
          return ready() || child <= 0;
        },
            cancelled);
        if (!ready()) {
          reply.result = Result::failed;
          reply.message = "The privileged helper did not confirm activation; authorization_argv also provides its terminal diagnostics";
          (capture ? capture_cancelled_ : redirect_cancelled_) = true;
          if (capture) {
            capture_->stopCapture();
          }

          if (!capture) {
            proxy_.stopRedirect();
          }

          return;
        }

        reply.argument_count = 0;
      }

      // Generic over the caller's callback.
      template <typename Predicate>
      TBC_HOT_PATH bool wait(Predicate predicate, const std::atomic<bool>& cancelled) {
        const auto deadline = Clock::now() + std::chrono::seconds{5};

        while (!predicate()) {
          if (cancelled.load(std::memory_order_acquire)) {
            throw std::runtime_error{"Network control is stopping"};
          }

          if (Clock::now() >= deadline) {
            return false;
          }

          tick();
          ::poll(nullptr, 0, 5);
        }

        return true;
      }

      inline static void reap(pid_t& child) noexcept {
        if (child <= 0) {
          return;
        }

        int status;
        const auto waited = ::waitpid(child, &status, WNOHANG);
        if (waited == child || (waited < 0 && sys::lastError() == ECHILD)) {
          child = -1;
        }
      }

      tbc::view<ConcurrentMemory&, tbc::lt::a> memory_;
      tbc::view<Proxy&, tbc::lt::a> proxy_;
      tbc::view<traffic::Service*, tbc::lt::a> capture_;
      tbc::view<Configuration, tbc::lt::a> configuration_;
      static_assert(Limits::processes == redirect::SocketOwners::maximum_processes);
      static_assert(Limits::targets == redirect::Target::maximum_targets);
      tbc::view<std::optional<redirect::Selection<>>, tbc::lt::a> selection_;
      tbc::view<std::array<FixedText<redirect::ProcessToken::maximum_bytes>, Limits::processes>, tbc::lt::a> process_arguments_;
      pid_t capture_child_ = -1;
      pid_t redirect_child_ = -1;
      bool capture_cancelled_ = false;
      bool redirect_cancelled_ = false;
    };

  }
}

// Interface: traffic/control_service.cppm
export {
  namespace telar::runtime::traffic::control {

    // Administration has its own worker; certificate-store operations never run on
    // the packet, proxy, or terminal workers. Each authenticated connection issues
    // one bounded request. Closing a client only cancels delivery of its reply.
    // Generic over the caller's handler.
    template <ConcurrentAllocator Memory, typename Handler>
    class TBC_HOT_PATH Service : public PackagePort {
      using Clock = std::chrono::steady_clock;

      struct Peer {
        inline explicit Peer(Memory& memory, FileDescriptor channel)
            : socket(std::move(channel)),
              input(memory, Limits::request_bytes + Protocol::prefix_bytes),
              output(memory, Limits::reply_bytes + Protocol::prefix_bytes) {}

        FileDescriptor socket;
        SensitiveAllocation<Memory> input;
        SensitiveAllocation<Memory> output;
        Clock::time_point deadline = Clock::now() + std::chrono::seconds{5};
        std::size_t expected = Protocol::prefix_bytes;
        std::size_t received = 0;
        std::size_t reply_bytes = 0;
        std::size_t sent = 0;
        std::optional<plugins::ServiceSpec> package;
      };

      struct Attachment {
        FileDescriptor socket;
        plugins::ServiceSpec package;
      };

    public:
      inline explicit Service(Memory& memory, std::string_view path, Handler& handler)
          : memory_(memory),
            listener_(path),
            handler_(handler),
            worker_([this] {
              run();
            }) {}

      inline ~Service() {
        stopping_.store(true, std::memory_order_release);
        wake_.notify();
        worker_.join();
      }

      Service(const Service&) = delete;
      Service& operator=(const Service&) = delete;

      inline FileDescriptor openPackage(const plugins::ServiceSpec& package) override {
        if (!package.traffic() || package.plugin_id == 0 || package.generation == 0) {
          throw SystemError{"Package control capability denied", EACCES};
        }

        std::array<int, 2> descriptors;
        if (::socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors.data()) != 0) {
          throw SystemError{"Create package control channel"};
        }

        FileDescriptor native{descriptors[0]}, client{descriptors[1]};

        configureProxySocket(native.get());
        configureProxySocket(client.get());
        if (!attachments_.publish({std::move(native), package})) {
          throw SystemError{"Package control attachment queue is full", EBUSY};
        }

        wake_.notify();
        return client;
      }

    private:
      inline void run() noexcept {
        while (!stopping_.load(std::memory_order_acquire)) {
          try {
            step();
          } catch (const std::exception& error) {
            std::fprintf(stderr, "telar network control: %s\n", error.what());
          }
        }
      }

      inline void step() {
        std::array<pollfd, Limits::peers + 2> descriptors{};

        descriptors[0] = {.fd = listener_.descriptor(), .events = POLLIN, .revents = 0};
        descriptors[1] = {.fd = wake_.descriptor(), .events = POLLIN, .revents = 0};
        for (std::size_t index = 0; index < peers_.size(); ++index) {
          const auto& peer = peers_[index];

          descriptors[index + 2] = {.fd = peer ? peer->socket.get() : -1, .events = static_cast<short>(peer && peer->reply_bytes ? POLLOUT : POLLIN)};
        }

        if (::poll(descriptors.data(), descriptors.size(), 100) < 0 && sys::lastError() != EINTR) {
          throw SystemError{"Poll network control"};
        }

        if (stopping_.load(std::memory_order_acquire)) {
          return;
        }

        handler_.tick();

        if (descriptors[1].revents & POLLIN) {
          wake_.drain();
          while (auto attachment = attachments_.tryReceive()) {
            for (auto& peer : peers_) {
              if (!peer) {
                peer.emplace(memory_, std::move(attachment->socket));
                peer->package = std::move(attachment->package);
                break;
              }
            }
          }
        }

        for (std::size_t index = 0; index < peers_.size(); ++index) {
          auto& peer = peers_[index];
          if (!peer) {
            continue;
          }

          const auto readiness = descriptors[index + 2].revents;
          bool close = (readiness & (POLLERR | POLLNVAL)) || Clock::now() >= peer->deadline;

          try {
            if (!close && (readiness & (POLLIN | POLLOUT | POLLHUP))) {
              close = advance(*peer, handler_, stopping_);
            }
          } catch (const std::exception&) {
            close = true;
          }

          if (close) {
            peer.reset();
          }
        }

        if (descriptors[0].revents & POLLIN) {
          auto socket = listener_.accept();
          if (!socket) {
            return;
          }

          for (auto& peer : peers_) {
            if (!peer) {
              peer.emplace(memory_, std::move(socket));
              break;
            }
          }
        }
      }

      // Moves one peer's exchange on; the handler and the stop flag are lent apart from it.
      inline static bool advance(Peer& peer, Handler& handler, const std::atomic<bool>& stopping) {
        if (peer.reply_bytes != 0) {
          const auto count = ::send(peer.socket.get(), peer.output.bytes().data() + peer.sent, peer.reply_bytes - peer.sent, 0);
          if (count < 0 && socketWouldBlock(sys::lastError())) {
            return false;
          }

          if (count <= 0) {
            return true;
          }

          peer.sent += static_cast<std::size_t>(count);
          return peer.sent == peer.reply_bytes;
        }

        for (std::size_t round = 0; round < 2; ++round) {
          const auto count = ::recv(peer.socket.get(), peer.input.bytes().data() + peer.received, peer.expected - peer.received, 0);
          if (count < 0 && socketWouldBlock(sys::lastError())) {
            return false;
          }

          if (count <= 0) {
            return true;
          }

          peer.received += static_cast<std::size_t>(count);
          if (peer.received != peer.expected) {
            return false;
          }

          if (peer.expected == Protocol::prefix_bytes) {
            plugins::FrameReader reader{peer.input.bytes().first(Protocol::prefix_bytes)};
            const auto length = reader.integer<std::uint32_t>();
            if (length == 0 || length > Limits::request_bytes) {
              return true;
            }

            peer.expected += length;
            continue;
          }

          const auto request = Protocol::request(peer.input.bytes().subspan(Protocol::prefix_bytes, peer.expected - Protocol::prefix_bytes));
          const auto output = peer.output.bytes().subspan(Protocol::prefix_bytes);
          std::span<const Byte> reply;

          try {
            reply = handler.handle(request, output, stopping, peer.package ? &*peer.package : nullptr);
          } catch (const std::exception& error) {
            reply = Protocol::encode(output, Reply{.result = Result::failed, .message = std::string_view{error.what()}.substr(0, 1024)});
          }

          const auto prefix = Protocol::prefix(reply.size());

          std::ranges::copy(prefix, peer.output.bytes().begin());
          peer.reply_bytes = prefix.size() + reply.size();
          peer.deadline = Clock::now() + std::chrono::seconds{5};
          return false;
        }

        return false;
      }

      Memory& memory_;
      LocalListener listener_;
      Handler& handler_;
      CompletionSignal wake_;
      std::array<std::optional<Peer>, Limits::peers> peers_;
      std::atomic<bool> stopping_{false};
      DropChannel<Attachment, Limits::peers, ChannelPolicy::keep_oldest> attachments_;
      std::thread worker_;
    };

  }
}
