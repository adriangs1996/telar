#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <lua.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.lua;
import telar.config.core;
import telar.config.runtime;
import telar.config.snapshot;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // Reads the configuration `source` returns as the runtime does with `--profile profile`, and
  // hands the values to `inspect` when the reader accepted it. Returns whether it did.
  template <typename Inspect>
  bool readConfiguration(std::string_view source, std::string_view profile, Inspect&& inspect) {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;
    lua::Vm<Memory> vm{memory};
    const auto values = makeOwned<config::RuntimeValues<Memory>>(memory, memory);

    vm.execute(source, "@config.lua");
    const lua::Value root{vm.state(), -1, "config"};

    try {
      config::SnapshotReader{memory, *values}.read(root, profile);
    } catch (const std::exception&) {
      return false;
    }

    inspect(*values);
    return true;
  }

  bool accepted(std::string_view source, std::string_view profile = {}) {
    return readConfiguration(source, profile, [](const config::RuntimeValues<Memory>&) {});
  }

  // A binding holds at most five keys, the prefix counting as one: the reader refuses more
  // instead of writing past BindingSetting::keys.
  void testBindingRejectsTooManyKeys() {
    check(!accepted("local keys = {'a','b','c','d','e','f'} return {api_version = 2, client = {keybindings = {{keys = keys, action = function() end, expression = false, prefixed = false}}}}"));
    check(!accepted("local keys = {'a','b','c','d','e'} return {api_version = 2, client = {keybindings = {{keys = keys, action = function() end, expression = false, prefixed = true}}}}"));
    check(accepted("local keys = {'a','b','c','d','e'} return {api_version = 2, client = {keybindings = {{keys = keys, action = function() end, expression = false, prefixed = false}}}}"));
    check(accepted("local keys = {'a','b','c','d'} return {api_version = 2, client = {keybindings = {{keys = keys, action = function() end, expression = false, prefixed = true}}}}"));
  }

  // History command filters are a fixed list of 64 patterns of at most 256 bytes; a
  // configuration past either bound, root and selected profile together, is refused.
  void testHistoryFilterBounds() {
    constexpr std::string_view patterns = "local function patterns(count, prefix) local list = {} for i = 1, count do list[i] = prefix .. i .. ';' end return list end ";

    const auto filters = [&](std::string_view body) {
      return std::string{patterns} + std::string{body};
    };

    check(!accepted(filters("return {api_version = 2, runtime = {history = {command_filters = patterns(65, 'p')}}}")));
    check(!accepted(filters("return {api_version = 2, runtime = {history = {command_filters = patterns(40, 'p')}}, profiles = {chosen = {runtime = {history = {command_filters = patterns(30, 'q')}}}}}"), "chosen"));
    check(!accepted("return {api_version = 2, runtime = {history = {command_filters = {string.rep('x', 257)}}}}"));
    check(!accepted("return {api_version = 2, runtime = {history = {command_filters = {''}}}}"));

    const bool read = readConfiguration(filters("return {api_version = 2, runtime = {history = {command_filters = patterns(64, 'p')}}}"), {}, [](const config::RuntimeValues<Memory>& values) {
      check(!values.history_filters.allowsPane("run p64; now", "/"));
      check(values.history_filters.allowsPane("unrelated", "/"));
    });

    check(read);
    check(accepted("return {api_version = 2, runtime = {history = {command_filters = {string.rep('x', 256)}}}}"));
  }

  // The answerback reply is a 1024-byte buffer of the control policy.
  void testControlAnswerbackBound() {
    check(!accepted("return {api_version = 2, runtime = {control_queries = {answerback = string.rep('a', 1025)}}}"));

    const bool read = readConfiguration("return {api_version = 2, runtime = {control_queries = {answerback = string.rep('a', 1024)}}}", {}, [](const config::RuntimeValues<Memory>& values) {
      check(values.control_policy.answerback_length == 1024);
      check(std::string_view{values.control_policy.answerback.data(), values.control_policy.answerback_length} == std::string(1024, 'a'));
    });

    check(read);
  }

  // `--profile` names a profile the configuration defines, with a name that is a safe key.
  void testSelectedProfileMustExist() {
    check(!accepted("return {api_version = 2, profiles = {a = {}}}", "missing"));
    check(!accepted("return {api_version = 2}", "x"));
    check(!accepted("return {api_version = 2, profiles = {a = {}}}", "../x"));
    check(!accepted("return {api_version = 2, profiles = {a = {}}}", std::string(65, 'a')));
    // The selected name is copied into a 65-byte buffer only once it is known to fit.
    check(!accepted("return {api_version = 2, profiles = {a = {}}}", std::string(4096, 'a')));
    check(!accepted("return {api_version = 2, profiles = {['bad name'] = {}}}"));
    check(accepted("return {api_version = 2, profiles = {a = {}}}", "a"));
    check(accepted(std::string{"return {api_version = 2, profiles = {"} + std::string(64, 'a') + " = {}}}", std::string(64, 'a')));
  }

  const telar::testing::Case case_binding_keys{"snapshot.binding_rejects_too_many_keys", testBindingRejectsTooManyKeys};
  const telar::testing::Case case_history_filters{"snapshot.history_filter_bounds", testHistoryFilterBounds};
  const telar::testing::Case case_answerback{"snapshot.control_answerback_bound", testControlAnswerbackBound};
  const telar::testing::Case case_selected_profile{"snapshot.selected_profile_must_exist", testSelectedProfileMustExist};

}
