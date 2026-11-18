#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.platform.paths;
import telar.config.core;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  struct TestEnvironment final : EnvironmentSource {
    using Values = ds::Array<std::pair<std::string_view, std::string_view>, 4>;

    explicit TestEnvironment(const Values& entries = {}) noexcept
        : values(entries) {}

    Values values{};

    std::string_view lookup(const char* name) const noexcept override {
      for (const auto& [key, value] : values) {
        if (key == name) {
          return value;
        }
      }

      return {};
    }
  };

  std::string root(AgentProvider provider, const TestEnvironment& environment, bool legacy = false) {
    SystemAllocator system;
    MemoryAdapter memory{system};

    return std::string{config::IntegrationProvider::describe(provider).root(memory, environment, legacy)};
  }

  // `telar integration` writes its hooks under the directory each agent reads them from: the
  // agent's own override when set, else its directory under HOME.
  void testProviderRoots() {
    const TestEnvironment overrides{{{{"HOME", "/home/user"}, {"CLAUDE_CONFIG_DIR", "/c"}, {"XDG_CONFIG_HOME", "/x"}}}};

    check(root(AgentProvider::claude, overrides) == "/c");
    check(root(AgentProvider::claude, overrides, true) == "/home/user/.claude");
    check(root(AgentProvider::opencode, overrides) == "/x/opencode");
    check(root(AgentProvider::cursor, overrides) == "/home/user/.cursor");

    const TestEnvironment home{{{{"HOME", "/home/user"}}}};

    check(root(AgentProvider::claude, home) == "/home/user/.claude");
    check(root(AgentProvider::opencode, home) == "/home/user/.config/opencode");

    bool refused = false;

    try {
      static_cast<void>(root(AgentProvider::claude, TestEnvironment{}));
    } catch (const std::invalid_argument&) {
      refused = true;
    }

    check(refused);
  }

  const telar::testing::Case case_provider_roots{"integration_provider.roots", testProviderRoots};

}
