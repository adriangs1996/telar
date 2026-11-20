#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_platform/file_descriptor.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <algorithm>
#include <arpa/inet.h>
#include <array>
#include <atomic>
#include <bit>
#include <cassert>
#include <cerrno>
#include <charconv>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <exception>
#include <fcntl.h>
#include <fstream>
#include <initializer_list>
#include <lauxlib.h>
#include <limits.h>
#include <lua.h>
#include <lualib.h>
#include <memory>
#include <mutex>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <optional>
#include <pcap/pcap.h>
#include <poll.h>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <thread>
#include <type_traits>
#include <unistd.h>
#include <unordered_map>
#include <utility>

import telar.testing;
import telar.testing.test_memory;
import telar.runtime.plugins.run_worker;
import telar.platform.fs;
import telar.runtime.traffic.capture_analysis;
import telar.runtime.traffic.control_backend;
import telar.base.memory.sensitive;
import telar.plugins;
import telar.runtime.http.message;
import telar.runtime.plugins.service;
import telar.runtime.plugins.worker;
import telar.platform.process;
import telar.runtime.traffic.control_protocol;
import telar.config.runtime;
import telar.runtime.vocabulary.exchange;
import telar.runtime.vocabulary.frames;
import telar.runtime.vocabulary.traffic;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using telar::Byte;
  namespace app = telar::runtime::plugins;

  app::ServiceSpec specification(bool intercept) {
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

  void write(const std::string& path, std::string_view source) {
    std::ofstream file{path};

    file << source;
    check(file.good());
  }

  void host() {
    SystemAllocator system;
    BudgetAllocator budget{system, 80 * 1024 * 1024};
    MemoryAdapter adapter{budget};
    Memory& memory = adapter;
    TemporaryDirectory directory{"/tmp/tlr-app-host.XXXXXX"};
    const auto entry = std::string{directory.path()} + "/main.lua";

    write(entry, R"lua(
local traffic = require('telar.traffic')
assert(io == nil and debug == nil)
local os_names = {}
for name in pairs(os) do os_names[#os_names + 1] = name end
table.sort(os_names)
assert(table.concat(os_names, ',') == 'clock,date,time')
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
      auto setup = ds::makeBox<app::TrafficReply>(memory);

      app::TrafficProtocol::readReply(host.trafficSetup(output.bytesMut()), setup.getMut());
      check(setup->changed && setup->registration_count == 2);
      check(setup->registrations[0].filter.view() == "udp port 53535" && setup->registrations[1].stage == app::TrafficStage::http);
      constexpr std::string_view bytes{"a\0b", 3};
      app::TrafficEvent packet{.event_id = 1, .registration = setup->registrations[0].id, .dropped = 0, .event = {.kind = traffic::Kind::packet, .original_bytes = 3, .bytes = {reinterpret_cast<const Byte*>(bytes.data()), bytes.size()}}};
      const auto response = host.invokeTraffic(packet, output.bytesMut());
      const auto observed = app::TrafficProtocol::readReply(response, setup.getMut());

      check(setup->changed && setup->registration_count == 1 && observed.decision_count == 0);
      check(app::Protocol::decodeEffects(observed.effects).batch.notifications[0].title == "packet verified");

      constexpr std::string_view body{"original\0body", 13};
      HttpMessageView message{.method = "POST", .target = "/", .body = {reinterpret_cast<const Byte*>(body.data()), body.size()}};
      SensitiveAllocation encoded_message{memory, HttpMessageLimits::message_bytes};
      SensitiveAllocation encoded_flow{memory, HttpMessageLimits::message_bytes + traffic::Limits::metadata_bytes};
      const auto payload = HttpMessageCodec::encode(encoded_message.bytesMut(), message);
      const auto flow = traffic::FlowCodec::encode(encoded_flow.bytesMut(), {.id = 31, .ticket = 123, .host = "example.test", .bytes = payload});
      app::TrafficEvent request{.event_id = 2, .registration = setup->registrations[0].id, .dropped = 0, .event = {.kind = traffic::Kind::http_intercept_request, .bytes = flow}};
      const auto decided = app::TrafficProtocol::readReply(host.invokeTraffic(request, output.bytesMut()), setup.getMut());

      check(!setup->changed && decided.decision_count == 1);
      app::FrameReader decision{decided.decisions[0].payload};

      decision.require(traffic::InterceptionCodec::Command::decision);
      check(decision.integer<std::uint64_t>() == 123 && decision.tag(traffic::Verdict::reject) == traffic::Verdict::replace);
      const auto edited = HttpMessageCodec::decode(decision.bytes());

      decision.finish();
      check(edited.target == "/edited" && edited.header_count == 2 && edited.headers[1].value == "two");
      check(std::string_view{reinterpret_cast<const char*>(edited.body.data()), edited.body.size()} == std::string_view{"original\0body\0suffix", 20});
      message.version = HttpVersion::http2;
      message.stream = 7;
      message.scheme = "https";
      message.authority = "example.test";
      const auto h2_payload = HttpMessageCodec::encode(encoded_message.bytesMut(), message);

      request.event_id = 3;
      request.event.bytes = traffic::FlowCodec::encode(encoded_flow.bytesMut(), {.id = 31, .ticket = 123, .host = "example.test", .bytes = h2_payload});
      const auto h2_decided = app::TrafficProtocol::readReply(host.invokeTraffic(request, output.bytesMut()), setup.getMut());

      check(h2_decided.decision_count == 1);
      app::FrameReader h2_decision{h2_decided.decisions[0].payload};

      h2_decision.require(traffic::InterceptionCodec::Command::decision);
      h2_decision.integer<std::uint64_t>();
      check(h2_decision.tag(traffic::Verdict::reject) == traffic::Verdict::replace);
      const auto h2_edited = HttpMessageCodec::decode(h2_decision.bytes());

      check(h2_edited.version == HttpVersion::http2 && h2_edited.stream == 7 && h2_edited.authority == "example.test" && h2_edited.target == "/edited");
    }

    check(budget.liveBytes() == 0);
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
      const auto setup = app::TrafficProtocol::reply(host.trafficSetup(output.bytesMut()));

      check(setup.registration_count == 1 && setup.registrations[0].stage == app::TrafficStage::observe);
    }

    check(budget.liveBytes() == 0);
  }

  bool closed(int descriptor) {
    pollfd ready{descriptor, POLLIN, 0};
    if (::poll(&ready, 1, 5000) <= 0) {
      return false;
    }

    Byte value;

    return ::recv(descriptor, &value, 1, 0) == 0;
  }

  // Reads `bytes` whole from a channel the service hands out non-blocking, where MSG_WAITALL returns
  // what has arrived so far.
  bool receiveExactly(int descriptor, std::span<Byte> bytes) {
    while (!bytes.empty()) {
      pollfd ready{descriptor, POLLIN, 0};

      if (::poll(&ready, 1, 5000) <= 0) {
        return false;
      }

      const auto count = ::recv(descriptor, bytes.data(), bytes.size(), 0);

      if (count < 0 && (errno == EAGAIN || errno == EINTR)) {
        continue;
      }

      if (count <= 0) {
        return false;
      }

      bytes = bytes.subspan(static_cast<std::size_t>(count));
    }

    return true;
  }

  void packageChannels() {
    SystemAllocator system;
    BudgetAllocator budget{system, 64 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/tlr-app-port.XXXXXX"};
    const auto path = std::string{directory.path()} + "/traffic";

    {
      traffic::Service service{memory, path, true};
      const auto observe = specification(false);
      ds::Array<Byte, traffic::Protocol::greeting_bytes> greeting;

      for (const auto role : {traffic::Role::intercept, traffic::Role::offline_capture}) {
        auto unauthorized = service.openPackage(observe);

        traffic::sendAll(unauthorized.get(), traffic::Protocol::greeting(greeting.viewMut(), role));
        check(closed(unauthorized.get()));
      }

      auto approved = service.openPackage(observe);

      traffic::sendAll(approved.get(), traffic::Protocol::greeting(greeting.viewMut(), traffic::Role::subscribe));
      pollfd ready{approved.get(), POLLIN, 0};

      check(::poll(&ready, 1, 5000) > 0);
      ds::Array<Byte, traffic::Protocol::prefix_bytes> prefix;

      check(receiveExactly(approved.get(), prefix.viewMut()));
      app::FrameReader reader{prefix};
      const auto length = reader.integer<std::uint32_t>();
      std::vector<Byte> reply(length);

      check(receiveExactly(approved.get(), reply));
      check(traffic::Protocol::decode(reply).kind == traffic::Kind::ready);
    }

    check(budget.liveBytes() == 0);
  }

  void unavailablePolicies() {
    SystemAllocator system;
    BudgetAllocator budget{system, 8 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;

    {
      traffic::Interception broker{memory};

      broker.configure(1, {.host = "example.test", .visibility = 3, .fail_closed = true});
      const traffic::FlowEvent event{.id = 31, .host = "example.test"};
      const auto original = broker.begin(event);
      ds::Array<Byte, 64> output;

      check(broker.pending(1, original));
      broker.setAvailable(1, false);
      check(!broker.pending(1, original));
      check(broker.poll(original, output.viewMut()).verdict == traffic::Verdict::reject);
      check(broker.begin(event) == decltype(broker)::rejected_ticket);
      broker.setAvailable(1, true);
      const auto fresh = broker.begin(event);

      check(fresh != original && broker.pending(1, fresh));
      broker.decide(1, original, traffic::Verdict::allow, {});
      check(broker.poll(fresh, output.viewMut()).verdict == traffic::Verdict::pending);
      broker.cancel(fresh);
      broker.disconnect(1);

      broker.configure(1, {.host = "example.test", .visibility = 3}, 1);
      broker.configure(2, {.host = "example.test", .visibility = 3}, 2);
      const auto chain = broker.begin(event);

      broker.setAvailable(2, false);
      broker.setAvailable(2, true);
      constexpr ds::Array<Byte, 3> replacement{'a', 0, 'b'};

      broker.decide(1, chain, traffic::Verdict::replace, replacement);
      const auto result = broker.poll(chain, output.viewMut());

      check(result.verdict == traffic::Verdict::replace && result.bytes == replacement.size());
      check(std::ranges::equal(std::span{output}.first(result.bytes), replacement));
      bool inherited = false;

      broker.deliver(2, [&](const auto&) {
        inherited = true;
        return true;
      });

      check(!inherited);
    }

    check(budget.liveBytes() == 0);
  }

  void controlHost() {
    SystemAllocator system;
    BudgetAllocator budget{system, 80 * 1024 * 1024};
    MemoryAdapter adapter{budget};
    Memory& memory = adapter;
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
      auto setup = ds::makeBox<app::TrafficReply>(memory);

      app::TrafficProtocol::readReply(host.trafficSetup(output.bytesMut()), setup.getMut());
      check(setup->registration_count == 1 && setup->registrations[0].stage == app::TrafficStage::control);
      const auto original = setup->registrations[0].id;

      check(traffic::control::Protocol::request(setup->registrations[0].requestBytes()).operation == traffic::control::Operation::status);
      auto reply = traffic::control::Protocol::encode(incoming.bytesMut(), traffic::control::Reply{.status = {.proxy = true, .administration = true, .port = 41234}});
      app::TrafficEvent event{.event_id = 1, .registration = original, .dropped = 0, .event = {}, .control = reply};

      app::TrafficProtocol::readReply(host.invokeTraffic(event, output.bytesMut()), setup.getMut());
      check(setup->changed && setup->registration_count == 1 && setup->registrations[0].id != original);
      check(traffic::control::Protocol::request(setup->registrations[0].requestBytes()).operation == traffic::control::Operation::ca_certificate);
      constexpr std::string_view bytes{"pem\0blob", 8};

      event.event_id = 2;
      event.registration = setup->registrations[0].id;
      event.control = traffic::control::Protocol::encode(incoming.bytesMut(), traffic::control::Reply{.certificate = {reinterpret_cast<const Byte*>(bytes.data()), bytes.size()}});
      app::TrafficProtocol::readReply(host.invokeTraffic(event, output.bytesMut()), setup.getMut());
      check(setup->changed && setup->registration_count == 0);
    }

    check(budget.liveBytes() == 0);
  }

  void datagramHost() {
    SystemAllocator system;
    BudgetAllocator budget{system, 80 * 1024 * 1024};
    MemoryAdapter adapter{budget};
    Memory& memory = adapter;
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
      ds::Array<Byte, 256> payload;
      auto setup = ds::makeBox<app::TrafficReply>(memory);

      app::TrafficProtocol::readReply(host.trafficSetup(output.bytesMut()), setup.getMut());
      check(setup->registration_count == 1 && setup->registrations[0].selection == traffic::Selection::datagrams);
      const auto registration = setup->registrations[0].id;
      constexpr ds::Array<Byte, 3> body{'a', 0, 'b'};
      traffic::DatagramEvent item{.source_port = 1234, .destination_port = 53, .original_bytes = body.size(), .bytes = body};

      item.source_address.atMut(0) = item.destination_address.atMut(0) = 127;
      item.source_address.atMut(3) = 1;
      item.destination_address.atMut(3) = 2;
      app::TrafficEvent incoming{.event_id = 1, .registration = registration, .event = {.kind = traffic::Kind::datagram, .offline = true, .interface = "fixture", .bytes = traffic::DatagramCodec::encode(payload.viewMut(), item)}};

      app::TrafficProtocol::readReply(host.invokeTraffic(incoming, output.bytesMut()), setup.getMut());
      check(setup->registration_count == 0 && !setup->changed);
      constexpr ds::Array<Byte, 8> echo{128, 0, 0, 0, 0, 22, 0, 33};

      item = {.transport = traffic::DatagramTransport::icmpv6, .ipv6 = true, .icmp_type = 128, .original_bytes = echo.size(), .bytes = echo};
      item.source_address.atMut(15) = 1;
      item.destination_address.atMut(15) = 2;
      incoming.event_id = 2;
      incoming.event.bytes = traffic::DatagramCodec::encode(payload.viewMut(), item);
      app::TrafficProtocol::readReply(host.invokeTraffic(incoming, output.bytesMut()), setup.getMut());
      check(setup->changed && setup->registration_count == 0);
    }

    check(budget.liveBytes() == 0);
  }

  // A stream interception event for `ticket`, encoded into `buffer`.
  app::TrafficEvent interception(std::span<Byte> buffer, std::uint32_t registration, std::uint64_t ticket) {
    constexpr std::string_view bytes{"payload"};
    const auto flow = traffic::FlowCodec::encode(buffer, {.id = ticket, .ticket = ticket, .host = "example.test", .bytes = {reinterpret_cast<const Byte*>(bytes.data()), bytes.size()}});

    return {.event_id = ticket, .registration = registration, .dropped = 0, .event = {.kind = traffic::Kind::intercept_request, .bytes = flow}};
  }

  // A callback may answer the flows it held back, but no more of them at once than a reply
  // carries, and no replacement past a stream chunk: past either it gets an error frame, never
  // a reply with part of its decisions.
  void decisionsBounded() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    TemporaryDirectory directory{"/tmp/tlr-app-decisions.XXXXXX"};
    const auto entry = std::string{directory.path()} + "/main.lua";

    write(entry, R"lua(
local traffic = require('telar.traffic')
local held = {}
traffic.intercept({stage='stream', host='example.test'}, function(err, event)
  assert(not err, err)
  local ticket = tonumber(event.ticket)
  if ticket == 1000 then
    return {action='replace', bytes=string.rep('x', )lua" +
                     std::to_string(traffic::FlowControl::chunk_bytes) + R"lua()}
  elseif ticket == 1001 then
    return {action='replace', bytes=string.rep('x', )lua" +
                     std::to_string(traffic::FlowControl::chunk_bytes + 1) + R"lua()}
  elseif ticket % 100 == 0 then
    for _, respond in ipairs(held) do respond({action='allow'}) end
    held = {}
  else
    held[#held + 1] = event.respond
  end
end)
return {}
)lua");
    const auto identity = specification(true);
    app::Host host{memory, entry.c_str(), &identity};
    SensitiveAllocation output{memory, app::TrafficLimits::reply_bytes};
    std::vector<Byte> buffer(traffic::Limits::metadata_bytes + 1024);
    auto setup = ds::makeBox<app::TrafficReply>(memory);

    app::TrafficProtocol::readReply(host.trafficSetup(output.bytesMut()), setup.getMut());
    check(setup->registration_count == 1);
    const auto registration = setup->registrations[0].id;
    const auto invoke = [&](std::uint64_t ticket) {
      return host.invokeTraffic(interception(buffer, registration, ticket), output.bytesMut());
    };

    for (std::uint64_t ticket = 1; ticket <= app::TrafficLimits::decisions; ++ticket) {
      check(app::TrafficProtocol::readReply(invoke(ticket), setup.getMut()).decision_count == 0);
    }

    check(app::TrafficProtocol::readReply(invoke(100), setup.getMut()).decision_count == app::TrafficLimits::decisions);

    for (std::uint64_t ticket = 101; ticket <= 101 + app::TrafficLimits::decisions; ++ticket) {
      check(app::TrafficProtocol::readReply(invoke(ticket), setup.getMut()).decision_count == 0);
    }

    check(app::Protocol::decodeError(invoke(200)).event_id == 200);
    check(app::TrafficProtocol::readReply(invoke(1000), setup.getMut()).decision_count == 1);
    check(app::Protocol::decodeError(invoke(1001)).event_id == 1001);
  }

  // An HTTP replacement holds as many header and trailer fields as a message carries: more is
  // an error frame, never a message with some of them.
  void httpReplaceBounded() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    TemporaryDirectory directory{"/tmp/tlr-app-replace.XXXXXX"};
    const auto entry = std::string{directory.path()} + "/main.lua";

    write(entry, R"lua(
local traffic = require('telar.traffic')
traffic.intercept({stage='http', host='example.test'}, function(err, event)
  assert(not err, err)
  local id = tonumber(event.flow_id)
  local fields = {}
  for index = 1, id // 2 do fields[index] = {name='x-field', value=tostring(index)} end
  if id % 2 == 0 then
    return {action='replace', headers=fields}
  end
  return {action='replace', trailers=fields}
end)
return {}
)lua");
    const auto identity = specification(true);
    app::Host host{memory, entry.c_str(), &identity};
    SensitiveAllocation output{memory, app::TrafficLimits::reply_bytes};
    SensitiveAllocation encoded_message{memory, HttpMessageLimits::message_bytes};
    SensitiveAllocation encoded_flow{memory, HttpMessageLimits::message_bytes + traffic::Limits::metadata_bytes};
    auto setup = ds::makeBox<app::TrafficReply>(memory);

    app::TrafficProtocol::readReply(host.trafficSetup(output.bytesMut()), setup.getMut());
    const auto payload = HttpMessageCodec::encode(encoded_message.bytesMut(), HttpMessageView{.method = "GET", .target = "/"});
    const HttpMessageView capacity{};
    std::uint64_t ticket = 0;
    const auto invoke = [&](std::size_t fields, bool headers) {
      ++ticket;
      const auto flow = traffic::FlowCodec::encode(encoded_flow.bytesMut(), {.id = fields * 2 + (headers ? 0 : 1), .ticket = ticket, .host = "example.test", .bytes = payload});

      return host.invokeTraffic({.event_id = ticket, .registration = setup->registrations[0].id, .dropped = 0, .event = {.kind = traffic::Kind::http_intercept_request, .bytes = flow}}, output.bytesMut());
    };

    for (const bool headers : {true, false}) {
      const auto limit = headers ? capacity.headers.size() : capacity.trailers.size();
      const auto decided = app::TrafficProtocol::readReply(invoke(limit, headers), setup.getMut());

      check(decided.decision_count == 1);
      app::FrameReader decision{decided.decisions[0].payload};

      decision.require(traffic::InterceptionCodec::Command::decision);
      decision.integer<std::uint64_t>();
      check(decision.tag(traffic::Verdict::reject) == traffic::Verdict::replace);
      const auto message = HttpMessageCodec::decode(decision.bytes());

      check((headers ? message.header_count : message.trailer_count) == limit);
      check(app::Protocol::decodeError(invoke(limit + 1, headers)).event_id == ticket);
      check(app::Protocol::decodeError(invoke(64 * limit, headers)).event_id == ticket);
    }
  }

  // A plugin's redirect request names at most as many targets and processes as the control
  // protocol carries, and a process list it gives is not empty: past that the call raises.
  void redirectBounds() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    TemporaryDirectory directory{"/tmp/tlr-app-redirect.XXXXXX"};
    const auto entry = std::string{directory.path()} + "/main.lua";
    const auto targets = std::to_string(traffic::control::Limits::targets);
    const auto processes = std::to_string(traffic::control::Limits::processes);

    write(entry, R"lua(
local traffic = require('telar.traffic')
local function list(count, value)
  local result = {}
  for index = 1, count do result[index] = value(index) end
  return result
end
local function target() return 'example.test:443' end
local function process(index) return 1000 + index end
local function start(options) return pcall(traffic.redirect.start, options, function() end) end
assert(start({targets=list()lua" +
                     targets + R"lua(, target), processes=list()lua" + processes + R"lua(, process)}))
assert(not start({targets=list()lua" +
                     targets + R"lua( + 1, target)}))
assert(not start({targets=list(1000, target)}))
assert(not start({targets={'example.test:443'}, processes={}}))
assert(not start({targets={'example.test:443'}, processes=list()lua" +
                     processes + R"lua( + 1, process)}))
return {}
)lua");
    auto identity = specification(false);

    identity.declared = {};
    identity.granted = {};
    identity.declared.insert(app::Capability::traffic_control);
    identity.granted.insert(app::Capability::traffic_control);
    app::Host host{memory, entry.c_str(), &identity};
    SensitiveAllocation output{memory, app::TrafficLimits::reply_bytes};
    auto setup = ds::makeBox<app::TrafficReply>(memory);

    app::TrafficProtocol::readReply(host.trafficSetup(output.bytesMut()), setup.getMut());
    check(setup->registration_count == 1);
    check(traffic::control::Protocol::request(setup->registrations[0].requestBytes()).process_count == traffic::control::Limits::processes);
  }

  // A flow held for a plugin whose callback fails gets the verdict the plugin chose for failure,
  // and the failure reaches the plugin's observers as a flow error naming the plugin.
  void workerCrashAppliesFailurePolicy() {
    SystemAllocator system;
    BudgetAllocator budget{system, 64 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/tlr-app-failure.XXXXXX"};
    const auto entry = std::string{directory.path()} + "/main.lua";
    const ExecutablePath executable;

    for (const auto policy : {std::string_view{"reject"}, std::string_view{"allow"}}) {
      write(entry, R"lua(
local telar = require('telar')
local traffic = require('telar.traffic')
traffic.subscribe({events={flow=true}}, function(err, event)
  if event and event.kind == 'flow.error' then
    return {telar.effect.notification{title=event.reason}}
  end
end)
traffic.intercept({stage='stream', host='example.test', visibility='both', timeout_ms=30000, failure=')lua" +
                       std::string{policy} + R"lua('}, function()
  error('callback failed')
end)
return {}
)lua");
      traffic::Service network{memory, std::string{directory.path()} + "/traffic", true};
      auto identity = specification(true);

      identity.entry.assign(entry);
      identity.declared.insert(app::Capability::notifications);
      identity.granted.insert(app::Capability::notifications);
      const ds::Array specifications{identity};
      app::Service plugins{memory, std::span<const app::ServiceSpec>{specifications}, executable.cStr(), {}, &network};
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
      std::uint64_t ticket = 0;

      // The worker registers its interception once it starts: until then flows pass.
      while (ticket == 0) {
        check(std::chrono::steady_clock::now() < deadline);
        ticket = network.intercept({.id = 31, .visibility = traffic::Visibility::plaintext, .host = "example.test"});
        if (ticket == 0) {
          std::this_thread::sleep_for(std::chrono::milliseconds{10});
        }
      }

      ds::Array<Byte, 64> replacement;
      auto decision = network.poll(ticket, replacement.viewMut());

      while (decision.verdict == traffic::Verdict::pending) {
        check(std::chrono::steady_clock::now() < deadline);
        std::this_thread::sleep_for(std::chrono::milliseconds{10});
        decision = network.poll(ticket, replacement.viewMut());
      }

      check(decision.verdict == (policy == "reject" ? traffic::Verdict::reject : traffic::Verdict::allow));
      bool reported = false;

      while (!reported) {
        check(std::chrono::steady_clock::now() < deadline);
        plugins.collect([&](const app::EffectBatch& batch) {
          reported |= batch.count == 1 && batch.notifications[0].title == "app_callback_error:traffic-fixture";
        });

        std::this_thread::sleep_for(std::chrono::milliseconds{10});
      }
    }

    check(budget.liveBytes() == 0);
  }

  // The registrations a plugin entry leaves after it runs, read as the host reads them.
  std::size_t registered(Memory& memory, const std::string& entry, const app::ServiceSpec& identity) {
    app::Host host{memory, entry.c_str(), &identity};
    SensitiveAllocation output{memory, app::TrafficLimits::reply_bytes};
    auto setup = ds::makeBox<app::TrafficReply>(memory);

    app::TrafficProtocol::readReply(host.trafficSetup(output.bytesMut()), setup.getMut());
    return setup->registration_count;
  }

  app::ServiceSpec controlSpecification() {
    auto identity = specification(false);

    identity.declared = {};
    identity.granted = {};
    identity.declared.insert(app::Capability::traffic_control);
    identity.granted.insert(app::Capability::traffic_control);
    return identity;
  }

  // A package holds at most 32 registrations and 8 pending control requests. One more is
  // an error the plugin can catch, and the ones it already holds stay registered.
  void registrationLimits() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    TemporaryDirectory directory{"/tmp/tlr-app-limits.XXXXXX"};
    const auto entry = std::string{directory.path()} + "/main.lua";

    write(entry, R"lua(
local traffic = require('telar.traffic')
for index = 1, )lua" +
                     std::to_string(app::TrafficLimits::registrations) +
                     R"lua( do
  assert(pcall(traffic.subscribe, {events={packet=true}}, function() end))
end
local allowed, message = pcall(traffic.subscribe, {events={packet=true}}, function() end)
assert(not allowed and message:find('limit'))
return {}
)lua");
    check(registered(memory, entry, specification(false)) == app::TrafficLimits::registrations);

    write(entry, R"lua(
local traffic = require('telar.traffic')
for index = 1, )lua" +
                     std::to_string(app::TrafficLimits::controls) +
                     R"lua( do
  assert(pcall(traffic.status, function() end))
end
local allowed, message = pcall(traffic.status, function() end)
assert(not allowed and message:find('limit'))
return {}
)lua");
    check(registered(memory, entry, controlSpecification()) == app::TrafficLimits::controls);
  }

  // Options the traffic API cannot honour are refused with an error and register nothing,
  // never read as a default: a misspelt failure policy must not turn a fail-closed rule
  // into fail-open.
  void optionValidation() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    TemporaryDirectory directory{"/tmp/tlr-app-options.XXXXXX"};
    const auto entry = std::string{directory.path()} + "/main.lua";

    write(entry, R"lua(
local traffic = require('telar.traffic')
local function refused(register, options)
  local allowed = pcall(register, options, function() end)
  assert(not allowed)
end
refused(traffic.subscribe, {events={packet=true}, filter=string.rep('a', )lua" +
                     std::to_string(traffic::Limits::filter_bytes + 1) + R"lua()})
refused(traffic.subscribe, {events={packet=true}, filter='tcp\0port 80'})
refused(traffic.subscribe, {events={}})
refused(traffic.intercept, {host='bad host'})
refused(traffic.intercept, {host='example.test', stage='packet'})
refused(traffic.intercept, {host='example.test', direction='sideways'})
refused(traffic.intercept, {host='example.test', visibility='hidden'})
refused(traffic.intercept, {host='example.test', failure='rejct'})
traffic.subscribe({events={packet=true}}, function() end)
return {}
)lua");
    check(registered(memory, entry, specification(true)) == 1);
  }

  // An exchange reaches a traffic plugin with its ids as decimal strings, exact past 2^53,
  // and each half's own status, outcome and timing.
  void exchangeEvent() {
    SystemAllocator system;
    BudgetAllocator budget{system, 80 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/tlr-app-exchange.XXXXXX"};
    const auto entry = std::string{directory.path()} + "/main.lua";
    constexpr std::uint64_t identity = (std::uint64_t{1} << 60) + 1;
    constexpr std::uint64_t connection = (std::uint64_t{1} << 62) + 3;

    write(entry, R"lua(
local telar = require('telar')
local traffic = require('telar.traffic')
traffic.subscribe({events={exchange=true}}, function(err, event)
  assert(not err, err)
  local exchange = event.exchange
  assert(event.kind == 'exchange')
  assert(exchange.id == ')lua" +
                     std::to_string(identity) + R"lua(' and exchange.connection_id == ')lua" + std::to_string(connection) + R"lua(')
  local request = exchange.request
  assert(request.head_truncated == false and request.status == 0)
  assert(type(request.outcome) == 'string' and math.type(request.finished_at_ms) == 'integer')
  return {telar.effect.notification{title='exchange verified'}}
end)
return {}
)lua");
    {
      CaptureQuota quota{4096};
      const ProxyCaptureLimits limits{.part_bytes = 1024, .exchange_bytes = 2048, .total_bytes = 4096, .enabled = true};
      CapturedExchange exchange{memory};

      exchange.request = ds::makeBox<CaptureHalf>(memory, memory, quota, limits, CaptureStart{.key = {connection, 1}, .side = CaptureSide::request, .protocol = CaptureProtocol::http1, .host = "example.test", .started_at_ms = 1});
      exchange.request.getMut().appendHead("GET / HTTP/1.1\r\n\r\n");
      ds::Array<Byte, 4096> encoded;
      const auto bytes = app::Protocol::encodeExchange(encoded.viewMut(), {identity, 1}, exchange);
      const auto spec = specification(false);
      Memory& host_memory = adapter;
      app::Host host{host_memory, entry.c_str(), &spec};
      SensitiveAllocation output{host_memory, app::TrafficLimits::reply_bytes};
      auto setup = ds::makeBox<app::TrafficReply>(host_memory);

      app::TrafficProtocol::readReply(host.trafficSetup(output.bytesMut()), setup.getMut());
      check(setup->registration_count == 1);
      app::TrafficEvent event{.event_id = 1, .registration = setup->registrations[0].id, .dropped = 0, .event = {.kind = traffic::Kind::exchange, .bytes = bytes}};
      const auto reply = app::TrafficProtocol::readReply(host.invokeTraffic(event, output.bytesMut()), setup.getMut());
      const auto effects = app::Protocol::decodeEffects(reply.effects);

      check(effects.batch.count == 1 && effects.batch.notifications[0].title == "exchange verified");
      exchange.request.reset();
      check(quota.used() == 0);
    }

    check(budget.liveBytes() == 0);
  }

  // A registration as a traffic worker writes it into a reply, valid unless a field is changed.
  struct ForgedRegistration {
    std::uint32_t id = 1;
    app::TrafficStage stage = app::TrafficStage::stream;
    Byte selection = static_cast<Byte>(traffic::Selection::packets);
    std::string filter;
    std::string host = "example.test";
    Byte directions = 3;
    Byte visibility = 2;
    std::uint32_t timeout_ms = 1000;
    std::string request;
  };

  // A reply as a worker could write it, counts included, whatever they claim.
  struct ForgedReply {
    bool changed = true;
    Byte registration_count = 1;
    std::vector<ForgedRegistration> registrations{ForgedRegistration{}};
    Byte decision_count = 0;
    std::size_t decisions = 0;
    std::size_t effect_bytes = 0;
  };

  std::vector<Byte> forge(const ForgedReply& forged) {
    std::vector<Byte> output(app::TrafficLimits::reply_bytes + forged.effect_bytes);
    app::FrameWriter writer{output};

    writer.tag(app::FrameKind::traffic_reply);
    writer.integer(std::uint64_t{9});
    writer.boolean(forged.changed);
    writer.integer(forged.registration_count);
    for (const auto& registration : forged.registrations) {
      writer.integer(registration.id);
      writer.tag(registration.stage);
      writer.integer(registration.selection);
      writer.text(registration.filter);
      writer.text(registration.host);
      writer.integer(registration.directions);
      writer.integer(registration.visibility);
      writer.integer(registration.timeout_ms);
      writer.boolean(false);
      writer.text(registration.request);
    }

    writer.integer(forged.decision_count);
    for (std::size_t index = 0; index < forged.decisions; ++index) {
      writer.integer(std::uint32_t{1});
      writer.bytes({});
    }

    writer.bytes(std::vector<Byte>(forged.effect_bytes));
    const auto written = writer.finish();

    return {written.begin(), written.end()};
  }

  bool rejected(std::span<const Byte> input) {
    auto reply = std::make_unique<app::TrafficReply>();

    try {
      app::TrafficProtocol::readReply(input, *reply);
      return false;
    } catch (const std::exception&) {
      return true;
    }
  }

  // The host reads a traffic worker's reply into fixed tables: a reply whose counts, sizes
  // or registrations a worker could not have sent honestly is refused whole.
  void replyRejectsOutOfBounds() {
    auto reply = std::make_unique<app::TrafficReply>();

    check(app::TrafficProtocol::readReply(forge({}), *reply).decision_count == 0 && reply->registration_count == 1);
    check(!rejected(forge({.effect_bytes = app::TrafficLimits::reply_bytes / 2})));
    check(rejected(forge({.effect_bytes = app::TrafficLimits::reply_bytes})));

    const auto past = static_cast<Byte>(app::TrafficLimits::registrations + 1);
    ForgedReply too_many{.registration_count = past};

    too_many.registrations.resize(past);
    for (std::uint32_t index = 0; index < too_many.registrations.size(); ++index) {
      too_many.registrations[index].id = index + 1;
    }

    check(rejected(forge(too_many)));
    check(rejected(forge({.registration_count = 255})));
    check(rejected(forge({.changed = false})));
    check(rejected(forge({.decision_count = static_cast<Byte>(app::TrafficLimits::decisions + 1), .decisions = app::TrafficLimits::decisions + 1})));
    check(rejected(forge({.decision_count = 255, .decisions = 255})));

    const ds::Array<ForgedRegistration, 13> invalid{
        ForgedRegistration{.id = 0},
        ForgedRegistration{.selection = 0},
        ForgedRegistration{.stage = app::TrafficStage::observe, .filter = std::string{"tcp\0port", 8}},
        ForgedRegistration{.request = "x"},
        ForgedRegistration{.filter = "tcp"},
        ForgedRegistration{.host = "bad host"},
        ForgedRegistration{.directions = 0},
        ForgedRegistration{.directions = 4},
        ForgedRegistration{.visibility = 0},
        ForgedRegistration{.visibility = 4},
        ForgedRegistration{.timeout_ms = 0},
        ForgedRegistration{.timeout_ms = traffic::maximum_timeout_ms + 1},
        ForgedRegistration{.stage = app::TrafficStage::http, .timeout_ms = 0},
    };

    for (std::size_t index = 0; index < invalid.size(); ++index) {
      check(rejected(forge({.registrations = {invalid[index]}})), std::to_string(index));
    }
  }

  const telar::testing::Case case_host{
      "plugin_traffic.host",
      [] {
        host();
      },
  };
  const telar::testing::Case case_package_channels{
      "plugin_traffic.package_channels",
      [] {
        packageChannels();
      },
  };
  const telar::testing::Case case_unavailable_policies{
      "plugin_traffic.unavailable_policies",
      [] {
        unavailablePolicies();
      },
  };
  const telar::testing::Case case_control_host{
      "plugin_traffic.control_host",
      [] {
        controlHost();
      },
  };
  const telar::testing::Case case_datagram_host{
      "plugin_traffic.datagram_host",
      [] {
        datagramHost();
      },
  };
  const telar::testing::Case case_reply_rejects_out_of_bounds{"plugin_traffic.reply_rejects_out_of_bounds", replyRejectsOutOfBounds};
  const telar::testing::Case case_decisions_bounded{"plugin_traffic.decisions_bounded", decisionsBounded};
  const telar::testing::Case case_http_replace_bounded{"plugin_traffic.http_replace_bounded", httpReplaceBounded};
  const telar::testing::Case case_redirect_bounds{"plugin_traffic.redirect_bounds", redirectBounds};
  const telar::testing::Case case_worker_crash_applies_failure_policy{"plugin_traffic.worker_crash_applies_failure_policy", workerCrashAppliesFailurePolicy};
  const telar::testing::Case case_registration_limits{"plugin_traffic.registration_limits", registrationLimits};
  const telar::testing::Case case_option_validation{"plugin_traffic.option_validation", optionValidation};
  const telar::testing::Case case_exchange_event{"plugin_traffic.exchange_event", exchangeEvent};

}
