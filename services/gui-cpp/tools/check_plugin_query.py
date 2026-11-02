"""Compare bounded plugin catalog pages with extracted original Zig procedures."""
from pathlib import Path
import argparse,hashlib,json,os,random,subprocess

cpp_probe = r"""#include "core/memory.hpp"
#include "config/plugin_query.hpp"
#include "config/plugin_overrides.hpp"
#include "tests/json_fixture.hpp"
#include "text/json.hpp"
#include <array>
#include <charconv>
#include <iostream>
#include <limits>
#include <string>

using namespace telar::gui;
using telar::runtime::JsonValue;
using test::requiredJsonField;
namespace plugins = telar::runtime::plugins;

template <typename Number>
Number number(const JsonValue &request, std::string_view field) {
  const auto text = requiredJsonField(request, field).encoded();
  Number result{};
  const auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
  if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
    throw std::runtime_error{"Invalid fixture number"};
  }

  return result;
}

std::string string(const JsonValue &request, std::string_view field) {
  SystemAllocator memory;
  String<SystemAllocator> text{AllocatorRef<char, SystemAllocator>{memory}};
  requiredJsonField(request, field).string(text);

  return {text.data(), text.size()};
}

void run(const JsonValue &request) {
  std::array<plugins::ConfiguredPlugin, plugins::PackageLimits::configured> specifications{};
  std::array<plugins::Package, plugins::PackageLimits::configured> packages{};
  const auto count = number<std::size_t>(request, "count");
  const auto mask = number<std::uint64_t>(request, "disabled_mask");
  const auto prefix = string(request, "prefix");
  std::size_t loaded = 0;
  for (std::size_t index = 0; index < count; ++index) {
    auto &spec = specifications[index];
    spec.path.assign(prefix + std::to_string(index));
    spec.enabled = (mask & (std::uint64_t{1} << index)) == 0;
    if (!spec.enabled) {
      continue;
    }

    auto &package = packages[loaded++];
    auto &manifest = package.manifest;
    manifest.id.assign("id-" + std::to_string(index));
    manifest.version.assign("1.2");
    manifest.entry.assign("main.lua");
    manifest.source.assign("fixture \"中\"\n");
    manifest.revision.assign("rev\\x");
    manifest.action_count = number<std::size_t>(request, "actions");
    for (std::size_t action = 0; action < manifest.action_count; ++action) {
      manifest.actions[action].assign("action-" + std::to_string(action));
    }

    const auto capabilities = number<unsigned>(request, "capabilities");
    for (unsigned bit = 0; bit <= static_cast<unsigned>(plugins::Capability::runtime_control); ++bit) {
      if ((capabilities & (1U << bit)) != 0) {
        manifest.capabilities.insert(static_cast<plugins::Capability>(bit));
      }
    }

    const auto seed = number<unsigned>(request, "digest_seed");
    for (std::size_t byte = 0; byte < package.digest.size(); ++byte) {
      package.digest[byte] = static_cast<std::uint8_t>(seed + index + byte);
    }
  }

  const auto name = string(request, "name");
  const telar::ClientCommand command{.target_id = number<std::uint64_t>(request, "target"), .value = number<std::int64_t>(request, "page"), .text = name};
  PluginOverrides overrides;
  if (const auto requested = request.field("requested")) {
    for (const auto &specification : std::span{specifications}.first(count)) {
      auto desired = specification;
      desired.enabled = requested->boolean();
      overrides.set(desired, std::nullopt);
    }
  }

  const PluginCatalog catalog{number<std::uint64_t>(request, "generation"), std::span{specifications}.first(count), std::span{packages}.first(loaded), &overrides};
  std::array<char, 4096> output{};
  std::array<char, 32768> envelope{};
  JsonWriter writer{envelope};
  try {
    const auto result = number<unsigned>(request, "mode") == 0 ? PluginQuery::list(catalog, command, output) : PluginQuery::get(catalog, command, output);
    writer.object([&](JsonWriter &object) {
      object.member("value", result.next);
      object.member("text", result.text);
    });
  } catch (const std::exception &error) {
    writer.object([&](JsonWriter &object) {
      object.member("error", error.what());
    });
  }

  std::cout << writer.view() << '\n';
}

int main() {
  for (std::string line; std::getline(std::cin, line);) {
    run(JsonValue::parse(line));
  }
}
"""

def records():
    default=dict(generation=42,target=0,mode=0,name='',page=0,count=3,disabled_mask=1,prefix='path-',actions=2,capabilities=2047,digest_seed=0)
    for count in (0,1,2,31,32):
        for mask in (0,1,0x55555555,0xffffffff):
            for generation in (0,1,42,2**64-1):
                for mode in (0,1):
                    for page in (-2**63,-1,0,1,2,31,32,33,2**63-1):
                        yield dict(default,count=count,disabled_mask=mask,generation=generation,mode=mode,page=page,name='id-1')
    rng=random.Random(0x504c5547)
    for index in range(1500):
        count=rng.randrange(33);mask=rng.getrandbits(32);generation=rng.getrandbits(64);prefix=rng.choice(('path-','配置-','quoted"\\-','line\n-','\0-','\x01'*500));selected=rng.randrange(max(1,count));name=rng.choice((prefix+str(selected),'id-'+str(selected),'missing',''))
        yield dict(default,count=count,disabled_mask=mask,generation=generation,target=rng.choice((0,generation,(generation+1)%(2**64))),mode=rng.randrange(2),page=rng.choice((-1,0,1,2,31,32,63,64,65)),name=name,prefix=prefix,actions=rng.choice((0,1,2,63,64)),capabilities=rng.randrange(2048),digest_seed=rng.randrange(256))

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--compiler',default='clang++');p.add_argument('--zig',default='zig');p.add_argument('--output',type=Path,required=True);p.add_argument('--sanitize',action='store_true');p.add_argument('--pending',action='store_true',help='Compare requested/adopted activation states too');a=p.parse_args();repo=Path(__file__).resolve().parents[3];out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);tools=repo/'services/gui-cpp/tools';source=repo/'src/client/plugins/plugin_actions.zig';catalog=repo/'src/client/plugins/ConfiguredPlugins.zig';original=source.read_text();start=original.index('pub fn listPlugins(');end=original.index('\npub fn setPluginEnabled(',start);queries=original[start:end];catalog_body=catalog.read_text().split('const Catalog = @This();',1)[1];assert queries.count('pub fn ')==2 and 'writeAll("]}")' in queries and 'loaded < self.registry.count' in catalog_body
    zig=(tools/'plugin_query_reference.zig.in').read_text().replace('__CATALOG__',catalog_body).replace('__QUERIES__',queries);(out/'reference.zig').write_text(zig);(out/'probe.cpp').write_text(cpp_probe);commands=[]
    def run(command,name,**kwargs):
        with (out/(name+'.log')).open('wb') as log:r=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,**kwargs)
        commands.append(dict(command=command,actual_exit=r.returncode));(out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n');r.check_returncode()
    cpp=[a.compiler,'-std=c++23','-O2','-DTELAR_DIAGNOSTICS=0','-I',str(repo/'services/gui-cpp'),'-I',str(repo/'services/runtime-cpp'),'-I',str(repo/'dlls/telar-client/include'),str(out/'probe.cpp'),'-o',str(out/'candidate')]
    if a.sanitize:cpp.extend(['-g','-fsanitize=address,undefined','-fno-omit-frame-pointer'])
    run(cpp,'candidate-build');run([a.zig,'build-exe','-O','ReleaseSafe','-lc','--dep','plugin','-Mroot='+str(out/'reference.zig'),'-Mplugin='+str(repo/'src/core/plugin.zig'),'-femit-bin='+str(out/'reference')],'reference-build')
    cases=list(records())
    if a.pending:
        baseline=tuple(cases)
        cases.extend(dict(case,requested=value) for value in (False,True) for case in baseline)
    payload=''.join(json.dumps(r,ensure_ascii=True,separators=(',',':'))+'\n' for r in cases).encode();(out/'input.jsonl').write_bytes(payload);results={};env=dict(os.environ,ASAN_OPTIONS='detect_leaks=1',UBSAN_OPTIONS='halt_on_error=1');env.pop('LSAN_OPTIONS',None)
    for name in ('reference','candidate'):
        r=subprocess.run([str(out/name)],input=payload,capture_output=True,env=env);(out/(name+'-output.jsonl')).write_bytes(r.stdout);(out/(name+'-stderr.log')).write_bytes(r.stderr);results[name]=dict(actual_exit=r.returncode,binary_sha256=hashlib.sha256((out/name).read_bytes()).hexdigest());r.check_returncode()
    left=(out/'reference-output.jsonl').read_bytes().splitlines();right=(out/'candidate-output.jsonl').read_bytes().splitlines();assert len(left)==len(right)==len(cases);bad=[dict(index=i,request=c,reference=json.loads(x),candidate=json.loads(y)) for i,(c,x,y) in enumerate(zip(cases,left,right)) if json.loads(x)!=json.loads(y)];report=dict(candidate_source_sha256=hashlib.sha256(cpp_probe.encode()).hexdigest(),records=len(cases),differences=len(bad),first_differences=bad[:20],binaries=results,sanitize=a.sanitize,pending=a.pending,source_sha256={str(q.relative_to(repo)):hashlib.sha256(q.read_bytes()).hexdigest() for q in (source,catalog,Path(__file__),tools/'plugin_query_reference.zig.in',repo/'services/gui-cpp/config/plugin_overrides.hpp',repo/'services/gui-cpp/config/plugin_catalog.hpp',repo/'services/gui-cpp/config/plugin_query.hpp')});(out/'result.json').write_text(json.dumps(report,indent=2)+'\n');print(report['records'],'queries,',report['differences'],'differences');return int(bool(bad))
if __name__=='__main__':raise SystemExit(main())
