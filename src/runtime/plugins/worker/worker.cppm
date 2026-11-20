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
      inline tbc::val_a<ds::Option<SensitiveAllocation<Memory>>> receive(tbc::mut_a<Memory> memory, std::size_t maximum_bytes) {
        ds::Array<Byte, Protocol::prefix_bytes> prefix{};
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

        ds::Array<Byte, Protocol::prefix_bytes> prefix{};
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

      static constexpr std::size_t input_capacity = std::size_t{16} * 1024;
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
      // Where the effects lie in the storage.
      struct Effects {
        std::size_t offset = 0;
        std::size_t size = 0;
      };

      explicit Result(const ServiceSpec& specification, tbc::val_a<SensitiveAllocation<Memory>> owned, std::size_t effects_offset, std::size_t effects_size, bool from_traffic = false);

      // The batch views the result's storage.
      [[nodiscard]] EffectBatch batch() const;

      [[nodiscard]] bool authorized(const ServiceSpec& specification) const noexcept;

      std::uint8_t package_index;
      std::uint64_t plugin_id;
      PackageDigest digest;
      std::uint64_t generation;
      std::uint64_t event_id = 0;
      std::size_t batch_count = 0;
      tbc::val_a<SensitiveAllocation<Memory>> storage;
      bool traffic = false;
      Effects effects;

    private:
      [[nodiscard]] std::span<const Byte> effectBytes() const;
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
      void publish(tbc::val_a<OwnedResult<Memory>> result) noexcept;

      // Generic over the caller's consumer; takes it itself, as the lambdas callers pass build it in place.
      template <typename Consumer>
      TBC_GENERIC void collect(Consumer consumer) {
        if (!ready_ || !ready_.getMut().consume()) {
          return;
        }

        auto result = results_.tryReceive();
        if (result) {
          consumer(**result);
        }
      }

      void close() noexcept;

      [[nodiscard]] int descriptor() const noexcept;

    private:
      tbc::val_a<DropChannel<OwnedResult<Memory>, Limits::queue_depth, ChannelPolicy::keep_oldest>> results_;
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

      [[nodiscard]] bool active() const noexcept;

      bool ready(int descriptor, short events) noexcept;

      void drainError() noexcept;

      [[nodiscard]] std::string_view retainedError() const noexcept;

    private:
      using Clock = std::chrono::steady_clock;
      static constexpr std::size_t error_chunk_bytes = 1024;
      static constexpr std::size_t maximum_error_drain_bytes = std::size_t{64} * 1024;

      [[nodiscard]] int remainingMilliseconds() const noexcept;

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

      // The worker's argv: the executable, the command, the entry, two flags with the trace's path,
      // and the null that ends it.
      static constexpr std::size_t argument_capacity = 7;

      // The worker's argv, `executable` first and null last; a trace only in Debug builds.
      // The words view `executable` and the strings `options` names, region `a`.
      static tbc::val_a<ds::Array<char*, argument_capacity>> arguments(tbc::ref_a<TapWorkerOptions> options, tbc::val_a<const char*> executable) noexcept;
    };

    struct SessionOptions {
      const char* executable = nullptr;
      const char* entry = nullptr;
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
      Session(Session&&) = delete;
      Session& operator=(Session&&) = delete;

      OwnedResult<Memory> exchange(const ServiceSpec& specification, std::uint64_t event_id, std::span<const Byte> frame);

      SensitiveAllocation<Memory> request(std::span<const Byte> frame, std::size_t maximum_bytes);

      [[nodiscard]] std::string_view retainedError() const noexcept;

      [[nodiscard]] pid_t processId() const noexcept;

      [[nodiscard]] int outputDescriptor() const noexcept;

    private:
      static PipeProcess spawn(const SessionOptions& options);

      static void requireEvent(std::uint64_t expected, std::uint64_t received);

#if TELAR_DEBUG
      void finishTrace() noexcept;
#endif

      Memory& memory_;
      PipeProcess process_;
      // The stream reads the process above and the channel frames the stream, so the session stays put.
      tbc::val_self<PipeStream<SessionIo>> stream_;
      tbc::val_self<FrameChannel<PipeStream<SessionIo>>> channel_;
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
      static constexpr std::size_t reply_bytes = std::size_t{4} * 1024 * 1024;
      // The longest error a control callback hears of, or reports.
      static constexpr std::size_t error_bytes = 1024;
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

      [[nodiscard]] std::span<const Byte> requestBytes() const noexcept;

      [[nodiscard]] traffic::InterceptionRule rule() const noexcept;

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

    // Which event a frame is, and of which registration.
    struct TrafficEventId {
      std::uint64_t event_id = 0;
      std::uint32_t registration = 0;
    };

    class TrafficProtocol {
    public:
      static tbc::val_a<std::span<const Byte>> setup(tbc::val_a<std::span<Byte>> output, const ServiceSpec& specification);

      static ServiceSpec setup(std::span<const Byte> input);

      static tbc::val_a<std::span<const Byte>> event(tbc::val_a<std::span<Byte>> output, TrafficEventId id, std::span<const Byte> frame, std::uint64_t dropped = 0);

      static TrafficEvent event(std::span<const Byte> input);

      static tbc::val_a<std::span<const Byte>> controlEvent(tbc::val_a<std::span<Byte>> output, TrafficEventId id, std::span<const Byte> frame, std::string_view error = {});

      static tbc::val_a<std::span<const Byte>> reply(tbc::val_a<std::span<Byte>> output, const TrafficReply& reply, const TrafficOutcome& outcome);

      static TrafficReply reply(std::span<const Byte> input);

      // The registrations land in the reply; the outcome views the input.
      static tbc::val_a<TrafficOutcome> readReply(tbc::val_a<std::span<const Byte>> input, TrafficReply& reply);

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
        // How long a control connection may take to open and answer.
        static constexpr auto control_timeout = std::chrono::seconds{45};

        explicit Connection(tbc::mut_a<Secure> memory, TrafficRegistration declared, traffic::PackageChannel channel);

        TrafficRegistration registration;
        FileDescriptor socket;
        std::uint64_t owner;
        tbc::val_a<ByteQueue<Secure>> output;
        ds::Array<Byte, traffic::Protocol::prefix_bytes> prefix{};
        std::size_t prefix_bytes = 0;
        std::uint64_t dropped = 0;
        tbc::val_a<ds::Option<SensitiveAllocation<ConcurrentMemory>>> input;
        std::size_t received = 0;
        bool registration_ack;
        bool ready = false;
        bool notify_ready = false;
        std::chrono::steady_clock::time_point deadline = std::chrono::steady_clock::now() + control_timeout;
        FixedText<TrafficLimits::error_bytes> error;
      };

      // The order one step serves its connections in: interceptors first, as a flow waits on them.
      enum class Priority : std::uint8_t {
        intercept,
        observe,
        control,
      };

      // The poll events that fail a connection, that it reads on, and that it writes on.
      static constexpr unsigned failure_events = static_cast<unsigned>(POLLERR) | static_cast<unsigned>(POLLNVAL);
      static constexpr unsigned input_events = static_cast<unsigned>(POLLIN) | static_cast<unsigned>(POLLHUP);
      static constexpr unsigned output_events = POLLOUT;
      // How long a step waits for traffic when nothing is due at once.
      static constexpr int poll_timeout_ms = 100;
      // The descriptors a step watches before its connections': the wake, the cancellation and the session.
      static constexpr std::size_t fixed_watches = 3;
      // The bytes a request adds to the frame it carries, for an event and for a control event.
      static constexpr std::size_t event_overhead = 64;
      static constexpr std::size_t control_event_overhead = 128;
      // Room for the frame that tells a registration its worker restarted.
      static constexpr std::size_t ready_frame_bytes = 128;

    public:
      // The bridge keeps the allocator and the port, region `a`, and its own copy of the specification. The
      // session it talks to is the worker's, lent to each call.
      explicit TrafficBridge(tbc::mut_a<ConcurrentMemory> memory, ServiceSpec specification, tbc::mut_a<traffic::PackagePort> port);

      void attach(Session<ConcurrentMemory>& session);

      void detach() noexcept;

      [[nodiscard]] std::uint64_t errors() const noexcept;

      [[nodiscard]] bool transportFailed() const noexcept;

      // `session` is the worker's session, or null while it restarts. Takes the consumer itself, as the
      // lambdas callers pass build it in place.
      template <typename Consumer>
      TBC_GENERIC void step(Session<ConcurrentMemory>* session, int wake, const CancellationSignal& cancellation, Consumer consume, bool immediate = false) {
        if (openControls(session, consume)) {
          return;
        }

        announceRestart(session, consume);
        ds::Array<pollfd, TrafficLimits::registrations + fixed_watches> descriptors{};
        ds::Array<std::uint32_t, TrafficLimits::registrations> identities{};

        descriptors.atMut(0) = {.fd = wake, .events = POLLIN, .revents = 0};
        descriptors.atMut(1) = {.fd = cancellation.descriptor(), .events = POLLIN, .revents = 0};
        descriptors.atMut(2) = {.fd = session ? session->outputDescriptor() : -1, .events = POLLIN, .revents = 0};
        watchConnections(descriptors.viewMut().subspan(fixed_watches), identities.viewMut());
        if (::poll(descriptors.dataMut(), descriptors.size(), immediate ? 0 : poll_timeout_ms) < 0) {
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

        for (const auto priority : {Priority::intercept, Priority::observe, Priority::control}) {
          for (std::size_t index = 0; index < connections_.size(); ++index) {
            if (!due(index, priority, identities[index])) {
              continue;
            }

            const auto& watch = descriptors[index + fixed_watches];

            if (priority == Priority::control) {
              serveControl(session, index, watch, consume);
            } else {
              serveTraffic(session, index, watch, consume);
            }
          }
        }
      }

    private:
      // Opens each control connection not yet open, and dispatches the first that failed or timed out;
      // whether it dispatched one, which ends the step.
      template <typename Consumer>
      TBC_GENERIC bool openControls(Session<ConcurrentMemory>* session, Consumer& consume) {
        for (std::size_t index = 0; index < connections_.size(); ++index) {
          auto& connection = connections_.atMut(index);
          if (!connection || connection->registration.stage != TrafficStage::control) {
            continue;
          }

          if (std::chrono::steady_clock::now() >= connection->deadline) {
            connection.getMut().error.assign("Network control deadline exceeded");
          }

          if (!connection->socket && connection->error.view().empty()) {
            openControl(port_, specification_, connection.getMut());
          }

          if (!connection->error.view().empty()) {
            const auto error = connection->error;

            dispatchControl(session, index, {}, error.view(), consume);
            return true;
          }
        }

        return false;
      }

      // Tells each registration that waits for it that its worker restarted.
      template <typename Consumer>
      TBC_GENERIC void announceRestart(Session<ConcurrentMemory>* session, Consumer& consume) {
        for (std::size_t index = 0; index < connections_.size(); ++index) {
          auto& connection = connections_.atMut(index);
          if (connection && connection->notify_ready) {
            connection.getMut().notify_ready = false;
            constexpr std::string_view reason = "worker_restarted";
            ds::Array<Byte, ready_frame_bytes> output{};
            const auto ready = traffic::Protocol::encode(output.viewMut(), {.kind = traffic::Kind::ready, .bytes = byteView(reason)});

            dispatch(session, index, ready, connection->dropped, consume);
          }
        }
      }

      template <typename Consumer>
      TBC_GENERIC void serveControl(Session<ConcurrentMemory>* session, std::size_t index, const pollfd& watch, Consumer& consume) {
        const auto readiness = watch.revents;
        auto& connection = connections_.atMut(index);
        ds::Option<SensitiveAllocation<ConcurrentMemory>> frame;

        try {
          if (signaled(readiness, failure_events)) {
            throw SystemError{"Package control channel failed", EPIPE};
          }

          if (signaled(readiness, output_events)) {
            write(connection.getMut());
          }

          if (signaled(readiness, input_events)) {
            frame = read(memory_, connection.getMut());
          }
        } catch (const std::exception& failure) {
          connection.getMut().error.assign(std::string_view{failure.what()}.substr(0, TrafficLimits::error_bytes));
        }

        if (!connection->error.view().empty()) {
          const auto error = connection->error;

          dispatchControl(session, index, {}, error.view(), consume);
        } else if (frame) {
          traffic::control::Protocol::reply(frame->bytes());
          dispatchControl(session, index, frame->bytes(), {}, consume);
        }
      }

      template <typename Consumer>
      TBC_GENERIC void serveTraffic(Session<ConcurrentMemory>* session, std::size_t index, const pollfd& watch, Consumer& consume) {
        const auto readiness = watch.revents;
        auto& connection = connections_.atMut(index);

        if (signaled(readiness, failure_events)) {
          transport_failed_ = true;
          throw SystemError{"Package traffic channel failed", EPIPE};
        }

        try {
          if (signaled(readiness, output_events)) {
            write(connection.getMut());
          }
        } catch (...) {
          transport_failed_ = true;
          throw;
        }

        if (!signaled(readiness, input_events)) {
          return;
        }

        ds::Option<SensitiveAllocation<ConcurrentMemory>> frame;

        try {
          frame = read(memory_, connection.getMut());
        } catch (...) {
          transport_failed_ = true;
          throw;
        }

        if (!frame) {
          return;
        }

        const auto kind = traffic::Protocol::decode(frame->bytes()).kind;
        if (connection->registration_ack && kind == traffic::Kind::ready) {
          connection.getMut().registration_ack = false;
          return;
        }

        if (kind == traffic::Kind::ready) {
          connection.getMut().ready = true;
        }

        dispatch(session, index, frame->bytes(), connection->dropped, consume);
      }

      // Opens a control connection's socket; a failure other than a busy port is its error.
      static void openControl(traffic::PackagePort& port, const ServiceSpec& specification, Connection& connection);

      // The descriptor each connection is polled on, and the registration it served when polled.
      void watchConnections(std::span<pollfd> descriptors, std::span<std::uint32_t> identities) const noexcept;

      // Whether the connection in slot `index` is served at `priority`, and still the registration
      // `identity` it was polled as.
      [[nodiscard]] bool due(std::size_t index, Priority priority, std::uint32_t identity) const noexcept;

      static constexpr Priority priorityOf(TrafficStage stage) noexcept {
        if (stage == TrafficStage::control) {
          return Priority::control;
        }

        return stage == TrafficStage::observe ? Priority::observe : Priority::intercept;
      }

      static constexpr bool signaled(short revents, unsigned events) noexcept {
        return (static_cast<unsigned>(static_cast<unsigned short>(revents)) & events) != 0;
      }

      // A control connection is spent once its event is sent; the callback's reply may change the table.
      template <typename Consumer>
      TBC_GENERIC void dispatchControl(Session<ConcurrentMemory>* session, std::size_t index, std::span<const Byte> frame, std::string_view error, Consumer& consume) {
        auto& connection = connections_.atMut(index);

        if (!session) {
          connection.reset();
          return;
        }

        SensitiveAllocation request{memory_, frame.size() + error.size() + control_event_overhead};
        const auto event_id = ++next_event_;
        const auto encoded = TrafficProtocol::controlEvent(request.bytesMut(), {.event_id = event_id, .registration = connection->registration.id}, frame, error);

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
      TBC_GENERIC void publishEffects(std::uint64_t event_id, SensitiveAllocation<ConcurrentMemory> response, std::span<const Byte> effects, Consumer& consume) {
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
      TBC_GENERIC void dispatch(Session<ConcurrentMemory>* session, std::size_t index, std::span<const Byte> frame, std::uint64_t dropped, Consumer& consume) {
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

        SensitiveAllocation request{memory_, frame.size() + event_overhead};
        const auto event_id = ++next_event_;
        auto response = session->request(TrafficProtocol::event(request.bytesMut(), {.event_id = event_id, .registration = connection.registration.id}, frame, dropped + dropped_observations_), TrafficLimits::reply_bytes);
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

      // The connection of registration `id` among `connections` alone, so the reply naming it stays
      // borrowed meanwhile.
      static Connection* find(std::span<ds::Option<Connection>> connections, std::uint32_t id) noexcept;

      // What the reply decided views the input, region `a`; its registrations land in the bridge.
      tbc::val_a<TrafficOutcome> apply(std::uint64_t event_id, tbc::val_a<std::span<const Byte>> input);

      // The checks a changed reply's registrations pass before the bridge takes them.
      void checkRegistrations() const;

      // Closes each connection whose registration the reply dropped.
      void dropUnregistered() noexcept;

      // Opens a connection for each registration the reply added; an existing one must not change.
      void openRegistered();

      // Hands each decision of the outcome to the interceptor it names.
      void applyDecisions(const TrafficOutcome& outcome);

      static void enqueue(Connection& connection, std::span<const Byte> frame);

      static void write(Connection& connection);

      // A complete frame leaves the connection; it borrows only the allocator.
      static tbc::val_a<ds::Option<SensitiveAllocation<ConcurrentMemory>>> read(tbc::mut_a<ConcurrentMemory> memory, Connection& connection);

      tbc::mut_a<ConcurrentMemory> memory_;
      tbc::val_a<Secure> secure_;
      ServiceSpec specification_;
      tbc::mut_a<traffic::PackagePort> port_;
      tbc::val_a<ds::Array<ds::Option<Connection>, TrafficLimits::registrations>> connections_;
      tbc::val_a<ds::Box<TrafficReply, ConcurrentMemory>> reply_;
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
      std::string_view trace_prefix;
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
      Worker(Worker&&) = delete;
      Worker& operator=(Worker&&) = delete;

      void stop() noexcept;
      void revoke() noexcept;
      bool revoked() const noexcept;

      // The worker queues the exchange, and what it keeps of the allocator: region `a`.
      void submit(tbc::val_a<Shared> exchange) noexcept;

      WorkerMetrics metrics() const noexcept;
      const ServiceSpec& specification() const noexcept;

    private:
      static ServiceSpec bindPermissions(ConcurrentMemory& memory, const ServiceSpec& specification);

      void run() noexcept;
      void runTraffic() noexcept;

      // Waits while the worker is disabled for either cancellation; false when the wait failed.
      bool awaitCancellation() noexcept;

      // Starts the session and its traffic bridge, and hands the bridge the session.
      void startTraffic();
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
      tbc::val_a<DropChannel<Shared, Limits::queue_depth, ChannelPolicy::keep_newest>> requests_;
      CancellationSignal cancellation_;
      ds::Option<Session<ConcurrentMemory>> session_;
      ds::Box<TrafficBridge, ConcurrentMemory> bridge_;
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
