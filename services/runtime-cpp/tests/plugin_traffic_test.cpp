#include "check.hpp"
#include "plugins/host.hpp"
#include "telar_platform/temporary_directory.hpp"
#include "traffic/connection.hpp"
#include "traffic/datagram.hpp"
#include "traffic/service.hpp"
#include <fstream>

using namespace telar::runtime;
using telar::Byte;
namespace app = telar::runtime::plugins;

static app::ServiceSpec specification(bool intercept) {
  app::ServiceSpec specification;
  specification.plugin_id = 11;
  specification.generation = 7;
  specification.name.assign("traffic-fixture");
  specification.declared.insert(app::Capability::traffic_observe);
  specification.granted.insert(app::Capability::traffic_observe);
  if (intercept) {
    specification.declared.insert(app::Capability::traffic_intercept);
    specification.granted.insert(app::Capability::traffic_intercept);
  }
  specification.digest.fill(0x5a);
  return specification;
}

static void write(const std::string &path, std::string_view source) {
  std::ofstream file{path};
  file << source;
  check(file.good());
}

static void host() {
  SystemAllocator system;
  BudgetAllocator memory{system, 80 * 1024 * 1024};
  TemporaryDirectory directory{"/tmp/tlr-app-host.XXXXXX"};
  const auto entry = std::string{directory.path()} + "/main.lua";
  write(entry, R"lua(
local traffic = require('telar.traffic')
assert(io == nil and os == nil and debug == nil)
local stop
stop = traffic.subscribe({events={packet=true},filter='udp port 53535'}, function(err, event)
  assert(not err, err)
  assert(event.kind == 'packet' and event.bytes == 'a\0b')
  assert(event.app.id == 'traffic-fixture' and event.app.generation == '7')
  stop()
  return {telar.effect.notification{title='packet verified'}}
end)
traffic.intercept({stage='http',host='example.test'},function(err,event)
  assert(not err, err)
  assert(event.message.body == 'original\0body' and event.message.body_decoded)
  assert(event.message.protocol == 'http11' or (event.message.protocol == 'h2' and event.message.stream_id == 7 and event.message.authority == 'example.test'))
  assert(event.ticket == '123' and event.flow_id == '31')
  assert(event.respond({action='replace',target='/edited',body=event.message.body..'\0suffix',headers={{name='x-key',value='one'},{name='x-key',value='two'}}}))
  assert(not event.respond({action='reject'}))
end)
return {}
)lua");
  {
    const auto identity = specification(true);
    app::Host host{memory, entry.c_str(), &identity};
    SensitiveAllocation output{memory, app::TrafficLimits::reply_bytes};
    auto setup = makeOwned<app::TrafficReply>(memory);
    app::TrafficProtocol::readReply(host.trafficSetup(output.bytes()), *setup);
    check(setup->changed && setup->registration_count == 2);
    check(setup->registrations[0].filter.view() == "udp port 53535" && setup->registrations[1].stage == app::TrafficStage::http);
    constexpr std::string_view bytes{"a\0b", 3};
    app::TrafficEvent packet{.event_id = 1, .registration = setup->registrations[0].id, .dropped = 0, .event = {.kind = traffic::Kind::packet, .original_bytes = 3, .bytes = {reinterpret_cast<const Byte *>(bytes.data()), bytes.size()}}};
    const auto response = host.invokeTraffic(packet, output.bytes());
    app::TrafficProtocol::readReply(response, *setup);
    check(setup->changed && setup->registration_count == 1 && setup->decision_count == 0);
    check(app::Protocol::decodeEffects(setup->effects).batch.notifications[0].title == "packet verified");

    constexpr std::string_view body{"original\0body", 13};
    HttpMessageView message{.method = "POST", .target = "/", .body = {reinterpret_cast<const Byte *>(body.data()), body.size()}};
    SensitiveAllocation encoded_message{memory, HttpMessageLimits::message_bytes};
    SensitiveAllocation encoded_flow{memory, HttpMessageLimits::message_bytes + traffic::Limits::metadata_bytes};
    const auto payload = HttpMessageCodec::encode(encoded_message.bytes(), message);
    const auto flow = traffic::FlowCodec::encode(encoded_flow.bytes(), {.id = 31, .ticket = 123, .host = "example.test", .bytes = payload});
    app::TrafficEvent request{.event_id = 2, .registration = setup->registrations[0].id, .dropped = 0, .event = {.kind = traffic::Kind::http_intercept_request, .bytes = flow}};
    app::TrafficProtocol::readReply(host.invokeTraffic(request, output.bytes()), *setup);
    check(!setup->changed && setup->decision_count == 1);
    app::FrameReader decision{setup->decisions[0].payload};
    decision.require(traffic::InterceptionCodec::Command::decision);
    check(decision.integer<std::uint64_t>() == 123 && decision.tag(traffic::Verdict::reject) == traffic::Verdict::replace);
    const auto edited = HttpMessageCodec::decode(decision.bytes());
    decision.finish();
    check(edited.target == "/edited" && edited.header_count == 2 && edited.headers[1].value == "two");
    check(std::string_view{reinterpret_cast<const char *>(edited.body.data()), edited.body.size()} == std::string_view{"original\0body\0suffix", 20});
    message.version = HttpVersion::http2;
    message.stream = 7;
    message.scheme = "https";
    message.authority = "example.test";
    const auto h2_payload = HttpMessageCodec::encode(encoded_message.bytes(), message);
    request.event_id = 3;
    request.event.bytes = traffic::FlowCodec::encode(encoded_flow.bytes(), {.id = 31, .ticket = 123, .host = "example.test", .bytes = h2_payload});
    app::TrafficProtocol::readReply(host.invokeTraffic(request, output.bytes()), *setup);
    check(setup->decision_count == 1);
    app::FrameReader h2_decision{setup->decisions[0].payload};
    h2_decision.require(traffic::InterceptionCodec::Command::decision);
    h2_decision.integer<std::uint64_t>();
    check(h2_decision.tag(traffic::Verdict::reject) == traffic::Verdict::replace);
    const auto h2_edited = HttpMessageCodec::decode(h2_decision.bytes());
    check(h2_edited.version == HttpVersion::http2 && h2_edited.stream == 7 && h2_edited.authority == "example.test" && h2_edited.target == "/edited");
  }
  check(memory.liveBytes() == 0);
  write(entry, R"lua(
local traffic = require('telar.traffic')
local allowed, message = pcall(function() traffic.intercept({host='*'},function() end) end)
assert(not allowed and message:find('capability denied'))
traffic.subscribe({},function() end)
return {}
)lua");
  {
    const auto identity = specification(false);
    app::Host host{memory, entry.c_str(), &identity};
    SensitiveAllocation output{memory, app::TrafficLimits::reply_bytes};
    const auto setup = app::TrafficProtocol::reply(host.trafficSetup(output.bytes()));
    check(setup.registration_count == 1 && setup.registrations[0].stage == app::TrafficStage::observe);
  }
  check(memory.liveBytes() == 0);
}

static bool closed(int descriptor) {
  pollfd ready{descriptor, POLLIN, 0};
  if (::poll(&ready, 1, 5000) <= 0) { return false; }
  Byte value;
  return ::recv(descriptor, &value, 1, 0) == 0;
}

static void packageChannels() {
  SystemAllocator system;
  BudgetAllocator budget{system, 64 * 1024 * 1024};
  SynchronizedAllocator memory{budget};
  TemporaryDirectory directory{"/tmp/tlr-app-port.XXXXXX"};
  const auto path = std::string{directory.path()} + "/traffic";
  {
    traffic::Service service{memory, path, true};
    const auto observe = specification(false);
    std::array<Byte, traffic::Protocol::greeting_bytes> greeting;
    for (const auto role : {traffic::Role::intercept, traffic::Role::offline_capture}) {
      auto unauthorized = service.openPackage(observe);
      traffic::sendAll(unauthorized.get(), traffic::Protocol::greeting(greeting, role));
      check(closed(unauthorized.get()));
    }
    auto approved = service.openPackage(observe);
    traffic::sendAll(approved.get(), traffic::Protocol::greeting(greeting, traffic::Role::subscribe));
    pollfd ready{approved.get(), POLLIN, 0};
    check(::poll(&ready, 1, 5000) > 0);
    std::array<Byte, traffic::Protocol::prefix_bytes> prefix;
    check(::recv(approved.get(), prefix.data(), prefix.size(), MSG_WAITALL) == static_cast<ssize_t>(prefix.size()));
    app::FrameReader reader{prefix};
    const auto length = reader.integer<std::uint32_t>();
    std::vector<Byte> reply(length);
    check(::recv(approved.get(), reply.data(), reply.size(), MSG_WAITALL) == static_cast<ssize_t>(reply.size()));
    check(traffic::Protocol::decode(reply).kind == traffic::Kind::ready);
  }
  check(budget.liveBytes() == 0);
}

static void unavailablePolicies() {
  SystemAllocator system;
  BudgetAllocator budget{system, 8 * 1024 * 1024};
  SynchronizedAllocator memory{budget};
  {
    traffic::Interception broker{memory};
    broker.configure(1, {.host = "example.test", .visibility = 3, .fail_closed = true});
    const traffic::FlowEvent event{.id = 31, .host = "example.test"};
    const auto original = broker.begin(event);
    std::array<Byte, 64> output;
    check(broker.pending(1, original));
    broker.setAvailable(1, false);
    check(!broker.pending(1, original));
    check(broker.poll(original, output).verdict == traffic::Verdict::reject);
    check(broker.begin(event) == decltype(broker)::rejected_ticket);
    broker.setAvailable(1, true);
    const auto fresh = broker.begin(event);
    check(fresh != original && broker.pending(1, fresh));
    broker.decide(1, original, traffic::Verdict::allow, {});
    check(broker.poll(fresh, output).verdict == traffic::Verdict::pending);
    broker.cancel(fresh);
    broker.disconnect(1);

    broker.configure(1, {.host = "example.test", .visibility = 3}, 1);
    broker.configure(2, {.host = "example.test", .visibility = 3}, 2);
    const auto chain = broker.begin(event);
    broker.setAvailable(2, false);
    broker.setAvailable(2, true);
    constexpr std::array<Byte, 3> replacement{'a', 0, 'b'};
    broker.decide(1, chain, traffic::Verdict::replace, replacement);
    const auto result = broker.poll(chain, output);
    check(result.verdict == traffic::Verdict::replace && result.bytes == replacement.size());
    check(std::ranges::equal(std::span{output}.first(result.bytes), replacement));
    bool inherited = false;
    broker.deliver(2, [&](const auto &) { inherited = true; return true; });
    check(!inherited);
  }
  check(budget.liveBytes() == 0);
}

static void controlHost() {
  SystemAllocator system;
  BudgetAllocator memory{system, 80 * 1024 * 1024};
  TemporaryDirectory directory{"/tmp/tlr-app-control-host.XXXXXX"};
  const auto entry = std::string{directory.path()} + "/main.lua";
  write(entry, R"lua(
local traffic=require('telar.traffic')
local allowed,message=pcall(function() traffic.recordings.list(function() end) end)
assert(not allowed and message:find('capability denied'))
local cancel=traffic.status(function() error('Cancelled callback ran') end)
cancel()
traffic.status(function(err,reply)
  assert(not err and reply.result=='ok' and reply.administration_enabled)
  assert(reply.proxy.active and reply.proxy.port==41234)
  traffic.ca.certificate(function(err,reply)
    assert(not err and reply.ca.certificate=='pem\0blob')
  end)
end)
return {}
)lua");
  {
    auto identity = specification(false);
    identity.declared = {};
    identity.granted = {};
    identity.declared.insert(app::Capability::traffic_control);
    identity.granted.insert(app::Capability::traffic_control);
    app::Host host{memory, entry.c_str(), &identity};
    SensitiveAllocation output{memory, app::TrafficLimits::reply_bytes};
    SensitiveAllocation incoming{memory, traffic::control::Limits::reply_bytes};
    auto setup = makeOwned<app::TrafficReply>(memory);
    app::TrafficProtocol::readReply(host.trafficSetup(output.bytes()), *setup);
    check(setup->registration_count == 1 && setup->registrations[0].stage == app::TrafficStage::control);
    const auto original = setup->registrations[0].id;
    check(traffic::control::Protocol::request(setup->registrations[0].requestBytes()).operation == traffic::control::Operation::status);
    auto reply = traffic::control::Protocol::encode(incoming.bytes(), traffic::control::Reply{.status = {.proxy = true, .administration = true, .port = 41234}});
    app::TrafficEvent event{.event_id = 1, .registration = original, .dropped = 0, .event = {}, .control = reply};
    app::TrafficProtocol::readReply(host.invokeTraffic(event, output.bytes()), *setup);
    check(setup->changed && setup->registration_count == 1 && setup->registrations[0].id != original);
    check(traffic::control::Protocol::request(setup->registrations[0].requestBytes()).operation == traffic::control::Operation::ca_certificate);
    constexpr std::string_view bytes{"pem\0blob", 8};
    event.event_id = 2;
    event.registration = setup->registrations[0].id;
    event.control = traffic::control::Protocol::encode(incoming.bytes(), traffic::control::Reply{.certificate = {reinterpret_cast<const Byte *>(bytes.data()), bytes.size()}});
    app::TrafficProtocol::readReply(host.invokeTraffic(event, output.bytes()), *setup);
    check(setup->changed && setup->registration_count == 0);
  }
  check(memory.liveBytes() == 0);
}

static void datagramHost() {
  SystemAllocator system;
  BudgetAllocator memory{system, 80 * 1024 * 1024};
  TemporaryDirectory directory{"/tmp/tlr-datagram-host.XXXXXX"};
  const auto entry = std::string{directory.path()} + "/main.lua";
  write(entry, R"lua(
local traffic = require('telar.traffic')
local received = 0
local stop
stop = traffic.subscribe({events={datagram=true}},function(err,event)
  assert(not err,err)
  received = received + 1
  assert(event.kind=='datagram' and event.source=='capture' and event.visibility=='wire')
  assert(event.app.id=='traffic-fixture' and event.interface=='fixture' and event.offline)
  assert(event.flow_id==nil and event.direction==nil and not event.truncated)
  assert(event.captured_bytes==#event.bytes and event.original_bytes==#event.bytes)
  if received==1 then
    assert(event.transport=='udp' and not event.ipv6)
    assert(event.source_address=='127.0.0.1' and event.destination_address=='127.0.0.2')
    assert(event.source_port==1234 and event.destination_port==53 and event.bytes=='a\0b')
    assert(event.icmp_type==nil)
  else
    assert(event.transport=='icmpv6' and event.ipv6)
    assert(event.source_address=='::1' and event.destination_address=='::2')
    assert(event.icmp_type==128 and event.icmp_code==0 and event.source_port==nil)
    assert(event.icmp_identifier==22 and event.icmp_sequence==33)
    stop()
  end
end)
return {}
)lua");
  {
    const auto identity = specification(false);
    app::Host host{memory, entry.c_str(), &identity};
    SensitiveAllocation output{memory, app::TrafficLimits::reply_bytes};
    std::array<Byte, 256> payload;
    auto setup = makeOwned<app::TrafficReply>(memory);
    app::TrafficProtocol::readReply(host.trafficSetup(output.bytes()), *setup);
    check(setup->registration_count == 1 && setup->registrations[0].selection == traffic::Selection::datagrams);
    const auto registration = setup->registrations[0].id;
    constexpr std::array<Byte, 3> body{'a', 0, 'b'};
    traffic::DatagramEvent item{.source_port = 1234, .destination_port = 53, .original_bytes = body.size(), .bytes = body};
    item.source_address[0] = item.destination_address[0] = 127;
    item.source_address[3] = 1;
    item.destination_address[3] = 2;
    app::TrafficEvent incoming{.event_id = 1, .registration = registration, .event = {.kind = traffic::Kind::datagram, .offline = true, .interface = "fixture", .bytes = traffic::DatagramCodec::encode(payload, item)}};
    app::TrafficProtocol::readReply(host.invokeTraffic(incoming, output.bytes()), *setup);
    check(setup->registration_count == 0 && !setup->changed);
    constexpr std::array<Byte, 8> echo{128, 0, 0, 0, 0, 22, 0, 33};
    item = {.transport = traffic::DatagramTransport::icmpv6, .ipv6 = true, .icmp_type = 128, .original_bytes = echo.size(), .bytes = echo};
    item.source_address[15] = 1;
    item.destination_address[15] = 2;
    incoming.event_id = 2;
    incoming.event.bytes = traffic::DatagramCodec::encode(payload, item);
    app::TrafficProtocol::readReply(host.invokeTraffic(incoming, output.bytes()), *setup);
    check(setup->changed && setup->registration_count == 0);
  }
  check(memory.liveBytes() == 0);
}

int main() {
  host();
  packageChannels();
  unavailablePolicies();
  controlHost();
  datagramHost();
  std::puts("Package traffic: Lua callbacks, binary HTTP decisions, dynamic cancellation, notifications and native capability enforcement passed");
}
