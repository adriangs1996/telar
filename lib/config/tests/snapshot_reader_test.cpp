#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <lua.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.testing.test_memory;
import telar.lua;
import telar.config.runtime;
import telar.config.gui;
import telar.wire.vocabulary;
import telar.config.snapshot;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // Reads the configuration `source` returns as the runtime does with `--profile profile`, and
  // hands the values to `inspect` when the reader accepted it. Returns whether it did.
  template <typename Inspect>
  bool readConfiguration(std::string_view source, std::string_view profile, Inspect&& inspect) {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    lua::Vm<Memory> vm{memory};
    auto values = ds::makeBox<config::RuntimeValues<Memory>>(memory, memory);

    vm.execute(source, "@config.lua");
    const lua::Value root{vm.state(), -1, "config"};

    try {
      config::SnapshotReader{memory, values.getMut()}.read(root, profile);
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

  // Each spelling of `runtime.control_queries` selects its own access or color format; a
  // clipboard read the user set to `ask` must never be read as `allow`.
  void testControlPolicyValues() {
    const auto policy = [](std::string_view table, auto&& inspect) {
      const bool read = readConfiguration(std::string{"return {api_version = 2, runtime = {control_queries = "} + std::string{table} + "}}", {}, [&](const config::RuntimeValues<Memory>& values) {
        inspect(values.control_policy);
      });

      check(read, table);
    };

    policy("{clipboard_read = 'ask', clipboard_write = 'ask', color_format = 'none'}", [](const control::Policy& read) {
      check(read.clipboard_read == control::Access::ask && read.clipboard_write == control::Access::ask);
      check(read.color_format == control::ColorFormat::none);
    });
    policy("{clipboard_read = 'deny', clipboard_write = 'deny', color_format = '8-bit'}", [](const control::Policy& read) {
      check(read.clipboard_read == control::Access::deny && read.clipboard_write == control::Access::deny);
      check(read.color_format == control::ColorFormat::eight_bit);
    });
    policy("{clipboard_read = 'allow', clipboard_write = 'allow', color_format = '16-bit'}", [](const control::Policy& read) {
      check(read.clipboard_read == control::Access::allow && read.clipboard_write == control::Access::allow);
      check(read.color_format == control::ColorFormat::sixteen_bit);
    });

    const bool defaults = readConfiguration("return {api_version = 2}", {}, [](const config::RuntimeValues<Memory>& values) {
      check(values.control_policy.clipboard_read == control::Access::ask && values.control_policy.clipboard_write == control::Access::allow);
      check(values.control_policy.color_format == control::ColorFormat::sixteen_bit);
    });

    check(defaults);
    check(!accepted("return {api_version = 2, runtime = {control_queries = {color_format = '24-bit'}}}"));
  }

  // `runtime.agent_descriptions` names the helper that describes agents: its argv and timeout,
  // within the helper bounds, and none of the engine's own fields.
  void testAgentDescriptionsHelper() {
    const bool read = readConfiguration("return {api_version = 2, runtime = {agent_descriptions = {command = {'x', 'y'}, timeout_ms = 2000}}}", {}, [](const config::RuntimeValues<Memory>& values) {
      const auto words = values.descriptions.views();

      check(words.count == 2 && words.span()[0] == "x" && words.span()[1] == "y");
      check(values.descriptions.timeout == std::chrono::seconds{2});
    });

    check(read);
    check(!accepted("return {api_version = 2, runtime = {agent_descriptions = {command = {'x'}, idle_timeout_ms = 10000}}}"));
    check(!accepted("local command = {} for i = 1, 33 do command[i] = 'a' end return {api_version = 2, runtime = {agent_descriptions = {command = command}}}"));
    check(!accepted("return {api_version = 2, runtime = {agent_descriptions = {command = {''}}}}"));
    check(!accepted("return {api_version = 2, runtime = {agent_descriptions = {command = {string.rep('a', 2048), string.rep('b', 2049)}}}}"));
    check(accepted("local command = {} for i = 1, 32 do command[i] = 'a' end return {api_version = 2, runtime = {agent_descriptions = {command = command}}}"));
    check(accepted("return {api_version = 2, runtime = {agent_descriptions = {command = {string.rep('a', 2048), string.rep('b', 2048)}}}}"));
  }

  // A configured agent's screen phrases decide its status: its working phrase reads as working,
  // and a screen that also asks for approval reads as blocked.
  void testConfiguredAgentScreenDetection() {
    const bool read = readConfiguration("return {api_version = 2, runtime = {agents = {{name = 'custom', working = {'pondering deeply'}, blocked = {'approve this step?'}}}}}", {}, [](const config::RuntimeValues<Memory>& values) {
      const auto working = values.manifests.detect("~ pondering deeply (3s)");
      const auto blocked = values.manifests.detect("~ pondering deeply (3s)\napprove this step? [y/n]");

      check(working.hasValue() && working->status == AgentStatus::working);
      check(blocked.hasValue() && blocked->status == AgentStatus::blocked);
      check(!values.manifests.detect("an idle shell prompt $").hasValue());
    });

    check(read);
  }

  // Every theme color is six hexadecimal digits: the reader refuses a malformed one instead of
  // reading it as some other color, and `theme` and its alias `client.theme` exclude each other.
  void testThemeRejectsMalformedColors() {
    constexpr std::string_view palette = "local function palette(count) local list = {} for i = 1, count do list[i] = '#102030' end return list end ";

    const auto withPalette = [&](std::string_view body) {
      return std::string{palette} + std::string{body};
    };

    check(!accepted(withPalette("return {api_version = 2, theme = {terminal = {palette = palette(15)}}}")));
    check(!accepted(withPalette("return {api_version = 2, theme = {terminal = {palette = palette(17)}}}")));
    check(accepted(withPalette("return {api_version = 2, theme = {terminal = {palette = palette(16)}}}")));
    check(!accepted("return {api_version = 2, theme = {colors = {accent = '#12345g'}}}"));
    check(accepted("return {api_version = 2, theme = {colors = {accent = '#12345f'}}}"));
    check(!accepted("return {api_version = 2, theme = {terminal = {foreground = 'default'}}}"));
    check(accepted("return {api_version = 2, theme = {colors = {accent = 'default'}}}"));
    check(!accepted("return {api_version = 2, theme = 'shade', client = {theme = 'shade'}}"));
    check(accepted("return {api_version = 2, theme = 'shade'}"));
    check(accepted("return {api_version = 2, client = {theme = 'shade'}}"));
  }

  // `gui.window.background_blur` is either a switch or a radius in 0..255.
  void testGuiBackgroundBlur() {
    const auto window = [](std::string_view blur) {
      telar::testing::TestMemory memory;
      lua::Vm<Memory> vm{memory};

      vm.execute(std::string{"return {window = {background_blur = "} + std::string{blur} + "}}", "@gui.lua");
      return config::GuiReader::read(lua::Value{vm.state(), -1, "gui"}).window;
    };

    const auto on = window("true");

    check(on.blur == true && !on.blur_radius.hasValue());
    const auto radius = window("12");

    check(radius.blur_radius == std::uint8_t{12} && !radius.blur.hasValue());
    check(!accepted("return {api_version = 2, gui = {window = {background_blur = 300}}}"));
    check(accepted("return {api_version = 2, gui = {window = {background_blur = 255}}}"));
  }

  const telar::testing::Case case_binding_keys{"snapshot.binding_rejects_too_many_keys", testBindingRejectsTooManyKeys};
  const telar::testing::Case case_history_filters{"snapshot.history_filter_bounds", testHistoryFilterBounds};
  const telar::testing::Case case_answerback{"snapshot.control_answerback_bound", testControlAnswerbackBound};
  const telar::testing::Case case_selected_profile{"snapshot.selected_profile_must_exist", testSelectedProfileMustExist};
  const telar::testing::Case case_control_policy{"snapshot.control_policy_values", testControlPolicyValues};
  const telar::testing::Case case_agent_descriptions{"snapshot.agent_descriptions_helper", testAgentDescriptionsHelper};
  const telar::testing::Case case_agent_screen{"snapshot.configured_agent_screen_detection", testConfiguredAgentScreenDetection};
  const telar::testing::Case case_theme_colors{"snapshot.theme_rejects_malformed_colors", testThemeRejectsMalformedColors};
  const telar::testing::Case case_gui_blur{"snapshot.gui_background_blur", testGuiBackgroundBlur};

}
