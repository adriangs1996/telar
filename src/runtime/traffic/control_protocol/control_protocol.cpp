module telar.runtime.traffic.control_protocol;

import telar.native.pcap;

namespace telar::runtime::traffic {

  auto Protocol::greeting(tbc::view<std::span<Byte>, tbc::lt::a> output, Role role, std::string_view filter, Selection selection) -> tbc::view<std::span<const Byte>, tbc::lt::a> {
    if (filter.size() > Limits::filter_bytes || filter.contains('\0') || (role != Role::subscribe && !filter.empty())) {
      throw EncodingError{"Invalid traffic subscription"};
    }

    plugins::FrameWriter writer{output};

    writer.integer(magic);
    writer.tag(role);
    writer.tag(selection);
    writer.text(filter);
    return writer.finish();
  }

  std::size_t Protocol::encodedSize(const Event& event) {
    validate(event);
    constexpr auto fixed_bytes = 2 * sizeof(Byte) + 6 * sizeof(std::uint64_t) + 5 * sizeof(std::uint32_t);

    return fixed_bytes + event.interface.size() + event.bytes.size();
  }

  auto Protocol::encode(tbc::view<std::span<Byte>, tbc::lt::a> output, const Event& event) -> tbc::view<std::span<const Byte>, tbc::lt::a> {
    validate(event);
    plugins::FrameWriter writer{output};

    writer.tag(event.kind);
    writer.integer(event.session);
    writer.integer(event.sequence);
    writer.integer(event.timestamp_us);
    writer.integer(event.interface_index);
    writer.integer(event.link_type);
    writer.integer(event.original_bytes);
    writer.integer(event.kernel_drops);
    writer.integer(event.capture_drops);
    writer.integer(event.runtime_drops);
    writer.boolean(event.offline);
    writer.text(event.interface);
    writer.bytes(event.bytes);
    return writer.finish();
  }

  auto Protocol::decode(std::span<const Byte> input) -> Event {
    if (input.size() > Limits::http_frame_bytes) {
      throw EncodingError{"Traffic frame exceeds its limit"};
    }

    plugins::FrameReader reader{input};
    Event event;

    event.kind = reader.tag(Kind::datagram);
    event.session = reader.integer<std::uint64_t>();
    event.sequence = reader.integer<std::uint64_t>();
    event.timestamp_us = reader.integer<std::uint64_t>();
    event.interface_index = reader.integer<std::uint32_t>();
    event.link_type = reader.integer<std::uint32_t>();
    event.original_bytes = reader.integer<std::uint32_t>();
    event.kernel_drops = reader.integer<std::uint64_t>();
    event.capture_drops = reader.integer<std::uint64_t>();
    event.runtime_drops = reader.integer<std::uint64_t>();
    event.offline = reader.boolean();
    event.interface = reader.text();
    event.bytes = reader.bytes();
    reader.finish();
    validate(event);
    return event;
  }

  auto Protocol::prefix(std::size_t bytes, std::uint64_t dropped) -> std::array<Byte, prefix_bytes> {
    if (bytes > Limits::http_frame_bytes) {
      throw EncodingError{"Traffic frame exceeds its limit"};
    }

    std::array<Byte, prefix_bytes> output{};
    plugins::FrameWriter writer{output};

    writer.integer(static_cast<std::uint32_t>(bytes));
    writer.integer(dropped);
    return output;
  }

  auto Protocol::name(Kind kind) noexcept -> std::string_view {
    constexpr std::array names{"ready", "packet", "interface.open", "interface.closed", "interface.error", "statistics", "capture.started", "capture.stopped", "error", "exchange", "flow.open", "stream.data", "flow.close", "flow.error", "flow.gap", "intercept.request", "http.intercept.request", "datagram"};

    return names.at(static_cast<std::size_t>(kind));
  }

  void Protocol::validate(const Event& event) {
    const auto maximum = event.kind == Kind::http_intercept_request ? HttpMessageLimits::message_bytes + Limits::metadata_bytes : Limits::packet_bytes;
    if (event.interface.size() > Limits::interface_bytes || event.interface.contains('\0') || event.bytes.size() > maximum || (event.kind == Kind::packet && event.bytes.size() > event.original_bytes)) {
      throw EncodingError{"Invalid traffic event"};
    }
  }
}

namespace telar::runtime::traffic::recording {

  void Protocol::write(plugins::FrameWriter& writer, const Request& request) {
    validate(request);
    writer.tag(request.operation);
    writer.integer(request.id);
    writer.integer(request.cursor);
    writer.integer(request.max_bytes);
    writer.integer(request.max_events);
    writer.integer(request.max_age_ms);
    writer.integer(request.limit);
    writer.tag(request.selection);
    writer.text(request.filter);
    writer.text(request.host);
  }

  tbc::view<Request, tbc::lt::a> Protocol::read(plugins::FrameReader& reader) {
    Request request;

    request.operation = reader.tag(Operation::list);
    request.id = reader.integer<std::uint64_t>();
    request.cursor = reader.integer<std::uint64_t>();
    request.max_bytes = reader.integer<std::uint64_t>();
    request.max_events = reader.integer<std::uint32_t>();
    request.max_age_ms = reader.integer<std::uint32_t>();
    request.limit = reader.integer<std::uint32_t>();
    request.selection = reader.tag(Selection::all);
    request.filter = reader.text();
    request.host = reader.text();
    validate(request);
    return request;
  }

  void Protocol::header(plugins::FrameWriter& writer, const Page& page) {
    writer.integer(page.id);
    writer.boolean(page.active);
    writer.boolean(page.gap);
    writer.tag(page.format);
    writer.integer(page.oldest);
    writer.integer(page.next);
    writer.integer(page.end);
    writer.integer(page.evicted);
    writer.integer(page.dropped);
    writer.integer(page.contention_drops);
    writer.integer(page.bytes);
    writer.integer(page.count);
  }

  Page Protocol::page(std::span<const Byte> input) {
    if (input.size() > Limits::page_bytes || input.size() < page_header_bytes) {
      throw EncodingError{"Invalid recording page size"};
    }

    plugins::FrameReader reader{input.first(page_header_bytes)};
    Page page;

    page.id = reader.integer<std::uint64_t>();
    page.active = reader.boolean();
    page.gap = reader.boolean();
    page.format = reader.tag(Format::list);
    page.oldest = reader.integer<std::uint64_t>();
    page.next = reader.integer<std::uint64_t>();
    page.end = reader.integer<std::uint64_t>();
    page.evicted = reader.integer<std::uint64_t>();
    page.dropped = reader.integer<std::uint64_t>();
    page.contention_drops = reader.integer<std::uint64_t>();
    page.bytes = reader.integer<std::uint64_t>();
    page.count = reader.integer<std::uint32_t>();
    reader.finish();
    if (page.count > Limits::page_events || page.next > page.end || page.oldest > page.end) {
      throw EncodingError{"Invalid recording cursor"};
    }

    page.rows = input.subspan(page_header_bytes);
    return page;
  }

  void Protocol::validate(const Request& request) {
    const auto selection = static_cast<Byte>(request.selection);
    const bool no_identity = request.operation == Operation::start || request.operation == Operation::list;
    if (request.max_bytes == 0 || request.max_bytes > Limits::session_bytes || request.max_events == 0 || request.max_events > Limits::events || request.max_age_ms == 0 || request.max_age_ms > Limits::age_ms || request.limit == 0 || request.limit > Limits::page_events || selection == 0 || selection > static_cast<Byte>(Selection::all) || request.filter.size() > traffic::Limits::filter_bytes || request.filter.contains('\0') || request.host.size() > 255 || request.host.contains('\0') || (no_identity ? request.id != 0 : request.id == 0)) {
      throw EncodingError{"Invalid recording request"};
    }

    if (request.operation != Operation::start && !request.filter.empty()) {
      throw EncodingError{"A recording filter is set at creation"};
    }
  }
}

namespace telar::runtime::traffic::control {

  Request Protocol::action(std::string_view name) {
    constexpr std::array names{"status", "capture.start", "capture.stop", "redirect.start", "redirect.stop", "ca.certificate", "ca.install", "ca.uninstall", "ca.rotate"};
    const auto found = std::ranges::find(names, name);
    if (found != names.end()) {
      return {.operation = static_cast<Operation>(found - names.begin())};
    }

    constexpr std::array recordings{"recording.start", "recording.query", "recording.stop", "recording.remove", "recording.export", "recording.list"};
    const auto recording = std::ranges::find(recordings, name);
    if (recording != recordings.end()) {
      return {.operation = Operation::recording, .recording = recording::Request{.operation = static_cast<recording::Operation>(recording - recordings.begin())}};
    }

    throw EncodingError{"Unknown network control action"};
  }

  auto Protocol::prefix(std::size_t size) -> std::array<Byte, prefix_bytes> {
    if (size == 0 || size > Limits::reply_bytes) {
      throw EncodingError{"Invalid network control frame size"};
    }

    std::array<Byte, prefix_bytes> output;
    plugins::FrameWriter writer{output};

    writer.integer(static_cast<std::uint32_t>(size));
    return output;
  }

  tbc::view<std::span<const Byte>, tbc::lt::a> Protocol::encode(tbc::view<std::span<Byte>, tbc::lt::a> output, const Request& request) {
    validate(request);
    plugins::FrameWriter writer{output.first(std::min(output.size(), Limits::request_bytes))};

    writer.integer(request.direction != redirect::Direction::outbound ? direction_magic : request.process_count != 0 ? selection_magic
                                                                                      : request.recording            ? recording_magic
                                                                                                                     : magic);
    writer.tag(request.operation);
    writer.integer(static_cast<Byte>(request.target_count));
    for (const auto target : std::span{request.targets}.first(request.target_count)) {
      writer.text(target);
    }

    if (request.recording) {
      recording::Protocol::write(writer, *request.recording);
    }

    if (request.process_count != 0 || request.direction != redirect::Direction::outbound) {
      writer.integer(static_cast<Byte>(request.process_count));
      for (const auto pid : std::span{request.processes}.first(request.process_count)) {
        writer.integer(pid);
      }
    }

    if (request.direction != redirect::Direction::outbound) {
      writer.tag(request.direction);
    }

    return writer.finish();
  }

  Request Protocol::request(std::span<const Byte> bytes) {
    if (bytes.size() > Limits::request_bytes) {
      throw EncodingError{"Network control request exceeds its bound"};
    }

    plugins::FrameReader reader{bytes};
    const auto version = reader.integer<std::uint32_t>();
    if (version != magic && version != recording_magic && version != selection_magic && version != direction_magic) {
      throw EncodingError{"Incompatible network control protocol"};
    }

    Request request;

    request.operation = reader.tag(version != magic ? Operation::recording : Operation::ca_rotate);
    request.target_count = reader.integer<Byte>();
    if (request.target_count > request.targets.size()) {
      throw EncodingError{"Too many redirect targets"};
    }

    for (auto& target : std::span{request.targets}.first(request.target_count)) {
      target = reader.text();
    }

    if (request.operation == Operation::recording) {
      request.recording = recording::Protocol::read(reader);
    }

    if (version == selection_magic || version == direction_magic) {
      request.process_count = reader.integer<Byte>();
      if (request.process_count > request.processes.size()) {
        throw EncodingError{"Too many selected processes"};
      }

      for (auto& pid : std::span{request.processes}.first(request.process_count)) {
        pid = reader.integer<std::uint32_t>();
      }
    }

    if (version == direction_magic) {
      request.direction = reader.tag(redirect::Direction::both);
    }

    reader.finish();
    validate(request);
    return request;
  }

  tbc::view<std::span<const Byte>, tbc::lt::a> Protocol::encode(tbc::view<std::span<Byte>, tbc::lt::a> output, const Reply& reply) {
    validate(reply);
    plugins::FrameWriter writer{output.first(std::min(output.size(), Limits::reply_bytes))};

    writer.integer(reply.recording.empty() ? magic : recording_magic);
    writer.tag(reply.result);
    writer.tag(reply.status.capture);
    writer.tag(reply.status.redirect);
    writer.tag(reply.status.trust);
    writer.boolean(reply.status.proxy);
    writer.boolean(reply.status.transparent_tls);
    writer.boolean(reply.status.tls_accepting);
    writer.boolean(reply.status.interception);
    writer.boolean(reply.status.administration);
    writer.integer(reply.status.port);
    writer.integer(reply.status.capture_session);
    writer.integer(reply.status.interfaces);
    writer.integer(reply.status.interface_errors);
    writer.text(reply.message);
    writer.text(reply.fingerprint_sha1);
    writer.text(reply.fingerprint_sha256);
    writer.bytes(reply.certificate);
    writer.integer(static_cast<Byte>(reply.argument_count));
    for (const auto argument : std::span{reply.authorization}.first(reply.argument_count)) {
      writer.text(argument);
    }

    if (!reply.recording.empty()) {
      writer.bytes(reply.recording);
    }

    return writer.finish();
  }

  Reply Protocol::reply(std::span<const Byte> bytes) {
    if (bytes.size() > Limits::reply_bytes) {
      throw EncodingError{"Network control reply exceeds its bound"};
    }

    plugins::FrameReader reader{bytes};
    const auto version = reader.integer<std::uint32_t>();
    if (version != magic && version != recording_magic) {
      throw EncodingError{"Incompatible network control protocol"};
    }

    Reply reply;

    reply.result = reader.tag(Result::cleanup_required);
    reply.status.capture = reader.tag(CaptureState::offline);
    reply.status.redirect = reader.tag(RedirectState::cleanup_required);
    reply.status.trust = reader.tag(TrustState::stale);
    reply.status.proxy = reader.boolean();
    reply.status.transparent_tls = reader.boolean();
    reply.status.tls_accepting = reader.boolean();
    reply.status.interception = reader.boolean();
    reply.status.administration = reader.boolean();
    reply.status.port = reader.integer<std::uint16_t>();
    reply.status.capture_session = reader.integer<std::uint64_t>();
    reply.status.interfaces = reader.integer<std::uint32_t>();
    reply.status.interface_errors = reader.integer<std::uint32_t>();
    reply.message = reader.text();
    reply.fingerprint_sha1 = reader.text();
    reply.fingerprint_sha256 = reader.text();
    reply.certificate = reader.bytes();
    reply.argument_count = reader.integer<Byte>();
    if (reply.argument_count > reply.authorization.size()) {
      throw EncodingError{"Too many authorization arguments"};
    }

    for (auto& argument : std::span{reply.authorization}.first(reply.argument_count)) {
      argument = reader.text();
    }

    if (version == recording_magic) {
      reply.recording = reader.bytes();
    }

    reader.finish();
    validate(reply);
    return reply;
  }

  void Protocol::validate(const Request& request) {
    if ((!redirect::allowsIncoming(request.direction) && !redirect::allowsOutgoing(request.direction)) || (request.direction != redirect::Direction::outbound && request.operation != Operation::redirect_start) || (redirect::allowsIncoming(request.direction) && request.process_count != 0)) {
      throw EncodingError{"Incoming redirect selects local services by account; process selection is outbound only"};
    }

    if (request.process_count > request.processes.size() || (request.process_count != 0 && request.operation != Operation::redirect_start)) {
      throw EncodingError{"Processes are only valid for redirect selection"};
    }

    const auto processes = std::span{request.processes}.first(request.process_count);

    for (std::size_t index = 0; index < processes.size(); ++index) {
      if (processes[index] == 0 || processes[index] > std::numeric_limits<std::int32_t>::max() || std::ranges::find(processes.first(index), processes[index]) != processes.first(index).end()) {
        throw EncodingError{"Invalid or duplicate selected process"};
      }
    }

    if ((request.operation == Operation::recording) != request.recording.has_value()) {
      throw EncodingError{"Recording operation requires a recording request"};
    }

    if (request.target_count > request.targets.size() || (request.operation == Operation::redirect_start ? request.target_count == 0 : request.target_count != 0)) {
      throw EncodingError{"Redirect start requires targets; other operations accept none"};
    }

    for (const auto target : std::span{request.targets}.first(request.target_count)) {
      if (target.empty() || target.size() > Limits::target_bytes || target.find_first_of("\r\n\0", 0, 3) != std::string_view::npos) {
        throw EncodingError{"Invalid redirect target"};
      }
    }
  }

  void Protocol::validate(const Reply& reply) {
    if (reply.recording.size() > recording::Limits::page_bytes) {
      throw EncodingError{"Recording reply exceeds its bound"};
    }

    if (reply.message.size() > 1024 || reply.certificate.size() > Limits::certificate_bytes || reply.argument_count > reply.authorization.size() || (!reply.fingerprint_sha1.empty() && reply.fingerprint_sha1.size() != 40) || (!reply.fingerprint_sha256.empty() && reply.fingerprint_sha256.size() != 64)) {
      throw EncodingError{"Invalid network control reply"};
    }

    for (const auto argument : std::span{reply.authorization}.first(reply.argument_count)) {
      if (argument.empty() || argument.size() > 4096 || argument.contains('\0')) {
        throw EncodingError{"Invalid authorization argument"};
      }
    }
  }
}

namespace telar::runtime::traffic {

  FilterProgram::~FilterProgram() {
    pcap_freecode(&value);
  }

  Filter::Filter(std::string_view expression) {
    if (expression.contains('\0')) {
      throw std::invalid_argument{"Traffic filter contains NUL"};
    }

    expression_.assign(expression);

    // Validate syntax before accepting a subscription, including before capture starts.
    if (!expression.empty()) {
      compile(expression_.view(), DLT_EN10MB, validation_);
    }
  }

  bool Filter::matches(const Event& event) {
    if (event.kind != Kind::packet || expression_.view().empty()) {
      return true;
    }

    for (auto& entry : programs_) {
      if (entry && entry->link_type == event.link_type) {
        return apply(entry->program, event);
      }
    }

    for (auto& entry : programs_) {
      if (!entry) {
        entry.emplace();
        entry->link_type = event.link_type;
        compile(expression_.view(), static_cast<int>(event.link_type), entry->program);
        return apply(entry->program, event);
      }
    }

    throw std::runtime_error{"Traffic filter link-type limit reached"};
  }

  void Filter::compile(std::string_view filter, int link_type, Program& program) {
    const std::unique_ptr<pcap_t, decltype(&pcap_close)> dead{pcap_open_dead(link_type, Limits::packet_bytes), &pcap_close};
    if (!dead) {
      throw std::runtime_error{"Unable to compile traffic filter for link type"};
    }

    std::array<char, Limits::filter_bytes + 1> expression{};

    std::ranges::copy(filter, expression.begin());
    if (pcap_compile(dead.get(), &program.value, expression.data(), 1, PCAP_NETMASK_UNKNOWN) < 0) {
      throw std::invalid_argument{pcap_geterr(dead.get())};
    }
  }

  bool Filter::apply(const Program& program, const Event& event) noexcept {
    pcap_pkthdr header{};

    header.caplen = static_cast<bpf_u_int32>(event.bytes.size());
    header.len = event.original_bytes;
    return pcap_offline_filter(&program.value, &header, event.bytes.data()) != 0;
  }

  FlowIdentity FlowIdentity::of(const FlowEvent& event) noexcept {
    FlowIdentity identity{.id = event.id, .visibility = event.visibility, .source = event.source};

    identity.client.assign(event.client.substr(0, endpoint_bytes));
    identity.server.assign(event.server.substr(0, endpoint_bytes));
    identity.host.assign(event.host.substr(0, ProxyHostname::maximum_bytes));
    return identity;
  }

  FlowEvent FlowIdentity::event(Direction direction) const noexcept {
    return {.id = id, .direction = direction, .visibility = visibility, .source = source, .client = client.view(), .server = server.view(), .host = host.view()};
  }

  auto FlowCodec::encode(tbc::view<std::span<Byte>, tbc::lt::a> output, const FlowEvent& event) -> tbc::view<std::span<const Byte>, tbc::lt::a> {
    plugins::FrameWriter writer{output};

    writer.integer(event.id);
    writer.tag(event.direction);
    writer.tag(event.visibility);
    writer.tag(event.source);
    writer.integer(event.offset);
    writer.integer(event.ticket);
    writer.text(event.client);
    writer.text(event.server);
    writer.text(event.host);
    writer.text(event.reason);
    writer.bytes(event.bytes);
    return writer.finish();
  }

  FlowEvent FlowCodec::decode(std::span<const Byte> input) {
    plugins::FrameReader reader{input};
    FlowEvent event;

    event.id = reader.integer<std::uint64_t>();
    event.direction = reader.tag(Direction::inbound);
    event.visibility = reader.tag(Visibility::plaintext);
    event.source = reader.tag(FlowSource::capture);
    event.offset = reader.integer<std::uint64_t>();
    event.ticket = reader.integer<std::uint64_t>();
    event.client = reader.text();
    event.server = reader.text();
    event.host = reader.text();
    event.reason = reader.text();
    event.bytes = reader.bytes();
    reader.finish();
    if (event.client.size() > 128 || event.server.size() > 128 || event.host.size() > 253 || event.reason.size() > 128) {
      throw EncodingError{"Invalid flow metadata"};
    }

    return event;
  }

  HttpControl* FlowControl::http() noexcept {
    return nullptr;
  }

  bool isFlow(Kind kind) noexcept {
    return kind >= Kind::flow_open && kind <= Kind::flow_gap;
  }

  bool selects(Selection selection, Selection flag) noexcept {
    return (static_cast<Byte>(selection) & static_cast<Byte>(flag)) != 0;
  }

  void Pcapng::section(plugins::FrameWriter& writer) {
    writer.integer<std::uint32_t>(0x0a0d0d0a);
    writer.integer<std::uint32_t>(section_bytes);
    writer.integer<std::uint32_t>(0x1a2b3c4d);
    writer.integer<std::uint16_t>(1);
    writer.integer<std::uint16_t>(0);
    writer.integer<std::uint64_t>(std::numeric_limits<std::uint64_t>::max());
    writer.integer<std::uint32_t>(section_bytes);
  }

  std::size_t Pcapng::packetBytes(const Event& event) {
    return 20 + 8 + padded(event.interface.size()) + 32 + padded(event.bytes.size());
  }

  void Pcapng::packet(plugins::FrameWriter& writer, const Event& event, std::uint32_t interface) {
    if (event.kind != Kind::packet || event.link_type > std::numeric_limits<std::uint16_t>::max()) {
      throw EncodingError{"Packet cannot be represented in PCAPNG"};
    }

    const auto interface_bytes = static_cast<std::uint32_t>(20 + 8 + padded(event.interface.size()));

    writer.integer<std::uint32_t>(1);
    writer.integer(interface_bytes);
    writer.integer(static_cast<std::uint16_t>(event.link_type));
    writer.integer<std::uint16_t>(0);
    writer.integer<std::uint32_t>(Limits::packet_bytes);
    writer.integer<std::uint16_t>(2);
    writer.integer(static_cast<std::uint16_t>(event.interface.size()));
    raw(writer, {reinterpret_cast<const Byte*>(event.interface.data()), event.interface.size()});
    writer.integer<std::uint32_t>(0);
    writer.integer(interface_bytes);
    const auto packet_bytes = static_cast<std::uint32_t>(32 + padded(event.bytes.size()));

    writer.integer<std::uint32_t>(6);
    writer.integer(packet_bytes);
    writer.integer(interface);
    writer.integer(static_cast<std::uint32_t>(event.timestamp_us >> 32));
    writer.integer(static_cast<std::uint32_t>(event.timestamp_us));
    writer.integer(static_cast<std::uint32_t>(event.bytes.size()));
    writer.integer(event.original_bytes);
    raw(writer, event.bytes);
    writer.integer(packet_bytes);
  }

  std::size_t Pcapng::padded(std::size_t size) noexcept {
    return (size + 3) & ~std::size_t{3};
  }

  void Pcapng::raw(plugins::FrameWriter& writer, std::span<const Byte> bytes) {
    writer.append(bytes);
    for (std::size_t index = bytes.size(); index < padded(bytes.size()); ++index) {
      writer.integer<Byte>(0);
    }
  }
}
