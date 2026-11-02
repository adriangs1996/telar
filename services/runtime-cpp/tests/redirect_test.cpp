#include "check.hpp"
#include "redirect/helper.hpp"
#include "redirect/ingress.hpp"
#include "proxy/service.hpp"
#include "tls_fixture.hpp"
#include "traffic/service.hpp"
#include "http2_fixture.hpp"
#include <filesystem>
#include <functional>
#include <mutex>

using namespace telar::runtime;
using telar::Byte;
namespace redir = telar::runtime::redirect;

template <typename Operation>
static void rejects(Operation operation) {
  bool rejected = false;
  try { operation(); } catch (const std::exception &) { rejected = true; }
  check(rejected);
}

template <typename Predicate>
static void await(Predicate predicate, std::source_location location = std::source_location::current()) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  while (!predicate()) {
    check(std::chrono::steady_clock::now() < deadline, location);
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }
}

static Byte acknowledgement(int socket) {
  pollfd descriptor{socket, POLLIN, 0};
  check(::poll(&descriptor, 1, 5000) > 0);
  Byte byte = 0;
  check(::recv(socket, &byte, 1, 0) == 1);
  return byte;
}

struct TcpPair {
  FileDescriptor client;
  FileDescriptor server;
  redir::Target target;

  explicit TcpPair(bool ipv6 = false) {
    const auto endpoint = redir::Target::parse(ipv6 ? "[::1]:1" : "127.0.0.1:1");
    redir::Listener listener{endpoint};
    target = listener.mapping().target;
    target.port = listener.mapping().listener_port;
    target.endpoint.setPort(target.port);
    client = openOriginSocket(target.endpoint.storage.ss_family);
    check(::connect(client.get(), target.endpoint.address(), target.endpoint.length) == 0 || errno == EINPROGRESS);
    await([&] { server = listener.accept(); return static_cast<bool>(server); });
    int failure = -1;
    socklen_t size = sizeof(failure);
    check(::getsockopt(client.get(), SOL_SOCKET, SO_ERROR, &failure, &size) == 0 && failure == 0);
  }
};

struct SameUser {
  static bool allows(uid_t uid) noexcept { return uid == ::geteuid(); }
};

static void transfer(int source, int destination, std::string_view text) {
  std::size_t sent = 0;
  std::string result;
  await([&] {
    if (sent != text.size()) {
      const auto count = ::send(source, text.data() + sent, text.size() - sent, 0);
      check(count >= 0 || socketWouldBlock(errno));
      if (count > 0) { sent += static_cast<std::size_t>(count); }
    }
    std::array<char, 16384> bytes;
    const auto count = ::recv(destination, bytes.data(), bytes.size(), 0);
    check(count >= 0 || socketWouldBlock(errno));
    if (count > 0) { result.append(bytes.data(), static_cast<std::size_t>(count)); }
    return result.size() == text.size();
  });
  check(result == text);
}

static void targetsAndRules(SystemAllocator &memory) {
  for (const auto value : {"example.com:443", "127.0.0.1:0", "127.0.0.1:65536", "::1:443", "[fe80::1]:443", "224.0.0.1:443", "[::]:443", "127.0.0.1:44\n3", "127.0.0.1;bad:443"}) {
    rejects([&] { redir::Target::parse(value); });
  }
  const std::array<redir::Mapping, 2> mappings{{{redir::Target::parse("192.0.2.1:443"), 53001}, {redir::Target::parse("[::1]:80"), 53002}}};
  redir::PfIdentity identity{memory, "/tmp/fixture.sock.redirect"};
  const std::array<redir::FlowKey, 2> flows{{{.source = redir::Target::parse("192.0.2.2:55001"), .destination = mappings[0].target}, {.source = redir::Target::parse("[2001:db8::2]:55002"), .destination = mappings[1].target}}};
  redir::PfScope scope{.uid = 501, .label = identity.label, .discovery_interface = "utun0", .flows = flows, .log_interface = 15};
  const auto rules = redir::pfRules(memory, mappings, scope);
  check(std::string_view{rules}.contains("rdr on lo0 inet6 proto tcp"));
  check(std::string_view{rules}.contains("route-to utun0 inet6"));
  check(std::string_view{rules}.contains("user 501 flags any no state"));
  check(std::string_view{rules}.contains("from 192.0.2.2 port 55001 to 192.0.2.1 port 443"));
  check(!std::string_view{rules}.contains("tagged"));
  check(std::string_view{rules}.contains("log (user, to pflog15)"));
  check(!std::string_view{rules}.contains("user 0"));
  redir::Bypass bypass{.key = {.source = redir::Target::parse("192.0.2.3:55003"), .destination = mappings[0].target}};
  bypass.route.interface.assign("en0");
  bypass.route.gateway.assign("192.0.2.254");
  scope.bypasses = std::span{&bypass, 1};
  scope.log_all = true;
  const auto scoped_rules = redir::pfRules(memory, mappings, scope);
  check(std::string_view{scoped_rules}.contains("route-to (en0 192.0.2.254) inet proto tcp from 192.0.2.3 port 55003"));
  check(!std::string_view{scoped_rules}.contains("rdr on lo0 inet proto tcp from 192.0.2.3"));
  redir::PfCommand command{memory};
  const std::array<std::string_view, 5> arguments{"-n", "-a", identity.anchor, "-f", "-"};
  command.run(arguments, rules);
  command.run(arguments, scoped_rules);
  bypass.route.interface.assign("en0;pass");
  rejects([&] { redir::pfRules(memory, mappings, scope); });
  scope.bypasses = {};
  auto incoming_mappings = mappings;
  incoming_mappings[0].incoming = true;
  const std::array incoming_flows{flows[0]};
  auto incoming_scope = scope;
  incoming_scope.direction = redir::Direction::inbound;
  incoming_scope.flows = {};
  incoming_scope.incoming_flows = incoming_flows;
  const auto incoming_rules = redir::pfRules(memory, incoming_mappings, incoming_scope);
  check(!std::string_view{incoming_rules}.contains("pass out"));
  check(std::string_view{incoming_rules}.contains("pass in log (user, to pflog15) quick on ! lo0 route-to utun0"));
  check(std::string_view{incoming_rules}.contains("pass in quick on ! lo0 route-to (lo0 127.0.0.1)"));
  check(std::string_view{incoming_rules}.contains("to 192.0.2.1 port 443 -> 192.0.2.1 port 53001"));
  check(std::string_view{incoming_rules}.contains("to 192.0.2.1 port 53001 flags S/SA keep state"));
  check(!std::string_view{incoming_rules}.contains("-> 127.0.0.1"));
  command.run(arguments, incoming_rules);
  const std::array<redir::Mapping, 1> incoming_v6{{{redir::Target::parse("[2001:db8::1]:443"), 53003, true}}};
  const std::array<redir::FlowKey, 1> incoming_v6_flow{{{.source = redir::Target::parse("[2001:db8::2]:55003"), .destination = incoming_v6[0].target}}};
  auto v6_scope = incoming_scope;
  v6_scope.incoming_flows = incoming_v6_flow;
  const auto v6_rules = redir::pfRules(memory, incoming_v6, v6_scope);
  check(std::string_view{v6_rules}.contains("to 2001:db8::1 port 443 -> 2001:db8::1 port 53003"));
  check(std::string_view{v6_rules}.contains("to 2001:db8::1 port 53003 flags S/SA keep state"));
  check(!std::string_view{v6_rules}.contains("-> ::1"));
  command.run(arguments, v6_rules);
  incoming_scope.direction = redir::Direction::both;
  incoming_scope.flows = flows;
  const auto both_rules = redir::pfRules(memory, incoming_mappings, incoming_scope);
  check(std::string_view{both_rules}.contains("pass out") && std::string_view{both_rules}.contains("pass in log"));
  command.run(arguments, both_rules);
  rejects([&] { redir::pfRules(memory, mappings, incoming_scope); });
  incoming_scope.direction = redir::Direction::outbound;
  rejects([&] { redir::pfRules(memory, incoming_mappings, incoming_scope); });
  scope.uid = 0;
  rejects([&] { redir::pfRules(memory, mappings, scope); });
  scope.uid = 501;
  scope.discovery_interface = "utun0\npass all";
  rejects([&] { redir::pfRules(memory, mappings, scope); });
}

static void incomingListeners() {
  auto target = redir::Target::parse("127.0.0.1:1");
  ifaddrs *raw = nullptr;
  check(::getifaddrs(&raw) == 0);
  const std::unique_ptr<ifaddrs, decltype(&freeifaddrs)> interfaces{raw, &freeifaddrs};
  for (const auto *entry = raw; entry; entry = entry->ifa_next) {
    if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET || !(entry->ifa_flags & IFF_UP) || (entry->ifa_flags & IFF_LOOPBACK)) { continue; }
    const auto &address = reinterpret_cast<const sockaddr_in &>(*entry->ifa_addr);
    const auto host = ntohl(address.sin_addr.s_addr);
    if (host == INADDR_ANY || host == INADDR_BROADCAST || IN_MULTICAST(host)) { continue; }
    std::array<char, INET_ADDRSTRLEN> text{};
    check(::inet_ntop(AF_INET, &address.sin_addr, text.data(), text.size()) != nullptr);
    target = redir::Target::parse(std::string{text.data()} + ":1");
    break;
  }
  for (const bool incoming : {false, true}) {
    redir::Listener listener{target, incoming};
    NetworkAddress bound = target.endpoint;
    socklen_t size = bound.length;
    check(::getsockname(listener.descriptor(), reinterpret_cast<sockaddr *>(&bound.storage), &size) == 0);
    std::array<char, INET_ADDRSTRLEN> host{};
    const auto &address = reinterpret_cast<const sockaddr_in &>(bound.storage);
    check(::inet_ntop(AF_INET, &address.sin_addr, host.data(), host.size()) != nullptr);
    const auto mapping = listener.mapping();
    check(mapping.incoming == incoming && mapping.listenerAddress() == host.data());
    check(mapping.listener_port == ntohs(address.sin_port) && mapping.listener_port != 0);
    check(std::string_view{host.data()} == (incoming ? target.host.view() : "127.0.0.1"));
    auto client = openOriginSocket(AF_INET);
    check(::connect(client.get(), bound.address(), bound.length) == 0 || errno == EINPROGRESS);
    FileDescriptor server;
    await([&] { server = listener.accept(); return static_cast<bool>(server); });
    constexpr char payload[] = "incoming listener\0binary";
    transfer(client.get(), server.get(), {payload, sizeof(payload) - 1});
  }
}

static void discoveredPackets() {
  for (const bool ipv6 : {false, true}) {
    const auto family = static_cast<std::uint32_t>(ipv6 ? AF_INET6 : AF_INET);
    const auto ip_size = ipv6 ? 40U : 20U;
    std::vector<Byte> frame(sizeof(family) + ip_size + 20);
    const auto encoded = htonl(family);
    std::memcpy(frame.data(), &encoded, sizeof(encoded));
    auto *ip = frame.data() + sizeof(family);
    if (ipv6) {
      ip[0] = 0x60;
      ip[5] = 20;
      ip[6] = IPPROTO_TCP;
      ip[23] = 1;
      ip[39] = 1;
    } else {
      ip[0] = 0x45;
      ip[3] = 40;
      ip[9] = IPPROTO_TCP;
      ip[12] = ip[16] = 127;
      ip[15] = ip[19] = 1;
    }
    auto *tcp = ip + ip_size;
    tcp[0] = 0xd6;
    tcp[1] = 0xd9;
    tcp[2] = 0x01;
    tcp[3] = 0xbb;
    tcp[12] = 0x50;
    tcp[13] = 0x02;
    const auto key = redir::FlowKey::syn(frame);
    check(key && key->source.port == 55001 && key->destination.port == 443);
    check(key->source.host.view() == (ipv6 ? "::1" : "127.0.0.1"));
    check(key->matches(*key));
    std::vector<Byte> logged(64 + frame.size() - sizeof(family));
    logged[0] = 61;
    logged[1] = static_cast<Byte>(family);
    logged[60] = 2;
    const uid_t owner = 501;
    std::memcpy(logged.data() + 44, &owner, sizeof(owner));
    std::memcpy(logged.data() + 4, "lo0", 4);
    const pid_t process = 12345;
    std::memcpy(logged.data() + 48, &process, sizeof(process));
    std::copy(frame.begin() + sizeof(family), frame.end(), logged.begin() + 64);
    std::array<Byte, 128> normalized{};
    const auto length = redir::PacketLog::normalize(logged, owner, normalized);
    check(length == frame.size() && std::equal(frame.begin(), frame.end(), normalized.begin()));
    redir::PacketLog::Metadata metadata;
    check(redir::PacketLog::normalize(logged, owner, normalized, &metadata) == frame.size());
    check(!metadata.incoming);
    check(redir::PacketLog::normalize(logged, owner, normalized, &metadata, redir::Direction::inbound) == 0);
    logged[60] = 1;
    check(redir::PacketLog::normalize(logged, owner, normalized, &metadata, redir::Direction::inbound) == frame.size() && metadata.incoming);
    check(redir::PacketLog::normalize(logged, owner, normalized, &metadata, redir::Direction::both) == frame.size());
    check(redir::PacketLog::normalize(logged, owner, normalized) == 0);
    logged[60] = 2;
    check(metadata.pid == process && metadata.interface.view() == "lo0" && metadata.interface_index == ::if_nametoindex("lo0"));
    check(redir::PacketLog::normalize(logged, 0, normalized) == 0);
    check(redir::PacketLog::normalize(std::span{logged}.first(63), owner, normalized) == 0);
    check(redir::PacketLog::normalize(logged, owner, std::span{normalized}.first(3)) == 0);
    logged[0] = 60;
    check(redir::PacketLog::normalize(logged, owner, normalized) == 0);
    for (std::size_t length = 0; length < frame.size(); ++length) {
      check(!redir::FlowKey::syn(std::span{frame}.first(length)));
    }
    tcp[13] = 0x12;
    check(!redir::FlowKey::syn(frame));
    tcp[13] = 0x02;
    tcp[12] = 0xf0;
    check(!redir::FlowKey::syn(frame));
    tcp[12] = 0x50;
    if (ipv6) {
      ip[6] = IPPROTO_FRAGMENT;
    } else {
      ip[6] = 0x20;
    }
    check(!redir::FlowKey::syn(frame));
  }
}

struct FakeState {
  std::optional<std::uint64_t> token;
  bool fail_clear = false;
  std::optional<std::uint64_t> load() { return token; }
  void save(std::uint64_t value) { token = value; }
  void clear() {
    if (fail_clear) { throw std::runtime_error{"injected record removal failure"}; }
    token.reset();
  }
};

struct FakeCommand {
  std::vector<std::vector<std::string>> calls;
  std::size_t fail_at = SIZE_MAX;
  bool hooks = true;

  std::string run(std::span<const std::string_view> arguments, std::string_view = {}) {
    std::vector<std::string> owned;
    for (const auto argument : arguments) { owned.emplace_back(argument); }
    calls.push_back(owned);
    if (calls.size() == fail_at) { throw std::runtime_error{"injected PF failure"}; }
    if (arguments.front() == "-sr") { return hooks ? "anchor \"com.apple/*\" all\n" : ""; }
    if (arguments.front() == "-sn") { return "rdr-anchor \"com.apple/*\" all\n"; }
    if (arguments.front() == "-E") { return "pf enabled\nToken : 12345\n"; }
    const bool syntax = arguments.size() == 5 && arguments[0] == "-n" && arguments[1] == "-a" && arguments[3] == "-f" && arguments[4] == "-";
    const bool load = arguments.size() == 4 && arguments[0] == "-a" && arguments[2] == "-f" && arguments[3] == "-";
    const bool flush = arguments.size() == 4 && arguments[0] == "-a" && arguments[2] == "-F" && (arguments[3] == "rules" || arguments[3] == "nat");
    const bool release = arguments.size() == 2 && arguments[0] == "-X" && arguments[1] == "12345";
    check(syntax || load || flush || release);
    return {};
  }
};

struct FakeLoopback {
  std::size_t owners = 0;
  bool fail_acquire = false;
  bool fail_release = false;
  void acquire() {
    ++owners;
    if (fail_acquire) { throw std::runtime_error{"injected loopback activation failure"}; }
  }
  void release() {
    if (fail_release) { throw std::runtime_error{"injected loopback cleanup failure"}; }
    owners = 0;
  }
};

static void lifecycle(SystemAllocator &memory) {
  redir::PfIdentity identity{memory, "/tmp/fixture.sock.redirect"};
  FakeLoopback loopback;
  for (std::size_t failure = 1; failure <= 5; ++failure) {
    FakeCommand command;
    command.fail_at = failure;
    FakeState state;
    {
      redir::PfSession session{command, state, identity, loopback};
      rejects([&] { session.start("fixture rules"); });
    }
    check(!state.token);
    for (const auto &call : command.calls) {
      check(std::ranges::find(call, "all") == call.end() && std::ranges::find(call, "states") == call.end());
    }
  }
  FakeCommand command;
  FakeState state{12345};
  {
    redir::PfSession session{command, state, identity, loopback};
    session.recover();
    check(!state.token);
    check(command.calls.size() == 3 && command.calls.back() == std::vector<std::string>{"-X", "12345"});
    session.start("fixture rules");
    check(state.token == 12345);
    check(loopback.owners == 1);
  }
  check(!state.token);
  check(loopback.owners == 0);
  command.hooks = false;
  redir::PfSession session{command, state, identity, loopback};
  rejects([&] { session.start("fixture rules"); });
  check(!state.token);
  for (const auto output : {"", "Token : 0\n", "Token : -1\n", "Token : 12garbage\n"}) {
    rejects([&] { decltype(session)::parseToken(output); });
  }
  for (std::size_t failure = 1; failure <= 3; ++failure) {
    FakeCommand cleanup;
    cleanup.fail_at = failure;
    FakeState recorded{12345};
    redir::PfSession recovery{cleanup, recorded, identity, loopback};
    rejects([&] { recovery.recover(); });
    check(recorded.token == 12345);
    check(cleanup.calls[0] == std::vector<std::string>{"-a", std::string{identity.anchor}, "-F", "rules"});
    check(cleanup.calls[1] == std::vector<std::string>{"-a", std::string{identity.anchor}, "-F", "nat"});
    check(cleanup.calls.size() == (failure < 3 ? 2 : 3));
    cleanup.fail_at = SIZE_MAX;
    recovery.stop();
    check(!recorded.token);
    const auto count = cleanup.calls.size();
    recovery.stop();
    check(cleanup.calls.size() == count);
  }
  FakeCommand activation;
  FakeState recorded;
  loopback.fail_acquire = true;
  {
    redir::PfSession rollback{activation, recorded, identity, loopback};
    rejects([&] { rollback.start("fixture rules"); });
  }
  check(!recorded.token && loopback.owners == 0);
  loopback.fail_acquire = false;
  loopback.fail_release = true;
  recorded.token = 12345;
  redir::PfSession recovery{activation, recorded, identity, loopback};
  const auto before = activation.calls.size();
  rejects([&] { recovery.recover(); });
  check(recorded.token == 12345 && activation.calls.size() == before + 2);
  loopback.fail_release = false;
  recovery.stop();
  check(!recorded.token);
  FakeState removed_reference{12345, true};
  FakeCommand finalization;
  {
    redir::PfSession closing{finalization, removed_reference, identity, loopback};
    rejects([&] { closing.recover(); });
    check(removed_reference.token == 0);
    removed_reference.fail_clear = false;
  }
  check(!removed_reference.token);
  check(std::ranges::count_if(finalization.calls, [](const auto &call) { return call.front() == "-X"; }) == 1);
}

struct LeaseStore {
  std::optional<std::string> content;
  bool fail_save = false;
  bool fail_clear = false;
  std::optional<std::string> load() { return content; }
  void save(std::string_view value) {
    if (fail_save) { throw std::runtime_error{"injected lease write failure"}; }
    content = value;
  }
  void clear() {
    if (fail_clear) { throw std::runtime_error{"injected lease removal failure"}; }
    content.reset();
  }
};

struct FakeInterface {
  bool skip = true;
  bool fail = false;
  std::vector<bool> changes;
  bool skipped() const noexcept { return skip; }
  void setSkipped(bool value) {
    if (fail) { throw std::runtime_error{"injected loopback ioctl failure"}; }
    skip = value;
    changes.push_back(value);
  }
};

static void loopbackLeases(SystemAllocator &memory) {
  using Parser = redir::PfLoopback<FakeCommand>;
  check(Parser::parse("No ALTQ support in kernel\nlo0 (skip)\n"));
  check(!Parser::parse("lo0\nALTQ related functions disabled\n"));
  rejects([] { Parser::parse("lo01 (skip)\n"); });
  rejects([] { Parser::parse("lo0 (unknown)\n"); });
  constexpr std::string_view first = "tlr_0000000000000001";
  constexpr std::string_view second = "tlr_0000000000000002";
  for (const bool originally_skipped : {false, true}) {
    LeaseStore store;
    FakeInterface interface{.skip = originally_skipped, .fail = false, .changes = {}};
    redir::LoopbackLeases leases{memory};
    leases.acquire(store, interface, first);
    check(!interface.skip && store.content.has_value());
    leases.acquire(store, interface, first);
    leases.acquire(store, interface, second);
    leases.release(store, interface, first);
    check(!interface.skip && store.content.has_value());
    // A fresh object represents recovery in another helper after a crash.
    redir::LoopbackLeases recovered{memory};
    recovered.release(store, interface, second);
    check(interface.skip == originally_skipped && !store.content);
    const auto count = interface.changes.size();
    recovered.release(store, interface, second);
    check(interface.changes.size() == count);
  }
  for (const auto malformed : {"", "skip\n", "skip\nbad\n", "filter\ntlr_0000000000000001\ntlr_0000000000000001\n"}) {
    LeaseStore store{std::string{malformed}};
    FakeInterface interface;
    redir::LoopbackLeases leases{memory};
    rejects([&] { leases.acquire(store, interface, first); });
    check(interface.skip && interface.changes.empty());
  }
  LeaseStore store;
  FakeInterface interface;
  redir::LoopbackLeases leases{memory};
  store.fail_save = true;
  rejects([&] { leases.acquire(store, interface, first); });
  check(!store.content && interface.skip);
  store.fail_save = false;
  interface.fail = true;
  rejects([&] { leases.acquire(store, interface, first); });
  check(store.content && interface.skip);
  interface.fail = false;
  leases.release(store, interface, first);
  check(!store.content && interface.skip);
  leases.acquire(store, interface, first);
  interface.fail = true;
  rejects([&] { leases.release(store, interface, first); });
  check(store.content && !interface.skip);
  interface.fail = false;
  store.fail_clear = true;
  rejects([&] { leases.release(store, interface, first); });
  check(store.content && interface.skip);
  store.fail_clear = false;
  leases.release(store, interface, first);
  check(!store.content && interface.skip);
}

static void relay(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library, const std::string &path) {
  AuthorityDirectory directory;
  const auto authority = CertificateAuthority<TlsTestMemory>::loadOrCreate(memory, library, directory.descriptor.get(), AuthorityKind::private_local);
  TlsTrustStore trust{memory, library};
  TlsContexts contexts{memory, library, trust};
  TlsInterception interception{contexts, authority};
  ProxyOptions options{memory};
  options.transparent_tls = true;
  check(options.intercept_hosts.append("*"));
  options.intercept_hosts.finish();
  const auto secret = ProxySecret::generate();
  ProxyService<TlsTestMemory, Kqueue, SystemNameResolver> service{memory, options, secret, interception, ProxyListener::bind(std::nullopt, {})};
  {
    redir::Ingress<decltype(service), SameUser> ingress{path, service};
    auto monitor = traffic::connect(path);
    std::array<Byte, redir::Protocol::frame_bytes> greeting{};
    traffic::sendAll(monitor.get(), redir::Protocol::encode(greeting, redir::Kind::monitor, {}));
    pollfd ready{monitor.get(), POLLIN, 0};
    check(::poll(&ready, 1, 5000) > 0);
    std::array<Byte, sizeof(std::uint32_t)> reply{};
    check(::recv(monitor.get(), reply.data(), reply.size(), MSG_WAITALL) == static_cast<ssize_t>(reply.size()));
    plugins::FrameReader identity{reply};
    check(identity.integer<std::uint32_t>() == ::geteuid());
    check(::poll(&ready, 1, 0) == 0);
    for (const bool ipv6 : {false, true}) {
      TcpPair downstream{ipv6};
      TcpPair upstream{ipv6};
      redir::Connection connection{.child = std::move(downstream.server), .origin = std::move(upstream.client), .target = upstream.target};
      auto channel = traffic::connect(path);
      redir::Protocol::send(channel.get(), connection);
      check(acknowledgement(channel.get()) == 1);
      Byte lifetime_probe;
      check(::recv(channel.get(), &lifetime_probe, 1, MSG_PEEK | MSG_DONTWAIT) < 0 && socketWouldBlock(errno));
      connection.child.reset();
      connection.origin.reset();
      transfer(upstream.server.get(), downstream.client.get(), "server-first banner\r\n");
      std::string payload(256 * 1024, '\0');
      for (std::size_t index = 0; index < payload.size(); ++index) { payload[index] = static_cast<char>(index * 37); }
      transfer(downstream.client.get(), upstream.server.get(), payload);
      check(::shutdown(downstream.client.get(), SHUT_WR) == 0);
      await([&] { Byte byte; const auto n = ::recv(upstream.server.get(), &byte, 1, 0); return n == 0; });
      transfer(upstream.server.get(), downstream.client.get(), "response after half-close");
      check(::shutdown(upstream.server.get(), SHUT_WR) == 0);
      await([&] { return service.active() == 0; });
      await([&] { return ::recv(channel.get(), &lifetime_probe, 1, MSG_PEEK | MSG_DONTWAIT) == 0; });
    }
    TcpPair downstream;
    TcpPair upstream;
    auto wrong_target = upstream.target;
    wrong_target.port = wrong_target.port == UINT16_MAX ? wrong_target.port - 1 : wrong_target.port + 1;
    wrong_target.endpoint.setPort(wrong_target.port);
    redir::Connection invalid{.child = std::move(downstream.server), .origin = std::move(upstream.client), .target = wrong_target};
    auto channel = traffic::connect(path);
    redir::Protocol::send(channel.get(), invalid);
    ready = {channel.get(), POLLIN, 0};
    check(::poll(&ready, 1, 5000) > 0);
    Byte byte;
    check(::recv(channel.get(), &byte, 1, 0) == 0);
    check(service.active() == 0);
  }
  check(!service.failed() && service.counters().read(ProxyCounter::passthrough_connection) == 2);
  check(service.counters().read(ProxyCounter::tls_context_failure) == 0);
  if (::geteuid() != 0) {
    redir::Ingress production{path, service};
    auto unauthorized = traffic::connect(path);
    pollfd pending{unauthorized.get(), POLLIN, 0};
    check(::poll(&pending, 1, 5000) > 0);
    Byte byte;
    check(::recv(unauthorized.get(), &byte, 1, 0) == 0);
  }
}

static void opaqueTls(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library) {
  AuthorityDirectory directory;
  const auto authority = CertificateAuthority<TlsTestMemory>::loadOrCreate(memory, library, directory.descriptor.get(), AuthorityKind::private_local);
  TlsTrustStore trust{memory, library};
  TlsContexts contexts{memory, library, trust};
  TlsInterception interception{contexts, authority};
  ProxyOptions options{memory};
  check(options.intercept_hosts.append("*"));
  options.intercept_hosts.finish();
  const auto secret = ProxySecret::generate();
  ProxyService<TlsTestMemory, Kqueue, SystemNameResolver> service{memory, options, secret, interception, ProxyListener::bind(std::nullopt, {})};
  TcpPair downstream;
  TcpPair upstream;
  check(service.adopt({.child = std::move(downstream.server), .origin = std::move(upstream.client), .target = upstream.target}));
  auto issuer = CertificatePair::authority("Transparent origin", CertificatePair::private_lifetime);
  auto leaf = issuer.mint("origin.test");
  TlsContext server_context{SSL_CTX_new(TLS_server_method())};
  TlsContext client_context{SSL_CTX_new(TLS_client_method())};
  check(server_context && client_context);
  check(SSL_CTX_use_certificate(server_context.get(), leaf.certificate.get()) == 1);
  check(SSL_CTX_use_PrivateKey(server_context.get(), leaf.key.get()) == 1);
  check(SSL_CTX_add1_chain_cert(server_context.get(), issuer.certificate.get()) == 1);
  check(X509_STORE_add_cert(SSL_CTX_get_cert_store(client_context.get()), issuer.certificate.get()) == 1);
  SSL_CTX_set_verify(client_context.get(), SSL_VERIFY_PEER, nullptr);
  auto client = createTlsPeer(client_context.get(), downstream.client.get(), false);
  auto server = createTlsPeer(server_context.get(), upstream.server.get(), true);
  check(SSL_set1_host(client.get(), "origin.test") == 1);
  bool client_ready = false;
  bool server_ready = false;
  bool failed = false;
  await([&] {
    if (!client_ready) { client_ready = advanceTlsPeer(client.get(), failed); check(!failed); }
    if (!server_ready) { server_ready = advanceTlsPeer(server.get(), failed); check(!failed); }
    return client_ready && server_ready;
  });
  check(X509_cmp(SSL_get0_peer_certificate(client.get()), leaf.certificate.get()) == 0);
  check(service.counters().read(ProxyCounter::passthrough_connection) == 1);
}

class TlsFlowObserver : public traffic::FlowControl {
public:
  struct Snapshot {
    std::size_t wire = 0;
    std::size_t plaintext = 0;
    unsigned errors = 0;
    std::string error;
    std::string closed;
  };

  void observeFlow(traffic::Kind kind, const traffic::FlowEvent &event) noexcept override {
    std::lock_guard lock{mutex_};
    if (kind == traffic::Kind::stream_data) {
      (event.visibility == traffic::Visibility::plaintext ? seen_.plaintext : seen_.wire) += event.bytes.size();
    } else if (kind == traffic::Kind::flow_error) {
      ++seen_.errors;
      seen_.error = event.reason;
    } else if (kind == traffic::Kind::flow_close) { seen_.closed = event.reason; }
  }

  Snapshot snapshot() {
    std::lock_guard lock{mutex_};
    return seen_;
  }

  std::uint64_t intercept(const traffic::FlowEvent &) noexcept override { return 0; }
  Decision poll(std::uint64_t, std::span<Byte>) noexcept override { return {traffic::Verdict::reject}; }
  void cancel(std::uint64_t) noexcept override {}
  std::optional<Time> deadline(std::uint64_t) noexcept override { return std::nullopt; }
  int descriptor() const noexcept override { return signal_.descriptor(); }
  void drain() noexcept override { signal_.drain(); }

private:
  CompletionSignal signal_;
  std::mutex mutex_;
  Snapshot seen_;
};

class TlsHttpOwner final : public TlsFlowObserver, public traffic::HttpControl {
public:
  explicit TlsHttpOwner(TlsTestMemory &memory) : reply_(memory, HttpMessageLimits::message_bytes) {}
  traffic::HttpControl *http() noexcept override { return this; }
  traffic::HttpPolicy policy(const traffic::FlowEvent &) noexcept override { return {true, true}; }
  std::uint64_t interceptHttp(const traffic::FlowEvent &event) noexcept override {
    check(event.visibility == traffic::Visibility::plaintext);
    auto message = HttpMessageCodec::decode(event.bytes);
    if (message.response) {
      static constexpr std::array<Byte, 10> body{'t', 'l', 's', 0, 'e', 'd', 'i', 't', 'e', 'd'};
      message.body = body;
      message.status = 202;
      message.reason = "Edited";
    } else { message.target = "/edited-tls"; }
    size_ = HttpMessageCodec::encode(reply_.bytes(), message).size();
    return calls.fetch_add(1, std::memory_order_relaxed) + 1;
  }
  Decision pollHttp(std::uint64_t, std::span<Byte> output) noexcept override {
    check(size_ <= output.size());
    std::ranges::copy(reply_.bytes().first(size_), output.begin());
    return {traffic::Verdict::replace, size_};
  }
  void cancelHttp(std::uint64_t) noexcept override {}
  std::optional<Time> httpDeadline(std::uint64_t) noexcept override { return std::chrono::steady_clock::now() + std::chrono::seconds{5}; }
  void httpUnavailable(const traffic::FlowEvent &) noexcept override { check(false); }
  std::atomic<unsigned> calls{0};

private:
  SensitiveAllocation<TlsTestMemory> reply_;
  std::size_t size_ = 0;
};

enum class TransparentTlsMode { intercept, pinned, excluded_pinned, suspended };

struct TransparentTlsCase {
  bool trusted_origin = true;
  bool http = true;
  bool numeric_ipv6 = false;
  bool edit = false;
  bool http2 = false;
  TransparentTlsMode mode = TransparentTlsMode::intercept;
};

static void exchangeHttp2Tls(TlsTestMemory &memory, SSL *client, SSL *server) {
  const std::array<std::pair<std::string_view, std::string_view>, 4> headers{{{":method", "GET"}, {":scheme", "https"}, {":authority", "origin.test"}, {":path", "/transparent"}}};
  constexpr auto end = static_cast<std::uint8_t>(Http2Flag::end_stream);
  constexpr auto complete_headers = end | static_cast<std::uint8_t>(Http2Flag::end_headers);
  const auto request = std::string{Http2DirectionObserver<TlsTestMemory>::client_preface} + http2Frame(Http2FrameKind::settings, 0, 0, {}) + http2Frame(Http2FrameKind::headers, complete_headers, 1, hpackFields(headers));
  const auto settings = http2Frame(Http2FrameKind::settings, 0, 0, {});
  std::size_t sent = 0;
  await([&] { return SSL_write_ex(server, settings.data(), settings.size(), &sent) == 1; });
  await([&] { return SSL_write_ex(client, request.data(), request.size(), &sent) == 1; });
  struct Sink {
    std::string path, status, body;
    bool ended = false;
    void emit(const Http2Event &event) noexcept {
      if (event.name == ":path") { path = event.value; }
      if (event.name == ":status") { status = event.value; }
      if (!event.bytes.empty()) { body.append(reinterpret_cast<const char *>(event.bytes.data()), event.bytes.size()); }
      ended |= event.kind == Http2Event::Kind::request_finished || event.kind == Http2Event::Kind::response_ended;
    }
  } request_sink, response_sink;
  Http2DirectionObserver request_observer{memory, Http2Direction::request};
  Http2DirectionObserver response_observer{memory, Http2Direction::response};
  std::array<std::uint8_t, 4096> bytes;
  std::size_t received = 0;
  await([&] {
    if (SSL_read_ex(server, bytes.data(), bytes.size(), &received) == 1) { request_observer.observe(std::span{bytes}.first(received), request_sink); }
    return request_sink.ended;
  });
  check(request_sink.path == "/edited-tls");
  const std::array<std::pair<std::string_view, std::string_view>, 1> response_headers{{{":status", "200"}}};
  const auto response = http2Frame(Http2FrameKind::headers, static_cast<std::uint8_t>(Http2Flag::end_headers), 1, hpackFields(response_headers)) + http2Frame(Http2FrameKind::data, end, 1, "yes");
  await([&] { return SSL_write_ex(server, response.data(), response.size(), &sent) == 1; });
  await([&] {
    if (SSL_read_ex(client, bytes.data(), bytes.size(), &received) == 1) { response_observer.observe(std::span{bytes}.first(received), response_sink); }
    return response_sink.ended;
  });
  check(response_sink.status == "202" && response_sink.body == std::string("tls\0edited", 10));
}

static void transparentTls(TlsTestMemory &memory, const TlsLibrary<TlsTestMemory> &library, TransparentTlsCase scenario = {}) {
  const auto [trusted_origin, http, numeric_ipv6, edit, http2, mode] = scenario;
  const bool excluded = mode == TransparentTlsMode::excluded_pinned;
  AuthorityDirectory directory;
  const auto authority = CertificateAuthority<TlsTestMemory>::loadOrCreate(memory, library, directory.descriptor.get(), AuthorityKind::private_local);
  auto issuer = CertificatePair::authority("Transparent origin", CertificatePair::private_lifetime);
  const auto hostname = numeric_ipv6 ? "::1" : "origin.test";
  auto leaf = issuer.mint(hostname);
  TlsTrustStore trust{memory, library};
  if (trusted_origin) { trust.add(issuer.certificate.get()); }
  TlsContexts contexts{memory, library, trust};
  TlsInterception interception{contexts, authority};
  if (mode == TransparentTlsMode::suspended) { interception.suspend(true); }
  ProxyOptions options{memory};
  options.transparent_tls = true;
  check(options.intercept_hosts.append(excluded ? "selected.other.test" : hostname));
  options.intercept_hosts.finish();
  const auto secret = ProxySecret::generate();
  std::optional<TlsHttpOwner> owner;
  TlsFlowObserver observer;
  if (edit) { owner.emplace(memory); }
  auto &flows = owner ? static_cast<TlsFlowObserver &>(*owner) : observer;
  ProxyService<TlsTestMemory, Kqueue, SystemNameResolver> service{memory, options, secret, interception, ProxyListener::bind(std::nullopt, {}), &flows};
  TcpPair downstream{numeric_ipv6};
  TcpPair upstream{numeric_ipv6};
  check(service.adopt({.child = std::move(downstream.server), .origin = std::move(upstream.client), .target = upstream.target}));
  TlsContext server_context{SSL_CTX_new(TLS_server_method())};
  TlsContext client_context{SSL_CTX_new(TLS_client_method())};
  check(SSL_CTX_use_certificate(server_context.get(), leaf.certificate.get()) == 1);
  check(SSL_CTX_use_PrivateKey(server_context.get(), leaf.key.get()) == 1);
  check(SSL_CTX_add1_chain_cert(server_context.get(), issuer.certificate.get()) == 1);
  check(X509_STORE_add_cert(SSL_CTX_get_cert_store(client_context.get()), excluded ? issuer.certificate.get() : authority.certificate()) == 1);
  SSL_CTX_set_verify(client_context.get(), SSL_VERIFY_PEER, nullptr);
  AlpnSelection selection;
  if (http2) {
    constexpr std::array<unsigned char, 2> name{'h', '2'};
    check(selection.assign(name));
    SSL_CTX_set_alpn_select_cb(server_context.get(), &AlpnSelection::select, nullptr);
  }
  auto client = createTlsPeer(client_context.get(), downstream.client.get(), false);
  auto server = createTlsPeer(server_context.get(), upstream.server.get(), true);
  TlsPin pin{leaf.key.get()};
  if (mode == TransparentTlsMode::pinned || excluded) {
    SSL_set_app_data(client.get(), &pin);
    SSL_set_verify(client.get(), SSL_VERIFY_PEER, &verifyTlsPin);
  }
  if (http2) {
    SSL_set_app_data(server.get(), &selection);
    constexpr std::array<unsigned char, 3> offer{2, 'h', '2'};
    check(SSL_set_alpn_protos(client.get(), offer.data(), offer.size()) == 0);
  }
  if (numeric_ipv6) {
    check(X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(client.get()), hostname) == 1);
  } else {
    check(SSL_set_tlsext_host_name(client.get(), hostname) == 1);
    check(SSL_set1_host(client.get(), hostname) == 1);
  }
  bool client_ready = false, server_ready = false, failed = false;
  const bool rejected = !trusted_origin || mode == TransparentTlsMode::pinned || mode == TransparentTlsMode::suspended;
  await([&] {
    if (!client_ready && !failed) { client_ready = advanceTlsPeer(client.get(), failed); }
    if (!server_ready) { bool upstream_failed = false; server_ready = advanceTlsPeer(server.get(), upstream_failed); }
    return rejected ? service.active() == 0 && flows.snapshot().errors != 0 : client_ready && server_ready;
  });
  if (rejected) {
    check(!client_ready);
    const auto seen = flows.snapshot();
    const auto counter = !trusted_origin ? ProxyCounter::tls_upstream_handshake_failure : mode == TransparentTlsMode::pinned ? ProxyCounter::tls_downstream_handshake_failure : ProxyCounter::tls_context_failure;
    const auto reason = !trusted_origin ? "tls_origin_handshake_failed" : mode == TransparentTlsMode::pinned ? "tls_client_handshake_failed" : "tls_context_failed";
    check(service.counters().read(counter) == 1);
    check(service.counters().read(ProxyCounter::passthrough_connection) == 0);
    check(seen.wire == 0 && seen.plaintext == 0 && seen.errors == 1 && seen.error == reason && seen.closed == reason);
    if (mode == TransparentTlsMode::pinned) {
      check(failed && pin.checked && !pin.matched && SSL_get_verify_result(client.get()) == X509_V_ERR_APPLICATION_VERIFICATION);
    }
    return;
  }
  check(!failed && SSL_get_verify_result(client.get()) == X509_V_OK);
  if (excluded) {
    check(pin.checked && pin.matched && X509_cmp(SSL_get0_peer_certificate(client.get()), leaf.certificate.get()) == 0);
    check(service.counters().read(ProxyCounter::passthrough_connection) == 1);
  } else {
    check(X509_cmp(SSL_get0_peer_certificate(client.get()), leaf.certificate.get()) != 0);
    check(X509_check_issued(authority.certificate(), SSL_get0_peer_certificate(client.get())) == X509_V_OK);
  }
  if (http2) {
    exchangeHttp2Tls(memory, client.get(), server.get());
    check(owner && owner->calls.load() == 2);
    return;
  }
  const std::string_view request = http ? "GET /transparent HTTP/1.1\r\nHost: origin.test\r\n\r\n" : std::string_view{"custom\0protocol", 15};
  std::size_t sent = 0;
  await([&] { return SSL_write_ex(client.get(), request.data(), request.size(), &sent) == 1; });
  std::array<char, 1024> bytes;
  std::size_t received = 0;
  await([&] { return SSL_read_ex(server.get(), bytes.data(), bytes.size(), &received) == 1; });
  if (edit) { check(std::string_view{bytes.data(), received}.starts_with("GET /edited-tls HTTP/1.1\r\n")); }
  else { check(std::string_view{bytes.data(), received} == request); }
  const std::string_view response = http ? "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nyes" : std::string_view{"binary\0response", 15};
  await([&] { return SSL_write_ex(server.get(), response.data(), response.size(), &sent) == 1; });
  std::string result;
  const auto expected = edit ? std::string{"HTTP/1.1 202 Edited\r\nContent-Length: 10\r\n\r\n"} + std::string{"tls\0edited", 10} : std::string{response};
  await([&] {
    if (SSL_read_ex(client.get(), bytes.data(), bytes.size(), &received) == 1) { result.append(bytes.data(), received); }
    return result.size() == expected.size();
  });
  check(result == expected);
  const auto seen = flows.snapshot();
  if (excluded) { check(seen.wire != 0 && seen.plaintext == 0 && seen.errors == 0); }
  else { check(seen.plaintext != 0 && seen.wire == 0 && seen.errors == 0); }
  if (owner) { check(owner->calls.load() == 2); }
}

int main() {
  SystemAllocator system;
  targetsAndRules(system);
  incomingListeners();
  discoveredPackets();
  lifecycle(system);
  loopbackLeases(system);
  BudgetAllocator budget{system, 64 * 1024 * 1024};
  TlsTestMemory memory{budget};
  std::array<char, 64> temporary{};
  std::strcpy(temporary.data(), "/tmp/telar-redirect-XXXXXX");
  check(::mkdtemp(temporary.data()) != nullptr);
  const auto root = std::filesystem::canonical(temporary.data()).string();
  {
    TlsLibrary library{memory};
    relay(memory, library, root + "/ingress.sock");
    opaqueTls(memory, library);
    transparentTls(memory, library);
    transparentTls(memory, library, {.trusted_origin = false});
    transparentTls(memory, library, {.http = false});
    transparentTls(memory, library, {.numeric_ipv6 = true});
    transparentTls(memory, library, {.edit = true});
    transparentTls(memory, library, {.edit = true, .http2 = true});
    transparentTls(memory, library, {.mode = TransparentTlsMode::pinned});
    transparentTls(memory, library, {.mode = TransparentTlsMode::excluded_pinned});
    transparentTls(memory, library, {.mode = TransparentTlsMode::suspended});
  }
  check(budget.liveBytes() == 0);
  std::filesystem::remove_all(root);
  std::puts("Transparent redirect tests passed");
}
