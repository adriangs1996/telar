#include "check.hpp"
#include "config/loader.hpp"
#include <filesystem>
#include <fstream>

using namespace telar::runtime;
using namespace telar;

static void writeConfig(const std::string &path, std::string_view source) {
  std::ofstream file{path};
  file << source;
  check(file.good());
}

static void testCommandTabRegistry() {
  SystemAllocator system;
  BudgetAllocator memory{system, 128 * 1024};
  {
    auto commands = makeOwned<config::CommandTabRegistry>(memory);
    config::LimitNotices limits;
    const std::array<std::string_view, 2> arguments{"echo", "value"};
    check(commands->keep(arguments, {}, limits));
    const auto saved = commands->checkpoint();
    check(commands->keep(arguments, {}, limits));
    check(commands->checkpoint().rows == saved.rows && commands->checkpoint().bytes == saved.bytes);
    check(commands->keep(arguments, "named", limits));
    check(commands->checkpoint().rows == 2);
    commands->restore(saved);
    check(commands->checkpoint().rows == 1);

    std::array<char, 16> label;
    for (std::size_t index = saved.rows; index < 768; ++index) {
      const auto length = std::snprintf(label.data(), label.size(), "%zu", index);
      check(commands->keep(arguments, {label.data(), static_cast<std::size_t>(length)}, limits));
    }
    check(!commands->keep(arguments, "excess", limits));
    check(limits.entries().size() == 1 && limits.entries()[0].name == "config.command_tab_rows");
    check(commands->keep(arguments, {}, limits));

    commands->restore(saved);
    std::array<char, 4096> bytes;
    bytes.fill('x');
    const std::array<std::string_view, 1> large{std::string_view{bytes.data(), bytes.size()}};
    for (std::size_t index = 0; index < 19; ++index) {
      const auto length = std::snprintf(label.data(), label.size(), "%zu", index);
      check(commands->keep(large, {label.data(), static_cast<std::size_t>(length)}, limits));
    }
    check(!commands->keep(large, "excess", limits));
    check(limits.entries().size() == 2 && limits.entries()[1].name == "config.command_tab_bytes");
    check(!commands->keep(large, "excess", limits) && !limits.entries()[1].requested);
    commands->restore(saved);
    check(commands->keep(large, {}, limits));
  }
  check(memory.liveBytes() == 0);
}

void testConfig() {
  testCommandTabRegistry();
  SystemAllocator system;
  BudgetAllocator memory{system, 32 * 1024 * 1024};
  std::array<char, 64> temporary{};
  std::strcpy(temporary.data(), "/tmp/telar-config-test-XXXXXX");
  check(::mkdtemp(temporary.data()) != nullptr);
  const auto root = std::filesystem::canonical(temporary.data()).string();
  const auto path = root + "/config.lua";
  writeConfig(root + "/history.lua", "module_loads = (module_loads or 0) + 1; return {output='bounded', command_filters={'hidden'}}");
  writeConfig(path, R"lua(
local telar = require('telar')
local history = require('history')
assert(history == require('history') and module_loads == 1)
return telar.config {
  api_version = 2,
  runtime = {
    history = history,
    session = {persist=false},
    engine = {command={'/bin/cat', ''}, timeout_ms=1000, idle_timeout_ms=10000},
    agents = {
      {name='custom-agent', process_names={'custom'}, display_name='Custom Agent', icon='é', attachments='ordered', command_tools={{tool='Shell',field='cmd'}}},
      {name='claude', working={'custom working phrase'}},
    },
  },
  profiles = {
    selected = {runtime = {history = {path='sub/../history.db', command_filters={'private'}, secrets_filter=false}, session={persist=true, resume_agents=false}}},
    other = {runtime = {history = {command_filters={'other-only'}}}},
  },
}
)lua");
  cli::ServerOptions options;
  options.config = path;
  options.profile = "selected";
  {
    config::RuntimeValues values{memory};
    config::Loader{memory, values}.load(options, ProcessEnvironment{});
    check(values.capture_output && values.persist_session && !values.resume_agents);
    check(std::string_view{values.history_path} == root + "/history.db" && !values.history_filters.secrets);
    check(!values.history_filters.allowsPane("hidden", "/tmp") && !values.history_filters.allowsPane("private", "/tmp"));
    check(values.history_filters.allowsPane("other-only", "/tmp"));
    check(values.engine.arguments.size() == 2 && values.engine.arguments[1].empty());
    check(values.engine.timeout == std::chrono::milliseconds{1000} && values.engine.idle_timeout == std::chrono::milliseconds{10000});
    const auto provider = values.manifests.fromExecutable("Custom.js");
    check(static_cast<unsigned>(provider) == 6);
    const auto *manifest = values.manifests.find(provider);
    check(manifest != nullptr && manifest->displayName() == "Custom Agent" && manifest->icon.view() == "é");
    check(manifest->attachments == AgentAttachmentMarkers::ordered && manifest->commandField("Shell") == "cmd");
    check(values.manifests.find(AgentProvider::claude)->working.matches("custom working phrase"));
  }
  check(memory.liveBytes() == 0);

  for (const auto source : {
           "return {api_version=2, profiles={unused={runtime={history={output='invalid'}}}}}",
           "return {api_version=2, runtime={history={command_filters={[2]='hole'}}}}",
           "return {api_version=2, runtime={engine={command={'cat'}, timeout_ms=999}}}",
           "return {api_version=1}",
           "return {api_version=2, runtime={agents={{name='custom'},{name='custom'}}}}",
           "return {api_version=2, runtime={agents={{name='Invalid'}}}}",
           "return {api_version=2, runtime={agents={{name='custom',icon='好'}}}}",
           "return {api_version=2, runtime={agents={{name='custom',icon='ab'}}}}",
           "return {api_version=2, runtime={agents={{name='custom',working={'line\\n'}}}}}",
           "return {api_version=2, plugins=false}",
           "return {api_version=2, plugins={false}}",
           "return {api_version=2, plugins={{path=''}}}",
           "return {api_version=2, plugins={{path=string.rep('x',513)}}}",
           "return {api_version=2, plugins={{path='package',enabled=1}}}",
           "return {api_version=2, plugins={{path='package',extra=true}}}",
           "return {api_version=2, profiles={unused={plugins=false}}}",
       }) {
    writeConfig(path, source);
    options.profile = {};
    bool rejected = false;
    try {
      config::RuntimeValues values{memory};
      config::Loader{memory, values}.load(options, ProcessEnvironment{});
    } catch (const std::exception &) {
      rejected = true;
    }
    check(rejected && memory.liveBytes() == 0);
  }

  writeConfig(path, R"lua(
local agents = {}
for index=1,28 do agents[index] = {name='custom'..index} end
agents[1].process_names = {string.rep('x',129),'one','two','three','four','five','six','seven','eight','ninth',false}
agents[1].working = {string.rep('x',65), 'kept'}
agents[1].command_tools = {{tool=string.rep('x',65),field='command'}, {tool='Shell',field='command'}}
agents[28].working = false
return {api_version=2, runtime={agents=agents}}
)lua");
  {
    config::RuntimeValues values{memory};
    config::Loader{memory, values}.load(options, ProcessEnvironment{});
    check(values.manifests.entries().size() == 32 && values.limits.entries().size() == 5);
    const auto *manifest = values.manifests.find(values.manifests.named("custom1"));
    check(manifest->process_names.entries().size() == 8 && manifest->working.entries().size() == 1);
    check(manifest->commandField("Shell") == "command");
    const auto reaches = values.limits.entries();
    const auto overflow = std::find_if(reaches.begin(), reaches.end(), [](const auto &reach) { return reach.name == "agent_manifest.max_paths"; });
    check(overflow != reaches.end() && overflow->requested == 10);
  }
  check(memory.liveBytes() == 0);

  writeConfig(path, R"lua(
local plugins={}
for index=1,32 do plugins[index]={path='plugin'..index,enabled=index % 2 == 0} end
plugins[33]=false
return {api_version=2,plugins=plugins,profiles={selected={plugins={{path='replacement'}}}}}
)lua");
  for (const auto selected : {std::string_view{}, std::string_view{"selected"}}) {
    options.profile = selected;
    config::RuntimeValues values{memory};
    config::Loader{memory, values}.load(options, ProcessEnvironment{});
    check(values.configuration_directory.view() == root);
    check(values.limits.entries().size() == 1 && values.limits.entries()[0].name == "plugins.max_plugins" && values.limits.entries()[0].requested == 33);
    if (selected.empty()) {
      check(values.plugins.count == 32 && values.plugins.entries[0].path.view() == "plugin1");
      check(!values.plugins.entries[0].enabled && values.plugins.entries[1].enabled);
    } else {
      check(values.plugins.count == 1 && values.plugins.entries[0].path.view() == "replacement" && values.plugins.entries[0].enabled);
    }
  }
  options.profile = {};
  check(memory.liveBytes() == 0);

  const auto outside = root + ".lua";
  writeConfig(outside, "return {api_version=2}");
  check(::symlink(outside.c_str(), (root + "/escape.lua").c_str()) == 0);
  writeConfig(path, "return require('escape')");
  bool rejected = false;
  try {
    config::RuntimeValues values{memory};
    config::Loader{memory, values}.load(options, ProcessEnvironment{});
  } catch (const lua::Error &error) {
    rejected = std::string_view{error.what()}.contains("escapes");
  }
  check(rejected && memory.liveBytes() == 0);
  std::filesystem::remove(outside);
  std::filesystem::remove_all(root);
}
