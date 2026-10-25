#include "check.hpp"
#include "plugins/host.hpp"
#include <filesystem>
#include <fstream>

using namespace telar;
using namespace telar::runtime;
namespace tap = telar::runtime::plugins;

static void writePlugin(const std::string &path, std::string_view source) {
  std::ofstream file{path};
  file << source;
  check(file.good());
}

static tap::ExchangeView sampleExchange() {
  static constexpr std::string_view head = ":method: POST\r\n: path \t:  /resource \t\r\nignored\r\nx-key: one\r\nx-key: two\r\n";
  static constexpr std::string_view body = "{\"value\":4}";
  const tap::HalfView request{
      .head = {reinterpret_cast<const Byte *>(head.data()), head.size()},
      .body = {reinterpret_cast<const Byte *>(body.data()), body.size()},
      .encoding = "gzip",
      .decoded = true,
      .body_truncated = true,
      .status_code = 0,
      .outcome = CaptureOutcome::finished,
      .finished_at_ms = 121,
  };
  auto response = request;
  response.status_code = 503;
  response.outcome = CaptureOutcome::failed;
  response.finished_at_ms = 123;
  return {
      .identity = {21, 8},
      .protocol = tap::ExchangeProtocol::h2,
      .key = {31, 5},
      .host = "example.test",
      .method = "POST",
      .target = "/resource",
      .started_at_ms = 100,
      .request = request,
      .response = response,
  };
}

void testPluginHost() {
  SystemAllocator system;
  BudgetAllocator memory{system, 80 * 1024 * 1024};
  std::array<char, 64> temporary;
  std::strcpy(temporary.data(), "/tmp/telar-plugin-host-XXXXXX");
  check(::mkdtemp(temporary.data()) != nullptr);
  const auto root = std::filesystem::canonical(temporary.data()).string();
  const auto path = root + "/main.lua";
  std::array<Byte, tap::Limits::effect_bytes> output;
  auto exchange = sampleExchange();

  writePlugin(root + "/helper.lua", "loads = (loads or 0) + 1; return {value = 73}");
  writePlugin(path, R"lua(
local telar = require('telar')
assert(require('helper') == require('helper') and loads == 1)
assert(io == nil and os == nil and debug == nil and package == nil)
assert(load == nil and loadfile == nil and dofile == nil and print == nil)
assert(getmetatable == nil and setmetatable == nil and rawset == nil)
local called = 0
return {on_exchange = function(exchange)
  called = called + 1
  assert(exchange.id == 21 and exchange.connection_id == 31 and exchange.stream_id == 5)
  assert(exchange.protocol == 'h2' and exchange.host == 'example.test')
  assert(exchange.method == 'POST' and exchange.target == '/resource')
  assert(exchange.status == 503 and exchange.outcome == 'failed')
  assert(exchange.started_at_ms == 100 and exchange.finished_at_ms == 123)
  assert(exchange.request.body_encoding == 'gzip' and exchange.request.body_decoded)
  assert(exchange.request.body_truncated and telar.json.decode(exchange.request.body).value == 4)
  local fields = exchange.request.head.fields
  assert(fields[1].name == ':method' and fields[1].value == 'POST')
  assert(fields[2].name == ': path' and fields[2].value == '/resource')
  assert(fields[3].name == 'x-key' and fields[4].value == 'two' and fields[5] == nil)
  for _, mutate in ipairs({
    function() exchange.host = 'other' end,
    function() exchange.request.body = 'other' end,
    function() exchange.request.head.raw = 'other' end,
    function() fields[1] = {} end,
    function() fields[1].name = 'other' end,
  }) do
    local ok, err = pcall(mutate)
    assert(not ok and err == 'exchange is immutable')
  end
  assert(telar.redact.secrets('token=private') == '[REDACTED]')
  assert(telar.redact.secrets(123) == '123')
  return {telar.effect.notification{title = called, message = 'binary\0text', level = 'warning', duration_ms = '123'}}
end}
)lua");
  {
    tap::Host host{memory, path.c_str()};
    for (int index = 1; index <= 50; ++index) {
      const auto reply = tap::Protocol::decodeEffects(host.invoke(exchange, output));
      check(reply.event_id == 21 && reply.batch.count == 1);
      const auto &notification = reply.batch.notifications[0];
      check(notification.title == std::to_string(index) && notification.message == std::string_view{"binary\0text", 11});
      check(notification.level == NotificationLevel::warning && notification.duration_ms == 123);
    }
  }
  check(memory.liveBytes() == 0);

  writePlugin(path, "local first = true; return {on_exchange = function() if first then first = false; error(string.rep('x', 5000), 0) end return {} end}");
  {
    tap::Host host{memory, path.c_str()};
    const auto error = tap::Protocol::decodeError(host.invoke(exchange, output));
    check(error.message == "unknown Lua error");
    check(tap::Protocol::decodeEffects(host.invoke(exchange, output)).batch.count == 0);
  }

  for (const auto result : {"nil", "{}", "{extra=true}"}) {
    writePlugin(path, std::string{"return {on_exchange = function() return "} + result + " end}");
    tap::Host host{memory, path.c_str()};
    check(tap::Protocol::decodeEffects(host.invoke(exchange, output)).batch.count == 0);
  }
  for (const auto result : {"true", "{{}}", "{telar.effect.notification{title='x',level='invalid'}}", "{telar.effect.notification{title=false}}"}) {
    writePlugin(path, std::string{"return {on_exchange = function() return "} + result + " end}");
    tap::Host host{memory, path.c_str()};
    const auto error = tap::Protocol::decodeError(host.invoke(exchange, output));
    check(error.event_id == 21 && error.message == "unknown Lua error");
  }

  writePlugin(path, "local first = true; return {on_exchange=function() if first then first=false; while true do end end return nil end}");
  {
    tap::Host host{memory, path.c_str()};
    check(tap::Protocol::decodeError(host.invoke(exchange, output)).message == "unknown Lua error");
    check(tap::Protocol::decodeEffects(host.invoke(exchange, output)).batch.count == 0);
  }

  writePlugin(path, "return {on_exchange=function() return {telar.effect.notification{title=string.rep('x', 65536)}} end}");
  {
    tap::Host host{memory, path.c_str()};
    bool rejected = false;
    try {
      host.invoke(exchange, output);
    } catch (const EncodingError &) {
      rejected = true;
    }
    check(rejected);
  }

  for (int index = 1; index <= 65; ++index) {
    writePlugin(root + "/module" + std::to_string(index) + ".lua", "return nil");
  }
  writePlugin(path, "for i=1,65 do assert(require('module'..i) == true) end return {on_exchange=function() return nil end}");
  {
    tap::Host host{memory, path.c_str()};
    check(tap::Protocol::decodeEffects(host.invoke(exchange, output)).batch.count == 0);
  }
  check(memory.liveBytes() == 0);
  std::filesystem::remove_all(root);
}
