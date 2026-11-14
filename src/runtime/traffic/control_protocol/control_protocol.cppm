module;
#include "tbc/annotations.hpp"
#include <cstdio>
#include <cstdlib>
#include <new>

#include <cstddef>
#include <cstdint>
#include <cstring>

#include <pcap/pcap.h>

export module telar.runtime.traffic.control_protocol;

import std;
import telar.tbc;

export import telar.runtime.vocabulary.frames;
export import telar.runtime.http.message;

export import telar.runtime.redirect.direction;
import telar.base.diagnostics;
import telar.base.text;
import telar.base.text.utf8;
import telar.vocabulary;

// Interface: traffic/protocol.cppm
export {
  namespace telar::runtime::traffic {

    inline constexpr std::string_view socket_suffix = ".traffic";

    struct Limits {
      static constexpr std::size_t packet_bytes = 262144;
      static constexpr std::size_t metadata_bytes = 1024;
      static constexpr std::size_t frame_bytes = packet_bytes + metadata_bytes;
      static constexpr std::size_t http_frame_bytes = HttpMessageLimits::message_bytes + 2 * metadata_bytes;
      static constexpr std::size_t filter_bytes = 4096;
      static constexpr std::size_t interface_bytes = 64;
      static constexpr std::size_t interfaces = 128;
      static constexpr std::size_t subscribers = 32;
      static constexpr std::size_t pending_frames = 8;
      static constexpr std::size_t filter_link_types = 16;
      static constexpr std::size_t http_part_bytes = static_cast<long>(48) * 1024;
    };

    enum class Role : Byte {
      subscribe = 1,
      live_capture = 2,
      offline_capture = 3,
      intercept = 4,
    };

    enum class Kind : Byte {
      ready,
      packet,
      interface_open,
      interface_closed,
      interface_error,
      statistics,
      capture_started,
      capture_stopped,
      error,
      exchange,
      flow_open,
      stream_data,
      flow_close,
      flow_error,
      flow_gap,
      intercept_request,
      http_intercept_request,
      datagram,
    };

    enum class Selection : Byte {
      packets = 1,
      exchanges = 2,
      both = 3,
      flows = 4,
      datagrams = 8,
      all = 15,
    };

    struct Event {
      Kind kind = Kind::packet;
      std::uint64_t session = 0;
      std::uint64_t sequence = 0;
      std::uint64_t timestamp_us = 0;
      std::uint32_t interface_index = 0;
      std::uint32_t link_type = 0;
      std::uint32_t original_bytes = 0;
      std::uint64_t kernel_drops = 0;
      std::uint64_t capture_drops = 0;
      std::uint64_t runtime_drops = 0;
      bool offline = false;
      std::string_view interface;
      std::span<const Byte> bytes;
    };

    // The independent data socket keeps packet backpressure out of terminal control delivery.
    class Protocol {
    public:
      static constexpr std::uint32_t magic = 0x31525454;
      static constexpr std::size_t prefix_bytes = sizeof(std::uint32_t) + sizeof(std::uint64_t);
      static constexpr std::size_t greeting_bytes = sizeof(std::uint32_t) + (2 * sizeof(Byte)) + sizeof(std::uint32_t);

      static auto greeting(tbc::view<std::span<Byte>, tbc::lt::a> output, Role role, std::string_view filter = {}, Selection selection = Selection::packets) -> tbc::view<std::span<const Byte>, tbc::lt::a>;

      static std::size_t encodedSize(const Event& event);

      static auto encode(tbc::view<std::span<Byte>, tbc::lt::a> output, const Event& event) -> tbc::view<std::span<const Byte>, tbc::lt::a>;

      static auto decode(std::span<const Byte> input) -> Event;

      static auto prefix(std::size_t bytes, std::uint64_t dropped = 0) -> std::array<Byte, prefix_bytes>;

      static auto name(Kind kind) noexcept -> std::string_view;

    private:
      static void validate(const Event& event);
    };

  }
}

// Interface: traffic/recording_protocol.cppm
export {
  namespace telar::runtime::traffic::recording {

    struct Limits {
      static constexpr std::size_t sessions = 4;
      static constexpr std::size_t session_bytes = 64 * 1024 * 1024;
      static constexpr std::size_t total_bytes = 128 * 1024 * 1024;
      static constexpr std::size_t events = 4096;
      static constexpr std::uint32_t age_ms = 60 * 60 * 1000;
      static constexpr std::size_t page_bytes = 512 * 1024;
      static constexpr std::uint32_t page_events = 128;
    };

    enum class Operation : Byte {
      start,
      query,
      stop,
      erase,
      pcapng,
      list,
    };
    enum class Format : Byte {
      events,
      pcapng,
      list,
    };

    struct Request {
      Operation operation = Operation::query;
      std::uint64_t id = 0;
      std::uint64_t cursor = 0;
      std::uint64_t max_bytes = 8 * 1024 * 1024;
      std::uint32_t max_events = 4096;
      std::uint32_t max_age_ms = 60000;
      std::uint32_t limit = 64;
      Selection selection = Selection::all;
      std::string_view filter;
      std::string_view host;
    };

    struct Page {
      std::uint64_t id = 0;
      bool active = false;
      bool gap = false;
      Format format = Format::events;
      std::uint64_t oldest = 1;
      std::uint64_t next = 1;
      std::uint64_t end = 1;
      std::uint64_t evicted = 0;
      std::uint64_t dropped = 0;
      std::uint64_t contention_drops = 0;
      std::uint64_t bytes = 0;
      std::uint32_t count = 0;
      std::span<const Byte> rows;
    };

    class Protocol {
    public:
      static constexpr std::size_t page_header_bytes = 8 * sizeof(std::uint64_t) + 3 * sizeof(Byte) + sizeof(std::uint32_t);

      static void write(plugins::FrameWriter& writer, const Request& request);

      // The request views the reader's frame.
      static tbc::view<Request, tbc::lt::a> read(plugins::FrameReader& reader);

      static void header(plugins::FrameWriter& writer, const Page& page);

      static Page page(std::span<const Byte> input);

    private:
      static void validate(const Request& request);
    };

  }
}

// Interface: traffic/control_protocol.cppm
export {
  namespace telar::runtime::traffic::control {

    inline constexpr std::string_view socket_suffix = ".network";

    struct Limits {
      static constexpr std::size_t request_bytes = 8192;
      static constexpr std::size_t reply_bytes = recording::Limits::page_bytes + 32768;
      static constexpr std::size_t certificate_bytes = 4096;
      static constexpr std::size_t targets = 16;
      static constexpr std::size_t target_bytes = 259;
      static constexpr std::size_t arguments = 80;
      static constexpr std::size_t processes = 16;
      static constexpr std::size_t peers = 16;
    };

    enum class Operation : Byte {
      status,
      capture_start,
      capture_stop,
      redirect_start,
      redirect_stop,
      ca_certificate,
      ca_install,
      ca_uninstall,
      ca_rotate,
      recording,
    };
    enum class Result : Byte {
      ok,
      disabled,
      authorization_required,
      busy,
      failed,
      cleanup_required,
    };
    enum class CaptureState : Byte {
      disabled,
      idle,
      live,
      offline,
    };
    enum class RedirectState : Byte {
      disabled,
      idle,
      starting,
      active,
      stopping,
      cleanup_required,
    };
    enum class TrustState : Byte {
      absent,
      installed,
      stale,
    };

    struct Request {
      Operation operation = Operation::status;
      std::array<std::string_view, Limits::targets> targets{};
      std::size_t target_count = 0;
      std::optional<recording::Request> recording;
      std::array<std::uint32_t, Limits::processes> processes{};
      std::size_t process_count = 0;
      redirect::Direction direction = redirect::Direction::outbound;
    };

    struct Status {
      CaptureState capture = CaptureState::disabled;
      RedirectState redirect = RedirectState::disabled;
      TrustState trust = TrustState::absent;
      bool proxy = false;
      bool transparent_tls = false;
      bool tls_accepting = false;
      bool interception = false;
      bool administration = false;
      std::uint16_t port = 0;
      std::uint64_t capture_session = 0;
      std::uint32_t interfaces = 0;
      std::uint32_t interface_errors = 0;
    };

    struct Reply {
      Result result = Result::ok;
      Status status{};
      std::string_view message;
      std::string_view fingerprint_sha1;
      std::string_view fingerprint_sha256;
      std::span<const Byte> certificate;
      std::array<std::string_view, Limits::arguments> authorization{};
      std::size_t argument_count = 0;
      std::span<const Byte> recording;
    };

    class Protocol {
    public:
      static constexpr std::uint32_t magic = 0x31434e54;
      static constexpr std::uint32_t recording_magic = 0x32434e54;
      static constexpr std::uint32_t selection_magic = 0x33434e54;
      static constexpr std::uint32_t direction_magic = 0x34434e54;
      static constexpr std::size_t prefix_bytes = sizeof(std::uint32_t);

      static Request action(std::string_view name);

      static std::array<Byte, prefix_bytes> prefix(std::size_t size);

      static tbc::view<std::span<const Byte>, tbc::lt::a> encode(tbc::view<std::span<Byte>, tbc::lt::a> output, const Request& request);

      static Request request(std::span<const Byte> bytes);

      static tbc::view<std::span<const Byte>, tbc::lt::a> encode(tbc::view<std::span<Byte>, tbc::lt::a> output, const Reply& reply);

      static Reply reply(std::span<const Byte> bytes);

    private:
      static void validate(const Request& request);

      static void validate(const Reply& reply);
    };

  }
}

// Interface: traffic/filter.cppm
export {
  namespace telar::runtime::traffic {

    // Outside Filter, so its optional entries see a complete, default
    // constructible type: Clang rejects emplace on a nested class whose member
    // initializers it has not yet parsed.
    struct FilterProgram {
      bpf_program value{};

      ~FilterProgram();
    };

    struct FilterEntry {
      std::uint32_t link_type = 0;
      FilterProgram program;
    };

    class Filter {
    public:
      Filter(const Filter&) = delete;
      Filter& operator=(const Filter&) = delete;

      explicit Filter(std::string_view expression);

      bool matches(const Event& event);

    private:
      using Program = FilterProgram;
      using Entry = FilterEntry;

      static void compile(std::string_view filter, int link_type, Program& program);

      static bool apply(const Program& program, const Event& event) noexcept;

      FixedText<Limits::filter_bytes> expression_;
      Program validation_;
      std::array<std::optional<Entry>, Limits::filter_link_types> programs_;
    };

  }
}

// Interface: traffic/flow.cppm
export {
  namespace telar::runtime::traffic {

    enum class Direction : Byte {
      outbound,
      inbound,
    };
    enum class Visibility : Byte {
      wire,
      plaintext,
    };
    enum class FlowSource : Byte {
      proxy,
      capture,
    };
    enum class Verdict : Byte {
      pending,
      allow,
      replace,
      reject,
    };
    class HttpControl;

    struct FlowEvent {
      std::uint64_t id = 0;
      Direction direction = Direction::outbound;
      Visibility visibility = Visibility::wire;
      FlowSource source = FlowSource::proxy;
      std::uint64_t offset = 0;
      std::uint64_t ticket = 0;
      std::string_view client;
      std::string_view server;
      std::string_view host;
      std::string_view reason;
      std::span<const Byte> bytes;
    };

    // Who a flow is, owned: what every event of it carries. A relay keeps its own copy, so its events
    // view the relay and not the flow it came from.
    struct FlowIdentity {
      std::uint64_t id = 0;
      Visibility visibility = Visibility::wire;
      FlowSource source = FlowSource::proxy;
      static constexpr std::size_t endpoint_bytes = 128;
      FixedText<endpoint_bytes> client;
      FixedText<endpoint_bytes> server;
      FixedText<ProxyHostname::maximum_bytes> host;

      static FlowIdentity of(const FlowEvent& event) noexcept;

      FlowEvent event(Direction direction = Direction::outbound) const noexcept;
    };

    class FlowCodec {
    public:
      static auto encode(tbc::view<std::span<Byte>, tbc::lt::a> output, const FlowEvent& event) -> tbc::view<std::span<const Byte>, tbc::lt::a>;

      static FlowEvent decode(std::span<const Byte> input);
    };

    // What hooks decide about proxied flows, which every flow reports to at once.
    class TBC_SHARED FlowControl {
    public:
      using Time = std::chrono::steady_clock::time_point;
      static constexpr std::size_t chunk_bytes = 64 * 1024;

      struct Decision {
        Verdict verdict;
        std::size_t bytes = 0;
      };

      virtual ~FlowControl() = default;
      virtual void observeFlow(Kind kind, const FlowEvent& event) noexcept = 0;
      virtual std::uint64_t intercept(const FlowEvent& event) noexcept = 0;
      virtual Decision poll(std::uint64_t ticket, std::span<Byte> replacement) noexcept = 0;
      virtual void cancel(std::uint64_t ticket) noexcept = 0;
      virtual std::optional<Time> deadline(std::uint64_t ticket) noexcept = 0;
      virtual int descriptor() const noexcept = 0;
      virtual void drain() noexcept = 0;

      virtual HttpControl* http() noexcept;
    };

    struct HttpPolicy {
      bool enabled = false;
      bool fail_closed = false;
    };

    class HttpControl {
    public:
      virtual ~HttpControl() = default;
      virtual HttpPolicy policy(const FlowEvent& context) noexcept = 0;
      virtual std::uint64_t interceptHttp(const FlowEvent& event) noexcept = 0;
      virtual FlowControl::Decision pollHttp(std::uint64_t ticket, std::span<Byte> replacement) noexcept = 0;
      virtual void cancelHttp(std::uint64_t ticket) noexcept = 0;
      virtual std::optional<FlowControl::Time> httpDeadline(std::uint64_t ticket) noexcept = 0;
      virtual void httpUnavailable(const FlowEvent& event) noexcept = 0;
    };

    bool isFlow(Kind kind) noexcept;

    bool selects(Selection selection, Selection flag) noexcept;

  }
}

// Interface: traffic/pcapng.cppm
export {
  namespace telar::runtime::traffic {

    class Pcapng {
    public:
      static constexpr std::size_t section_bytes = 28;

      static void section(plugins::FrameWriter& writer);

      static std::size_t packetBytes(const Event& event);

      static void packet(plugins::FrameWriter& writer, const Event& event, std::uint32_t interface);

    private:
      static std::size_t padded(std::size_t size) noexcept;

      static void raw(plugins::FrameWriter& writer, std::span<const Byte> bytes);
    };

  }
}
