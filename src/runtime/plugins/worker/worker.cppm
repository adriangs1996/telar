module;
#include "tbc/annotations.hpp"
#include "telar_platform/trace_macro.hpp"

export module telar.runtime.plugins.worker;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.runtime.platform.stream_read_buffer;
import telar.runtime.vocabulary.traffic;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.memory.sensitive;
import telar.platform.net;
import telar.platform.error;
import telar.platform.process;

import telar.runtime.plugins.tap_configuration;

import telar.plugins;

import telar.runtime.traffic.control_backend;
import telar.runtime.traffic.control_protocol;

import telar.runtime.platform.signals;
import telar.wire.vocabulary;
import telar.platform.primitives;
import telar.base.text;
import telar.runtime.vocabulary.frames;
import telar.base.ds;

// Interface: plugins/frame_channel.cppm
export {
  namespace telar::runtime::plugins {

    template <typename Stream>
    concept FrameStream = requires(Stream& stream, std::span<Byte> destination, std::span<const Byte> bytes) {
      { stream.read(destination) } noexcept -> std::same_as<StreamResult>;
      { stream.write(bytes, bytes) } -> std::same_as<void>;
    };

    // Generic over the caller's stream, and called for every frame a worker exchanges.
    template <FrameStream Stream>
    class TBC_GENERIC FrameChannel {
    public:
      inline explicit FrameChannel(Stream& stream) noexcept
          : stream_(stream) {}

      template <Allocator Memory>
      inline tbc::view<ds::Option<SensitiveAllocation<Memory>>, tbc::lt::a> receive(tbc::view<Memory&, tbc::lt::a> memory, std::size_t maximum_bytes) {
        ds::Array<Byte, Protocol::prefix_bytes> prefix;
        if (!readExact(prefix.viewMut())) {
          return ds::none;
        }

        std::span<const Byte> remaining{prefix};
        const auto length = LittleEndian<std::uint32_t>::decode(remaining);
        if (length == 0 || length > maximum_bytes) {
          throw EncodingError{"Invalid tap frame length"};
        }

        SensitiveAllocation frame{memory, length};
        if (!readExact(frame.bytesMut())) {
          throw SystemError{"Incomplete tap frame", EPIPE};
        }

        return frame;
      }

      inline void send(std::span<const Byte> payload) {
        if (payload.empty() || payload.size() > Limits::frame_bytes) {
          throw EncodingError{"Invalid tap frame length"};
        }

        ds::Array<Byte, Protocol::prefix_bytes> prefix;
        std::span<Byte> remaining{prefix.viewMut()};

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

        const auto view = input_.peek([this](std::span<Byte> bytes) noexcept {
          return stream_.read(bytes);
        },
            destination.size());

        requireReadable(view.state);
        return input_.copyTo(destination);
      }

      inline static void requireReadable(StreamResult::State state) {
        if (state != StreamResult::State::data && state != StreamResult::State::ended) {
          throw SystemError{"Read tap frame"};
        }
      }

      static constexpr std::size_t input_capacity = 16 * 1024;
      Stream& stream_;
      StreamReadBuffer<input_capacity> input_;
    };

    template <FrameStream Stream>
    FrameChannel(Stream& stream) -> FrameChannel<Stream>;

  }
}

// Interface: plugins/result.cppm
export {
  namespace telar::runtime::plugins {

    // A worker's effects for one event. The result owns the reply's storage, memory of the allocator in
    // region `a`, and keeps where the effects lie in it; the batch is decoded from there when read.
    template <Allocator Memory>
    struct Result {
      explicit Result(const ServiceSpec& specification, tbc::view<SensitiveAllocation<Memory>, tbc::lt::a> storage, std::size_t effects_offset, std::size_t effects_size, bool traffic = false);

      // The batch views the result's storage.
      EffectBatch batch() const;

      bool authorized(const ServiceSpec& specification) const noexcept;

      std::uint8_t package_index;
      std::uint64_t plugin_id;
      PackageDigest digest;
      std::uint64_t generation;
      std::uint64_t event_id = 0;
      std::size_t batch_count = 0;
      tbc::view<SensitiveAllocation<Memory>, tbc::lt::a> storage;
      bool traffic = false;

    private:
      std::span<const Byte> effectBytes() const;

      std::size_t effects_offset_;
      std::size_t effects_size_;
    };

    extern template struct Result<Memory>;
    extern template struct Result<ConcurrentMemory>;

    template <Allocator Memory>
    using OwnedResult = ds::Box<Result<Memory>, Memory>;

  }
}

// Interface: plugins/result_queue.cppm
export {
  namespace telar::runtime::plugins {

    template <Allocator Memory>
    class ResultQueue {
      static_assert(Limits::queue_depth <= PIPE_BUF);

    public:
      void activate();

      // The queue keeps the results, and what they keep of the allocator: region `a`.
      void publish(tbc::view<OwnedResult<Memory>, tbc::lt::a> result) noexcept;

      // Generic over the caller's consumer.
      template <typename Consumer>
      TBC_GENERIC void collect(Consumer&& consumer) {
        if (!ready_ || !ready_.getMut().consume()) {
          return;
        }

        auto result = results_.tryReceive();
        if (result) {
          consumer(**result);
        }
      }

      void close() noexcept;

      int descriptor() const noexcept;

    private:
      tbc::view<DropChannel<OwnedResult<Memory>, Limits::queue_depth, ChannelPolicy::keep_oldest>, tbc::lt::a> results_;
      ds::Option<CompletionSignal> ready_;
    };

    extern template class ResultQueue<Memory>;
    extern template class ResultQueue<ConcurrentMemory>;

  }
}

// Interface: plugins/session_io.cppm
export {
  namespace telar::runtime::plugins {

    class SessionIo {
    public:
      explicit SessionIo(PipeProcess& process, const CancellationSignal& cancellation) noexcept;

      void deadline(std::chrono::milliseconds timeout) noexcept;

      bool active() const noexcept;

      bool ready(int descriptor, short events) noexcept;

      void drainError() noexcept;

      std::string_view retainedError() const noexcept;

    private:
      using Clock = std::chrono::steady_clock;
      static constexpr std::size_t error_chunk_bytes = 1024;
      static constexpr std::size_t maximum_error_drain_bytes = 64 * 1024;

      int remainingMilliseconds() const noexcept;

      PipeProcess& process_;
      const CancellationSignal& cancellation_;
      Clock::time_point deadline_ = Clock::time_point::max();
      SensitiveText<Limits::stderr_bytes> error_;
    };

  }
}

// Interface: plugins/session.cppm
export {
  namespace telar::runtime::plugins {

    // The arguments of `telar-runtime tap-worker`, which Session::spawn writes and the runtime reads.
    struct TapWorkerOptions {
      static constexpr std::string_view command = "tap-worker";

      const char* entry = nullptr;
      bool traffic = false;
      const char* trace_path = nullptr;

      // The words after the command.
      static TapWorkerOptions parse(std::span<char* const> words);

      // The worker's argv, `executable` first and null last; a trace only in Debug builds.
      // The words view `executable` and the strings `options` names, region `a`.
      static tbc::view<ds::Array<char*, 7>, tbc::lt::a> arguments(tbc::view<const TapWorkerOptions&, tbc::lt::a> options, tbc::view<const char*, tbc::lt::a> executable) noexcept;
    };

    struct SessionOptions {
      const char* executable;
      const char* entry;
      const CancellationSignal& cancellation;
      std::chrono::milliseconds timeout = Limits::reply_deadline;
      const char* trace_path = nullptr;
      bool traffic = false;
    };

    template <Allocator Memory>
    class Session {
    public:
      explicit Session(Memory& memory, const SessionOptions& options);

      ~Session();

      Session(const Session&) = delete;
      Session& operator=(const Session&) = delete;

      OwnedResult<Memory> exchange(const ServiceSpec& specification, std::uint64_t event_id, std::span<const Byte> frame);

      SensitiveAllocation<Memory> request(std::span<const Byte> frame, std::size_t maximum_bytes);

      std::string_view retainedError() const noexcept;

      pid_t processId() const noexcept;

      int outputDescriptor() const noexcept;

    private:
      static PipeProcess spawn(const SessionOptions& options);

      static void requireEvent(std::uint64_t expected, std::uint64_t received);

#if TELAR_DEBUG
      void finishTrace() noexcept;
#endif

      Memory& memory_;
      PipeProcess process_;
      // The stream reads the process above and the channel frames the stream, so the session stays put.
      tbc::view<PipeStream<SessionIo>, tbc::lt::self> stream_;
      tbc::view<FrameChannel<PipeStream<SessionIo>>, tbc::lt::self> channel_;
      std::chrono::milliseconds timeout_;
      [[maybe_unused]] bool tracing_;
    };

    extern template class Session<Memory>;
    extern template class Session<ConcurrentMemory>;

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

    enum class TrafficStage : Byte {
      observe,
      stream,
      http,
      control,
    };

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

      std::span<const Byte> requestBytes() const noexcept;

      traffic::InterceptionRule rule() const noexcept;

      bool operator==(const TrafficRegistration&) const noexcept = default;
    };

    struct TrafficDecision {
      std::uint32_t registration = 0;
      std::span<const Byte> payload;
    };

    // The registrations a reply declares, which the host keeps; they own their texts.
    struct TrafficReply {
      std::uint64_t event_id = 0;
      bool changed = false;
      ds::Array<TrafficRegistration, TrafficLimits::registrations> registrations;
      std::size_t registration_count = 0;
    };

    // What a reply decides for its event, viewing the reply's bytes for as long as they live.
    struct TrafficOutcome {
      ds::Array<TrafficDecision, TrafficLimits::decisions> decisions;
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
      static tbc::view<std::span<const Byte>, tbc::lt::a> setup(tbc::view<std::span<Byte>, tbc::lt::a> output, const ServiceSpec& specification);

      static ServiceSpec setup(std::span<const Byte> input);

      static tbc::view<std::span<const Byte>, tbc::lt::a> event(tbc::view<std::span<Byte>, tbc::lt::a> output, std::uint64_t event_id, std::uint32_t registration, std::span<const Byte> frame, std::uint64_t dropped = 0);

      static TrafficEvent event(std::span<const Byte> input);

      static tbc::view<std::span<const Byte>, tbc::lt::a> controlEvent(tbc::view<std::span<Byte>, tbc::lt::a> output, std::uint64_t event_id, std::uint32_t registration, std::span<const Byte> frame, std::string_view error = {});

      static tbc::view<std::span<const Byte>, tbc::lt::a> reply(tbc::view<std::span<Byte>, tbc::lt::a> output, const TrafficReply& reply, const TrafficOutcome& outcome);

      static TrafficReply reply(std::span<const Byte> input);

      // The registrations land in the reply; the outcome views the input.
      static tbc::view<TrafficOutcome, tbc::lt::a> readReply(tbc::view<std::span<const Byte>, tbc::lt::a> input, TrafficReply& reply);

    private:
      static void write(FrameWriter& writer, const TrafficRegistration& registration);

      static TrafficRegistration read(FrameReader& reader);
    };

  }
}

// Interface: plugins/traffic_bridge.cppm
export {
  namespace telar::runtime::plugins {

    class TrafficBridge {
      using Secure = ErasingAllocator<ConcurrentMemory>;

      struct Connection {
        explicit Connection(tbc::view<Secure&, tbc::lt::a> memory, TrafficRegistration registration, traffic::PackageChannel channel);

        TrafficRegistration registration;
        FileDescriptor socket;
        std::uint64_t owner;
        tbc::view<ByteQueue<Secure>, tbc::lt::a> output;
        ds::Array<Byte, traffic::Protocol::prefix_bytes> prefix;
        std::size_t prefix_bytes = 0;
        std::uint64_t dropped = 0;
        tbc::view<ds::Option<SensitiveAllocation<ConcurrentMemory>>, tbc::lt::a> input;
        std::size_t received = 0;
        bool registration_ack;
        bool ready = false;
        bool notify_ready = false;
        std::chrono::steady_clock::time_point deadline = std::chrono::steady_clock::now() + std::chrono::seconds{45};
        FixedText<1024> error;
      };

    public:
      // The bridge keeps the allocator and the port, region `a`, and its own copy of the specification. The
      // session it talks to is the worker's, lent to each call.
      explicit TrafficBridge(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, const ServiceSpec& specification, tbc::view<traffic::PackagePort&, tbc::lt::a> port);

      void attach(Session<ConcurrentMemory>& session);

      void detach() noexcept;

      std::uint64_t errors() const noexcept;

      bool transportFailed() const noexcept;

      // `session` is the worker's session, or null while it restarts.
      template <typename Consumer>
      TBC_GENERIC void step(Session<ConcurrentMemory>* session, int wake, const CancellationSignal& cancellation, Consumer&& consume, bool immediate = false) {
        for (std::size_t index = 0; index < connections_.size(); ++index) {
          auto& connection = connections_.atMut(index);
          if (!connection || connection->registration.stage != TrafficStage::control) {
            continue;
          }

          if (std::chrono::steady_clock::now() >= connection->deadline) {
            connection.getMut().error.assign("Network control deadline exceeded");
          }

          if (!connection->socket && connection->error.view().empty()) {
            try {
              connection.getMut().socket = port_.openControl(specification_);
            } catch (const SystemError& failure) {
              if (failure.code() != EAGAIN) {
                connection.getMut().error.assign(std::string_view{failure.what()}.substr(0, 1024));
              }
            } catch (const std::exception& failure) {
              connection.getMut().error.assign(std::string_view{failure.what()}.substr(0, 1024));
            }
          }

          if (!connection->error.view().empty()) {
            const auto error = connection->error;

            dispatchControl(session, index, {}, error.view(), consume);
            return;
          }
        }

        for (std::size_t index = 0; index < connections_.size(); ++index) {
          auto& connection = connections_.atMut(index);
          if (connection && connection->notify_ready) {
            connection.getMut().notify_ready = false;
            constexpr std::string_view reason = "worker_restarted";
            ds::Array<Byte, 128> output;
            const auto ready = traffic::Protocol::encode(output.viewMut(), {.kind = traffic::Kind::ready, .bytes = {reinterpret_cast<const Byte*>(reason.data()), reason.size()}});

            dispatch(session, index, ready, connection->dropped, consume);
          }
        }

        ds::Array<pollfd, TrafficLimits::registrations + 3> descriptors{};
        ds::Array<std::uint32_t, TrafficLimits::registrations> identities{};

        descriptors.atMut(0) = {wake, POLLIN, 0};
        descriptors.atMut(1) = {cancellation.descriptor(), POLLIN, 0};
        descriptors.atMut(2) = {session ? session->outputDescriptor() : -1, POLLIN, 0};
        for (std::size_t index = 0; index < connections_.size(); ++index) {
          const auto& connection = connections_[index];

          identities.atMut(index) = connection ? connection->registration.id : 0;
          descriptors.atMut(index + 3) = {connection ? connection->socket.get() : -1, static_cast<short>(POLLIN | (connection && connection->output.size() ? POLLOUT : 0)), 0};
        }

        if (::poll(descriptors.dataMut(), descriptors.size(), immediate ? 0 : 100) < 0) {
          if (sys::lastError() == EINTR) {
            return;
          }

          throw SystemError{"Poll package traffic"};
        }

        if (cancellation.requested()) {
          return;
        }

        if (descriptors[2].revents != 0) {
          throw SystemError{"Traffic worker sent an unsolicited reply or exited", EPIPE};
        }

        enum class Priority {
          intercept,
          observe,
          control,
        };

        for (const auto priority : {Priority::intercept, Priority::observe, Priority::control}) {
          for (std::size_t index = 0; index < connections_.size(); ++index) {
            auto& connection = connections_.atMut(index);
            if (!connection) {
              continue;
            }

            const auto stage = connection->registration.stage;
            const auto selected = stage == TrafficStage::control ? Priority::control : stage == TrafficStage::observe ? Priority::observe
                                                                                                                      : Priority::intercept;
            if (selected != priority) {
              continue;
            }

            if (connection->registration.id != identities[index]) {
              continue;
            }

            const auto readiness = descriptors[index + 3].revents;

            if (stage == TrafficStage::control) {
              ds::Option<SensitiveAllocation<ConcurrentMemory>> frame;

              try {
                if (readiness & (POLLERR | POLLNVAL)) {
                  throw SystemError{"Package control channel failed", EPIPE};
                }

                if (readiness & POLLOUT) {
                  write(connection.getMut());
                }

                if (readiness & (POLLIN | POLLHUP)) {
                  frame = read(memory_, connection.getMut());
                }
              } catch (const std::exception& failure) {
                connection.getMut().error.assign(std::string_view{failure.what()}.substr(0, 1024));
              }

              if (!connection->error.view().empty()) {
                const auto error = connection->error;

                dispatchControl(session, index, {}, error.view(), consume);
              } else if (frame) {
                traffic::control::Protocol::reply(frame->bytes());
                dispatchControl(session, index, frame->bytes(), {}, consume);
              }

              continue;
            }

            if (readiness & (POLLERR | POLLNVAL)) {
              transport_failed_ = true;
              throw SystemError{"Package traffic channel failed", EPIPE};
            }

            try {
              if (readiness & POLLOUT) {
                write(connection.getMut());
              }
            } catch (...) {
              transport_failed_ = true;
              throw;
            }

            if (readiness & (POLLIN | POLLHUP)) {
              ds::Option<SensitiveAllocation<ConcurrentMemory>> frame;

              try {
                frame = read(memory_, connection.getMut());
              } catch (...) {
                transport_failed_ = true;
                throw;
              }

              if (!frame) {
                continue;
              }

              const auto kind = traffic::Protocol::decode(frame->bytes()).kind;
              if (connection->registration_ack && kind == traffic::Kind::ready) {
                connection.getMut().registration_ack = false;
                continue;
              }

              if (kind == traffic::Kind::ready) {
                connection.getMut().ready = true;
              }

              dispatch(session, index, frame->bytes(), connection->dropped, consume);
            }
          }
        }
      }

    private:
      // A control connection is spent once its event is sent; the callback's reply may change the table.
      template <typename Consumer>
      TBC_GENERIC void dispatchControl(Session<ConcurrentMemory>* session, std::size_t index, std::span<const Byte> frame, std::string_view error, Consumer&& consume) {
        auto& connection = connections_.atMut(index);

        if (!session) {
          connection.reset();
          return;
        }

        SensitiveAllocation request{memory_, frame.size() + error.size() + 128};
        const auto event_id = ++next_event_;
        const auto encoded = TrafficProtocol::controlEvent(request.bytesMut(), event_id, connection->registration.id, frame, error);

        connection.reset();
        auto response = session->request(encoded, TrafficLimits::reply_bytes);
        if (response.bytes().front() == static_cast<Byte>(FrameKind::error)) {
          if (Protocol::decodeError(response.bytes()).event_id != event_id) {
            throw EncodingError{"Stale control callback error"};
          }

          ++errors_;
          return;
        }

        const auto effects = apply(event_id, response.bytes()).effects;

        publishEffects(event_id, std::move(response), effects, consume);
      }

      // The result owns the reply and finds its effects again where the outcome saw them.
      template <typename Consumer>
      TBC_GENERIC void publishEffects(std::uint64_t event_id, SensitiveAllocation<ConcurrentMemory> response, std::span<const Byte> effects, Consumer&& consume) {
        if (effects.empty()) {
          return;
        }

        const auto offset = static_cast<std::size_t>(effects.data() - response.bytes().data());
        auto result = ds::makeBox<Result<ConcurrentMemory>>(memory_, specification_, std::move(response), offset, effects.size(), true);
        if (result->event_id != event_id) {
          throw EncodingError{"Stale traffic notification"};
        }

        if (result->batch_count != 0) {
          consume(std::move(result));
        }
      }

      // The connection is named by its slot, as the callback's reply may change the table it lives in.
      template <typename Consumer>
      TBC_GENERIC void dispatch(Session<ConcurrentMemory>* session, std::size_t index, std::span<const Byte> frame, std::uint64_t dropped, Consumer&& consume) {
        auto& connection = connections_.atMut(index).getMut();
        const auto event = traffic::Protocol::decode(frame);
        const bool control = event.kind == traffic::Kind::intercept_request || event.kind == traffic::Kind::http_intercept_request;
        ds::Option<traffic::FlowEvent> flow;

        if (control) {
          flow = traffic::FlowCodec::decode(event.bytes);
          if (!port_.packagePending(connection.owner, flow->ticket, connection.registration.stage == TrafficStage::http)) {
            return;
          }
        }

        if (!session) {
          if (control) {
            fail(connection, flow.getMut());
          } else {
            ++dropped_observations_;
          }

          return;
        }

        SensitiveAllocation request{memory_, frame.size() + 64};
        const auto event_id = ++next_event_;
        auto response = session->request(TrafficProtocol::event(request.bytesMut(), event_id, connection.registration.id, frame, dropped + dropped_observations_), TrafficLimits::reply_bytes);
        if (response.bytes().front() == static_cast<Byte>(FrameKind::error)) {
          const auto error = Protocol::decodeError(response.bytes());
          if (error.event_id != event_id) {
            throw EncodingError{"Stale traffic callback error"};
          }

          ++errors_;
          if (control) {
            fail(connections_.atMut(index).getMut(), *flow);
            port_.packageFailure(specification_, *flow);
          }

          return;
        }

        const auto effects = apply(event_id, response.bytes()).effects;

        publishEffects(event_id, std::move(response), effects, consume);
      }

      static void fail(Connection& connection, const traffic::FlowEvent& flow);

      Connection* find(std::uint32_t id) noexcept;

      // What the reply decided views the input, region `a`; its registrations land in the bridge.
      tbc::view<TrafficOutcome, tbc::lt::a> apply(std::uint64_t event_id, tbc::view<std::span<const Byte>, tbc::lt::a> input);

      static void enqueue(Connection& connection, std::span<const Byte> frame);

      static void write(Connection& connection);

      // A complete frame leaves the connection; it borrows only the allocator.
      static tbc::view<ds::Option<SensitiveAllocation<ConcurrentMemory>>, tbc::lt::a> read(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, Connection& connection);

      tbc::view<ConcurrentMemory&, tbc::lt::a> memory_;
      tbc::view<Secure, tbc::lt::a> secure_;
      ServiceSpec specification_;
      tbc::view<traffic::PackagePort&, tbc::lt::a> port_;
      tbc::view<ds::Array<ds::Option<Connection>, TrafficLimits::registrations>, tbc::lt::a> connections_;
      tbc::view<ds::Box<TrafficReply, ConcurrentMemory>, tbc::lt::a> reply_;
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
      const char* executable;
      CancellationSignal& cancellation;
      std::chrono::milliseconds timeout = Limits::reply_deadline;
      std::string_view trace_prefix{};
      traffic::PackagePort* traffic = nullptr;
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

    // A package's worker thread. The proxy submits exchanges, the runtime reads metrics and the trust
    // monitor revokes it from their own threads: what they touch is atomic or a synchronized channel, and
    // the session, the bridge and the thread's state belong to its thread alone. That split is audited
    // here, so the worker is TBC_SHARED; its thread keeps `this`, so it stays where it was built. Built in
    // worker.cpp for the steady clock.
    template <WorkerClock Clock = std::chrono::steady_clock>
    class TBC_SHARED Worker {
    public:
      using Shared = std::shared_ptr<SharedExchange>;

      explicit Worker(ConcurrentMemory& memory, const ServiceSpec& specification, ResultQueue<ConcurrentMemory>& results, TapBudget& budget, WorkerLaunch launch);

      ~Worker();

      Worker(const Worker&) = delete;
      Worker& operator=(const Worker&) = delete;

      void stop() noexcept;
      void revoke() noexcept;
      bool revoked() const noexcept;

      // The worker queues the exchange, and what it keeps of the allocator: region `a`.
      void submit(tbc::view<Shared, tbc::lt::a> exchange) noexcept;

      WorkerMetrics metrics() const noexcept;
      const ServiceSpec& specification() const noexcept;

    private:
      static ServiceSpec bindPermissions(ConcurrentMemory& memory, const ServiceSpec& specification);

      void run() noexcept;
      void runTraffic() noexcept;
      void process(const SharedExchange& shared) noexcept;
      void exchange(std::uint64_t event_id, std::span<const Byte> payload) noexcept;

      // Starts the plugin's session unless one runs; `traffic` gives it the traffic bridge's channel.
      void ensureSession(bool traffic);

      // Restarts a failed session, counting a timeout; false when the session was cancelled, which
      // ends it rather than restarting it.
      bool recover(const SystemError& error) noexcept;

      void restart() noexcept;
      void prepareTrace();

      ConcurrentMemory& memory_;
      ServiceSpec specification_;
      ResultQueue<ConcurrentMemory>& results_;
      TapBudget& budget_;
      WorkerLaunch launch_;
      ds::String<ConcurrentMemory> entry_;
      ds::String<ConcurrentMemory> trace_path_;
      [[maybe_unused]] std::uint64_t session_number_ = 0;
      tbc::view<DropChannel<Shared, Limits::queue_depth, ChannelPolicy::keep_newest>, tbc::lt::a> requests_;
      CancellationSignal cancellation_;
      ds::Option<Session<ConcurrentMemory>> session_;
      ds::Box<TrafficBridge, ConcurrentMemory> bridge_{};
      CompletionSignal wake_;
      std::uint64_t callback_errors_base_ = 0;
      RestartWindow restarts_;
      std::atomic<std::uint64_t> timeouts_{0};
      std::atomic<bool> disabled_{false};
      std::atomic<bool> revoked_{false};
      std::atomic<std::uint64_t> callback_errors_{0};
      std::jthread thread_;
    };

    extern template class Worker<std::chrono::steady_clock>;

  }
}
