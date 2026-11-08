#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstddef>
#include <arpa/inet.h>
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <cstring>
#include <cmath>
#include <cstdio>

import std;
import telar.base.memory;
import telar.runtime.tests.check;
import telar.config;
import telar.lua;

using namespace telar;
using namespace telar::runtime;

void testProxyAuthentication();

template <Allocator Memory>
static void readProxy(Memory &memory, ProxyOptions<Memory> &options, std::string_view source) {
  lua::Vm vm{memory};
  vm.execute(source, "@proxy-test");
  config::ProxyReader<Memory>::read(lua::Value{vm.state(), -1, "config.runtime.proxy"}, options);
}

static void testHosts(SystemAllocator &memory) {
  ProxyHostPolicy policy{memory};
  check(!policy.contains("example.com"));
  for (const auto pattern : {"Example.COM", "api.example.net", "*.EXAMPLE.NET", "*.deep.example.net", "example.com"}) {
    check(policy.append(pattern));
  }
  policy.finish();
  check(policy.patterns().size() == 4);
  for (const auto hostname : {"example.com", "EXAMPLE.COM", "api.example.net", "a.b.example.net", "deep.example.net", "c.deep.example.net"}) {
    check(policy.contains(hostname));
  }
  for (const auto hostname : {"", "example.net", "evil-example.net", "example.com.evil.net", "another.net"}) {
    check(!policy.contains(hostname));
  }

  check(policy.append("*"));
  policy.finish();
  check(policy.contains("anything") && !policy.contains(""));
  policy.clear();
  for (const auto rejected : {"", "*.", "**", "a.*.example.com", ".example", "a..example", "a.", "-a.example", "a-.example", "a.example-", "a_example", "https://example.com", "a:443", "a\nb"}) {
    check(!policy.append(rejected));
  }
  check(!policy.append(std::string(64, 'a') + ".example"));
  const auto longest = std::string(63, 'a') + "." + std::string(63, 'b') + "." + std::string(63, 'c') + "." + std::string(61, 'd');
  check(longest.size() == 253 && policy.append(longest) && !policy.append(longest + "x"));
  policy.clear();
  for (std::size_t index = 0; index < 256; ++index) {
    check(policy.append("host" + std::to_string(index) + ".example"));
  }
  check(!policy.append("overflow.example"));
  policy.finish();
  check(policy.contains("HOST255.EXAMPLE"));
}

void testProxyPolicy() {
  testProxyAuthentication();
  SystemAllocator system;
  testHosts(system);
  BudgetAllocator memory{system, 1024 * 1024};
  {
    ProxyOptions options{memory};
    readProxy(memory, options, "return {enabled=true,anonymous_tunnels=true,ca_dir='relative/authority',intercept_hosts={'*.Example.com','API.example.org','api.example.org'},capture={enabled=true,max_part_bytes='1',max_exchange_bytes=2,max_total_bytes=3,join_timeout_ms=1}}");
    check(options.enabled && options.anonymous_tunnels && options.authority_directory == "relative/authority");
    check(options.intercept_hosts.patterns().size() == 2 && options.intercept_hosts.contains("sub.example.com"));
    check(options.capture.enabled && options.capture.part_bytes == 1 && options.capture.exchange_bytes == 2 && options.capture.total_bytes == 3 && options.capture.join_timeout == std::chrono::milliseconds{1});

    auto overlay = options;
    readProxy(memory, overlay, "return {enabled=false,intercept_hosts={},capture={max_total_bytes=4}}");
    check(!overlay.enabled && overlay.intercept_hosts.patterns().empty() && overlay.capture.total_bytes == 4);
    check(options.enabled && options.intercept_hosts.patterns().size() == 2 && options.capture.total_bytes == 3);
    readProxy(memory, options, "return {capture={max_part_bytes=67108864,max_exchange_bytes=67108864,max_total_bytes=1073741824,join_timeout_ms=3600000}}");
    check(options.capture.join_timeout == std::chrono::hours{1});
  }
  check(memory.liveBytes() == 0);

  for (const auto expression : {"false", "{enabled=1}", "{anonymous_tunnels='yes'}", "{unknown=true}", "{ca_dir=''}", "{ca_dir='a\\0b'}", "{ca_dir=string.rep('a',1025)}", "{intercept_hosts=true}", "{intercept_hosts={[2]='example.com'}}", "{intercept_hosts={'a..b'}}", "{capture=false}", "{capture={enabled='yes'}}", "{capture={max_part_bytes=0}}", "{capture={max_part_bytes=2.5}}", "{capture={max_part_bytes=math.huge}}", "{capture={max_exchange_bytes=1}}", "{capture={max_exchange_bytes=67108865}}", "{capture={max_total_bytes=1073741825}}", "{capture={join_timeout_ms=3600001}}", "{capture={max_total_bytes=1}}", "{capture={bytes=1}}"}) {
    bool rejected = false;
    try {
      ProxyOptions options{memory};
      readProxy(memory, options, std::string{"return "} + expression);
    } catch (const lua::Error &) {
      rejected = true;
    }
    check(rejected && memory.liveBytes() == 0);
  }
}
