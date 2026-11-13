#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <cerrno>
#include <cstdlib>
#include <csignal>
#include <cstddef>
#include <cstring>
#include <cstdint>
#include <poll.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <net/if.h>
#include <pcap/pcap.h>
#include <pthread.h>
#include <cassert>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <limits.h>
#include <brotli/decode.h>
#include <zlib.h>
#include <zstd.h>

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.tests.check;
import telar.runtime.traffic.capture;
import telar.runtime.traffic.control_backend;
import telar.runtime.exchange_capture.producer;

using namespace telar;
using namespace telar::runtime;
using namespace telar::runtime::traffic;
using telar::Byte;

static void receiveAll(int socket, std::span<Byte> bytes) {
  while (!bytes.empty()) {
    pollfd descriptor{.fd = socket, .events = POLLIN, .revents = 0};
    check(::poll(&descriptor, 1, 5000) > 0);
    const auto count = ::recv(socket, bytes.data(), bytes.size(), 0);
    check(count > 0);
    bytes = bytes.subspan(static_cast<std::size_t>(count));
  }
}

struct Received {
  std::vector<Byte> bytes;
  std::uint64_t drops = 0;

  traffic::Event event() const { return Protocol::decode(bytes); }
};

static Received receive(int socket) {
  std::array<Byte, Protocol::prefix_bytes> prefix;
  receiveAll(socket, prefix);
  plugins::FrameReader reader{prefix};
  const auto length = reader.integer<std::uint32_t>();
  check(length <= Limits::frame_bytes);
  Received result{.bytes = std::vector<Byte>(length), .drops = reader.integer<std::uint64_t>()};
  receiveAll(socket, result.bytes);
  return result;
}

static FileDescriptor subscriber(const std::string &path, std::string_view filter, Selection selection = Selection::packets) {
  auto socket = traffic::connect(path);
  std::array<Byte, Protocol::greeting_bytes + Limits::filter_bytes> output;
  const auto greeting = Protocol::greeting(output, Role::subscribe, filter, selection);
  for (const auto &byte : greeting) {
    sendAll(socket.get(), {&byte, 1});
  }
  check(receive(socket.get()).event().kind == Kind::ready);
  return socket;
}

static void publish(int socket, traffic::Event event) {
  std::array<Byte, Limits::frame_bytes> output;
  const auto body = Protocol::encode(output, event);
  sendAll(socket, Protocol::prefix(body.size()));
  sendAll(socket, body);
}

static std::vector<Byte> packet(Byte protocol, std::string_view body) {
  constexpr std::size_t ethernet_bytes = 14;
  constexpr std::size_t ip_bytes = 20;
  constexpr std::size_t transport_bytes = 8;
  std::vector<Byte> bytes(ethernet_bytes + ip_bytes + transport_bytes + body.size());
  bytes[12] = 0x08;
  bytes[14] = 0x45;
  const auto ip_length = bytes.size() - ethernet_bytes;
  bytes[16] = static_cast<Byte>(ip_length >> 8);
  bytes[17] = static_cast<Byte>(ip_length);
  bytes[22] = 64;
  bytes[23] = protocol;
  bytes[26] = 127;
  bytes[29] = 1;
  bytes[30] = 127;
  bytes[33] = 1;
  constexpr std::uint16_t port = 53535;
  bytes[34] = static_cast<Byte>(port >> 8);
  bytes[35] = static_cast<Byte>(port);
  bytes[36] = bytes[34];
  bytes[37] = bytes[35];
  const auto udp_length = transport_bytes + body.size();
  bytes[38] = static_cast<Byte>(udp_length >> 8);
  bytes[39] = static_cast<Byte>(udp_length);
  std::ranges::copy(body, bytes.begin() + ethernet_bytes + ip_bytes + transport_bytes);
  return bytes;
}

static void codecAndFilters() {
  const auto udp = packet(17, std::string_view{"a\0b", 3});
  const auto tcp = packet(6, "ignored");
  traffic::Event original{.session = UINT64_MAX, .sequence = UINT64_MAX, .timestamp_us = 1234567, .interface_index = 7, .link_type = DLT_EN10MB, .original_bytes = static_cast<std::uint32_t>(udp.size() + 1), .kernel_drops = UINT64_MAX - 1, .capture_drops = 12, .runtime_drops = 34, .interface = "en0", .bytes = udp};
  std::array<Byte, Limits::frame_bytes> output;
  const auto encoded = Protocol::encode(output, original);
  const auto decoded = Protocol::decode(encoded);
  check(decoded.session == UINT64_MAX && decoded.sequence == UINT64_MAX);
  check(decoded.timestamp_us == 1234567 && decoded.interface_index == 7 && decoded.interface == "en0");
  check(decoded.kernel_drops == UINT64_MAX - 1 && decoded.capture_drops == 12 && decoded.runtime_drops == 34);
  check(std::ranges::equal(decoded.bytes, udp) && decoded.original_bytes > decoded.bytes.size());
  for (std::size_t length = 0; length < encoded.size(); ++length) {
    bool rejected = false;
    try {
      Protocol::decode(encoded.first(length));
    } catch (const std::exception &) {
      rejected = true;
    }
    check(rejected);
  }

  Filter filter{"udp port 53535"};
  check(filter.matches(original));
  original.bytes = tcp;
  original.original_bytes = static_cast<std::uint32_t>(tcp.size());
  check(!filter.matches(original));
  original.kind = Kind::statistics;
  check(filter.matches(original));
  original.kind = Kind::packet;
  original.bytes = udp;
  original.original_bytes = 1;
  bool rejected = false;
  try {
    Protocol::encode(output, original);
  } catch (const std::exception &) {
    rejected = true;
  }
  check(rejected);
}

static void kernelLossAccounting() {
  KernelDrops drops;
  KernelDrops::Sample first, second;
  drops.observe(first, 7, 2);
  drops.observe(second, 3, 1);
  check(drops.count() == 13);
  drops.observe(first, 7, 2);
  check(drops.count() == 13);
  drops.observe(first, 9, 4);
  check(drops.count() == 17);

  // Retiring first must not subtract its counts; a new handle starts at zero.
  first = {};
  drops.observe(first, 1, 0);
  drops.observe(second, 4, 1);
  check(drops.count() == 19);

  KernelDrops wrapping;
  KernelDrops::Sample previous;
  wrapping.observe(previous, UINT32_MAX - 1, UINT32_MAX);
  const auto before = wrapping.count();
  wrapping.observe(previous, 2, 0);
  check(wrapping.count() == before + 5);
  wrapping.observe(previous, 2, 0);
  check(wrapping.count() == before + 5);
}

static void offlineDelivery(SystemAllocator &memory, const std::string &path, const std::string &directory) {
  const auto udp = packet(17, std::string_view{"a\0b", 3});
  const auto tcp = packet(6, "ignored");
  const auto file_path = directory + "/fixture.pcap";
  const std::unique_ptr<pcap_t, decltype(&pcap_close)> dead{pcap_open_dead(DLT_EN10MB, Limits::packet_bytes), &pcap_close};
  const std::unique_ptr<pcap_dumper_t, decltype(&pcap_dump_close)> file{pcap_dump_open(dead.get(), file_path.c_str()), &pcap_dump_close};
  check(file != nullptr);
  for (const auto &bytes : {tcp, udp}) {
    pcap_pkthdr header{};
    header.ts = {.tv_sec = 123, .tv_usec = 456};
    header.caplen = static_cast<bpf_u_int32>(bytes.size());
    header.len = header.caplen;
    pcap_dump(reinterpret_cast<u_char *>(file.get()), &header, bytes.data());
  }
  check(pcap_dump_flush(file.get()) == 0);

  auto filtered = subscriber(path, "udp port 53535");
  auto all = subscriber(path, "");
  {
    Capture capture{memory, traffic::connect(path)};
    capture.offline(file_path.c_str());
  }

  std::size_t found = 0;
  while (found < 2) {
    const auto frame = receive(all.get());
    const auto event = frame.event();
    if (event.kind == Kind::packet) {
      check(event.offline && event.interface == "offline" && event.link_type == DLT_EN10MB);
      check(event.timestamp_us == 123000456 && event.session != 0);
      check(std::ranges::equal(event.bytes, found == 0 ? tcp : udp));
      ++found;
    }
  }
  for (;;) {
    const auto frame = receive(filtered.get());
    const auto event = frame.event();
    if (event.kind == Kind::packet) {
      check(std::ranges::equal(event.bytes, udp) && event.offline);
      break;
    }
  }
}

static void backpressureAndIsolation(const std::string &path) {
  auto slow = subscriber(path, "");
  const int small = 4096;
  check(::setsockopt(slow.get(), SOL_SOCKET, SO_RCVBUF, &small, sizeof(small)) == 0);
  auto producer = traffic::connect(path);
  std::array<Byte, Protocol::greeting_bytes> greeting;
  sendAll(producer.get(), Protocol::greeting(greeting, Role::offline_capture));
  check(receive(producer.get()).event().kind == Kind::ready);

  std::vector<Byte> body(64 * 1024, 0xab);
  for (std::uint64_t sequence = 1; sequence <= 256; ++sequence) {
    publish(producer.get(), traffic::Event{.session = 9, .sequence = sequence, .link_type = DLT_RAW, .original_bytes = static_cast<std::uint32_t>(body.size()), .interface = "fixture", .bytes = body});
  }

  // An unread subscriber must not prevent new subscriptions or valid control replies.
  auto healthy = subscriber(path, "udp");
  auto malicious = traffic::connect(path);
  std::array<Byte, Protocol::greeting_bytes> invalid{};
  sendAll(malicious.get(), invalid);

  bool dropped = false;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  while (!dropped && std::chrono::steady_clock::now() < deadline) {
    dropped = receive(slow.get()).drops > 0;
  }
  check(dropped);

  if (::geteuid() != 0) {
    auto forged = traffic::connect(path);
    sendAll(forged.get(), Protocol::greeting(greeting, Role::live_capture));
    pollfd descriptor{.fd = forged.get(), .events = POLLIN, .revents = 0};
    check(::poll(&descriptor, 1, 5000) > 0);
    Byte byte;
    check(::recv(forged.get(), &byte, 1, 0) == 0);
  }
  check(receive(healthy.get()).event().kind == Kind::statistics);
}

template <ConcurrentAllocator Memory>
static void exchangeDelivery(Service<Memory> &service, Memory &memory, const std::string &path) {
  auto client = subscriber(path, "", Selection::exchanges);
  check(service.listening());
  ProxyCaptureLimits limits;
  limits.enabled = true;
  CaptureProducer producer{memory, limits};
  CapturedExchange<Memory> exchange{memory};
  exchange.request = producer.start({.key = {37, 3}, .protocol = CaptureProtocol::http2, .host = "fixture.test", .started_at_ms = 1});
  exchange.response = producer.start({.key = {37, 3}, .side = CaptureSide::response, .protocol = CaptureProtocol::http2, .host = "fixture.test", .started_at_ms = 1});
  check(exchange.request && exchange.response);
  exchange.request->setMethod("POST");
  exchange.request->setTarget("/capture");
  exchange.request->append(CapturePart::request_head, ":method: POST\r\n:authority: fixture.test\r\n");
  exchange.request->append(CapturePart::request_body, std::string_view{"a\0b", 3});
  exchange.request->finish(CaptureOutcome::finished, 2);
  exchange.response->status_code = 200;
  exchange.response->body_decoded = true;
  const std::string response(128 * 1024, 'x');
  exchange.response->append(CapturePart::response_body, response);
  exchange.response->finish(CaptureOutcome::finished, 3);
  service.submit(exchange);

  for (;;) {
    const auto frame = receive(client.get());
    const auto event = frame.event();
    if (event.kind != Kind::exchange) {
      continue;
    }
    const auto view = plugins::Protocol::decodeExchange(event.bytes);
    check(view.host == "fixture.test" && view.method == "POST" && view.target == "/capture");
    check(view.key.connection == 37 && view.key.stream == 3 && view.protocol == plugins::ExchangeProtocol::h2);
    check(view.request && view.response && view.response->status_code == 200 && view.response->decoded);
    check(view.request->body.size() == 3 && view.request->body[1] == 0);
    check(view.response->body.size() == 48 * 1024 && view.response->body_truncated);
    check(exchange.response->body.size() == response.size() && !exchange.response->body.truncated);
    break;
  }
}

template <ConcurrentAllocator Memory>
static void interceptionDelivery(Service<Memory> &service, const std::string &path) {
  auto owner = traffic::connect(path);
  std::array<Byte, Limits::frame_bytes> output;
  sendAll(owner.get(), Protocol::greeting(output, Role::intercept));
  check(receive(owner.get()).event().kind == Kind::ready);
  auto send = [&](std::span<const Byte> bytes) { sendAll(owner.get(), Protocol::prefix(bytes.size())); sendAll(owner.get(), bytes); };
  send(InterceptionCodec::rule(output, {.host = "fixture.test", .visibility = 3, .timeout_ms = 5000}));
  check(receive(owner.get()).event().kind == Kind::ready);
  const std::array<Byte, 3> original{'a', 0, 'b'};
  struct Request { Service<Memory> &service; std::span<const Byte> bytes; std::uint64_t ticket = 0; } request{service, original};
  pthread_attr_t attributes;
  check(::pthread_attr_init(&attributes) == 0);
  check(::pthread_attr_setstacksize(&attributes, 192 * 1024) == 0);
  pthread_t thread;
  check(::pthread_create(&thread, &attributes, [](void *context) -> void * {
    auto &request = *static_cast<Request *>(context);
    request.ticket = request.service.intercept({.id = 17, .host = "fixture.test", .bytes = request.bytes});
    return nullptr;
  }, &request) == 0);
  check(::pthread_join(thread, nullptr) == 0);
  check(::pthread_attr_destroy(&attributes) == 0);
  const auto ticket = request.ticket;
  check(ticket != 0);
  for (;;) {
    const auto frame = receive(owner.get());
    const auto event = frame.event();
    if (event.kind != Kind::intercept_request) { continue; }
    const auto flow = FlowCodec::decode(event.bytes);
    check(flow.id == 17 && flow.ticket == ticket && std::ranges::equal(flow.bytes, original));
    break;
  }
  const std::array<Byte, 5> replacement{'c', 0, 'd', 'e', 'f'};
  send(InterceptionCodec::decision(output, ticket, Verdict::replace, replacement));
  FlowControl::Decision decision{Verdict::pending};
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
  while ((decision = service.poll(ticket, output)).verdict == Verdict::pending) {
    check(std::chrono::steady_clock::now() < deadline);
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }
  check(decision.verdict == Verdict::replace && decision.bytes == replacement.size());
  check(std::ranges::equal(std::span{output}.first(decision.bytes), replacement));
  auto second = traffic::connect(path);
  sendAll(second.get(), Protocol::greeting(output, Role::intercept));
  check(receive(second.get()).event().kind == Kind::ready);
  auto send_second = [&](std::span<const Byte> bytes) { sendAll(second.get(), Protocol::prefix(bytes.size())); sendAll(second.get(), bytes); };
  send_second(InterceptionCodec::rule(output, {.host = "fixture.test", .visibility = 3, .timeout_ms = 5000}));
  check(receive(second.get()).event().kind == Kind::ready);
  const auto pending = service.intercept({.id = 18, .host = "fixture.test", .bytes = original});
  check(pending != 0);
  send_second(InterceptionCodec::decision(output, pending, Verdict::reject));
  for (;;) {
    const auto frame = receive(owner.get());
    if (frame.event().kind == Kind::intercept_request) { break; }
  }
  check(service.poll(pending, output).verdict == Verdict::pending);
  send(InterceptionCodec::decision(output, pending, Verdict::replace, replacement));
  std::uint64_t second_ticket = 0;
  for (;;) {
    const auto frame = receive(second.get());
    if (frame.event().kind != Kind::intercept_request) { continue; }
    const auto flow = FlowCodec::decode(frame.event().bytes);
    check(flow.id == 18 && flow.ticket != pending && std::ranges::equal(flow.bytes, replacement));
    second_ticket = flow.ticket;
    break;
  }
  send(InterceptionCodec::decision(output, second_ticket, Verdict::reject));
  send_second(InterceptionCodec::decision(output, second_ticket, Verdict::allow));
  const auto composed_deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
  while ((decision = service.poll(pending, output)).verdict == Verdict::pending) {
    check(std::chrono::steady_clock::now() < composed_deadline);
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }
  check(decision.verdict == Verdict::replace && std::ranges::equal(std::span{output}.first(decision.bytes), replacement));
  second.reset();
  const auto abandoned = service.intercept({.id = 19, .host = "fixture.test", .bytes = original});
  owner.reset();
  while ((decision = service.poll(abandoned, output)).verdict == Verdict::pending) {
    check(std::chrono::steady_clock::now() < composed_deadline);
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }
  check(decision.verdict == Verdict::allow);
}

int main() {
  codecAndFilters();
  kernelLossAccounting();
  SystemAllocator system;
  BudgetAllocator budget{system, 64 * 1024 * 1024};
  SynchronizedAllocator memory{budget};
  std::array<char, 64> temporary{};
  std::strcpy(temporary.data(), "/tmp/telar-traffic-XXXXXX");
  check(::mkdtemp(temporary.data()) != nullptr);
  const auto directory = std::filesystem::canonical(temporary.data()).string();
  const auto path = directory + "/traffic.sock";
  {
    Service service{memory, path, true};
    offlineDelivery(system, path, directory);
    backpressureAndIsolation(path);
    exchangeDelivery(service, memory, path);
    interceptionDelivery(service, path);
  }
  check(budget.liveBytes() == 0);
  check(!std::filesystem::exists(path));
  std::filesystem::remove_all(directory);
  std::puts("Traffic tests passed");
}
