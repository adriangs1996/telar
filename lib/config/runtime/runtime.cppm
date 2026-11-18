module;
#include "telar_config/terminal/control/policy.hpp"

export module telar.config.runtime;

import std;
import telar.tbc;
import telar.config.core;
import telar.plugins;
import telar.platform.events;
import telar.base.text;
import telar.wire.vocabulary;
import telar.sys.posix;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.lua;
import telar.base.ds;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::runtime::control {
  using telar::runtime::control::Access;
  using telar::runtime::control::ColorFormat;
  using telar::runtime::control::Policy;
}

// Interface: telar_config/agents/evidence.cppm
export {
  namespace telar::runtime {

    struct AgentSignal {
      AgentProvider provider = AgentProvider::unknown;
      AgentStatus status = AgentStatus::unknown;
      Byte confidence = 0;
      bool identity_confirmed = false;
      bool ready_confirmed = false;

      bool operator==(const AgentSignal&) const = default;
    };

    struct AgentEvidence {
      AgentProvider provider = AgentProvider::unknown;
      AgentStatus status = AgentStatus::unknown;
      AgentSource source = AgentSource::screen;
      Byte confidence = 0;
      ObservationTime observed;
      std::int64_t expires_at = 0;

      bool expired(std::int64_t now) const noexcept;
      static AgentEvidence process(AgentProvider provider, ObservationTime now) noexcept;
      static AgentEvidence screen(AgentProvider provider, AgentSignal signal, ObservationTime now) noexcept;
      static AgentEvidence report(AgentProvider provider, AgentReportState state, ObservationTime now) noexcept;

      static constexpr std::chrono::milliseconds screen_working_expiry{120'000};
      static constexpr std::chrono::milliseconds report_working_expiry{600'000};
      static constexpr std::chrono::milliseconds settled_expiry{1'800'000};
      static constexpr std::chrono::milliseconds renewal_margin{300'000};
    };

    bool completionRequiresSignal(AgentProvider provider) noexcept;

  }
}

// Interface: telar_config/agents/manifest.cppm
export {
  namespace telar::runtime {

    bool containsInsensitive(std::string_view text, std::string_view phrase) noexcept;

    template <std::size_t Capacity, std::size_t TextCapacity>
    class ManifestTextList {
    public:
      void append(std::string_view text);
      bool matches(std::string_view text) const noexcept;
      std::span<const FixedText<TextCapacity>> entries() const noexcept;

    private:
      ds::Array<FixedText<TextCapacity>, Capacity> entries_;
      std::size_t count_ = 0;
    };

    enum class AgentInterruptKey {
      none,
      escape,
      escape_twice,
      control_c,
    };

    struct AgentCommandTool {
      FixedText<64> tool;
      FixedText<32> field;
    };

    struct AgentManifest {
      void addCommandTool(std::string_view name, std::string_view field);
      std::string_view commandField(std::string_view tool) const noexcept;
      std::string_view displayName() const noexcept;

      // The manifest's own placeholder, or one built in the caller's storage.
      tbc::view<std::string_view, tbc::lt::a> placeholderTitle(tbc::view<FixedText<96>&, tbc::lt::a> storage) const;

      AgentProvider provider = AgentProvider::unknown;
      tbc::view<FixedText<32>, tbc::lt::a> name;
      tbc::view<FixedText<32>, tbc::lt::a> display_name;
      tbc::view<FixedText<96>, tbc::lt::a> placeholder;
      FixedText<8> icon;
      AgentAttachmentMarkers attachments = AgentAttachmentMarkers::none;
      AgentInterruptKey interrupt = AgentInterruptKey::none;
      ManifestTextList<8, 128> process_names;
      ManifestTextList<8, 128> process_paths;
      ManifestTextList<16, 64> brand;
      ManifestTextList<16, 64> identity;
      ManifestTextList<16, 64> working;
      ManifestTextList<16, 64> blocked;
      ManifestTextList<16, 64> ready_prompt;
      ds::Array<AgentCommandTool, 8> command_tools;
      std::size_t tool_count = 0;
    };

    class AgentManifests {
    public:
      AgentManifest& add(std::string_view name);
      AgentManifest* tryAdd(std::string_view name);
      const AgentManifest* find(AgentProvider provider) const noexcept;
      AgentProvider named(std::string_view name) const noexcept;
      AgentProvider fromExecutable(std::string_view name) const noexcept;
      AgentProvider fromPath(std::string_view path) const noexcept;
      ds::Option<AgentSignal> detect(std::string_view text) const noexcept;
      std::span<const AgentManifest> entries() const noexcept;

    private:
      AgentProvider inferProvider(std::string_view text) const noexcept;

      static constexpr Byte first_custom_provider = first_custom_agent_provider;
      static constexpr Byte maximum_custom_agents = max_agent_provider_index - first_custom_provider + 1;
      ds::Array<AgentManifest, 32> entries_;
      std::size_t count_ = 0;
      Byte custom_count_ = 0;
    };

  }
}

// Interface: telar_config/agents/builtin_manifests.cppm
export {
  namespace telar::runtime {

    AgentManifests makeBuiltinManifests();

    inline const AgentManifests builtin_manifests = makeBuiltinManifests();

  }
}

// Interface: telar_config/control_reader.cppm
export {
  namespace telar::runtime::config {

    void readControlPolicy(const lua::Value& table, control::Policy& policy);

  }
}

// Interface: telar_config/history/filters.cppm
export {
  namespace telar::runtime {

    class HistoryPatternList {
    public:
      void append(std::string_view pattern);
      bool matches(std::string_view text) const noexcept;

    private:
      ds::Array<FixedText<256>, 64> patterns_;
      std::size_t count_ = 0;
    };

    class HistoryFilters {
    public:
      bool allowsPane(std::string_view command, std::string_view directory) const noexcept;
      bool allowsAgent(std::string_view command, std::string_view directory, bool redact = true) const noexcept;
      static bool looksLikeSecret(std::string_view command) noexcept;

      bool secrets = true;
      HistoryPatternList commands;
      HistoryPatternList directories;

    private:
      struct TokenRule {
        std::string_view marker;
        std::size_t minimum_length;
      };

      static bool tokenByte(unsigned char byte) noexcept;
      static bool matchesToken(std::string_view command, const TokenRule& rule) noexcept;
      static bool matchesAssignment(std::string_view command, std::string_view marker) noexcept;
    };

    inline const HistoryFilters default_history_filters{};

  }
}

// Interface: telar_config/proxy/capture_limits.cppm
export {
  namespace telar::runtime {

    struct ProxyCaptureLimits {
      static constexpr std::size_t mebibyte = 1024 * 1024;
      static constexpr std::size_t maximum_exchange_bytes = 64 * mebibyte;
      static constexpr std::size_t maximum_total_bytes = 1024 * mebibyte;
      static constexpr auto maximum_join_timeout = std::chrono::hours{1};

      std::size_t part_bytes = 16 * mebibyte;
      std::size_t exchange_bytes = 32 * mebibyte;
      std::size_t total_bytes = 128 * mebibyte;
      std::chrono::milliseconds join_timeout{std::chrono::minutes{15}};
      bool enabled = false;

      bool valid() const noexcept;
    };

  }
}

// Interface: telar_config/proxy/host_policy.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class ProxyHostPolicy {
    public:
      static constexpr std::size_t maximum_hosts = 256;
      static constexpr std::size_t maximum_hostname_bytes = ProxyHostname::maximum_bytes;

      explicit ProxyHostPolicy(Memory& memory);
      static bool validPattern(std::string_view pattern) noexcept;
      bool append(std::string_view pattern);
      void finish();
      void clear() noexcept;
      bool contains(std::string_view hostname) const noexcept;
      std::span<const String<Memory>> patterns() const noexcept;

    private:
      bool find(std::string_view pattern) const noexcept;

      static constexpr std::string_view wildcard_prefix = "*.";
      Vector<String<Memory>, Memory> patterns_;
    };

  }
}

// Interface: telar_config/proxy/options.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    struct ProxyOptions {
      explicit ProxyOptions(Memory& memory);

      String<Memory> authority_directory;
      ProxyHostPolicy<Memory> intercept_hosts;
      ProxyCaptureLimits capture;
      bool enabled = false;
      bool anonymous_tunnels = false;
      bool pane_https_proxy = true;
      bool network_capture = false;
      bool network_control = false;
      bool transparent_redirect = false;
      bool transparent_tls = false;
      bool stream_interception = false;
    };

  }
}

// Interface: telar_config/proxy_reader.cppm
export {
  namespace telar::runtime::config {

    template <Allocator Memory>
    class ProxyReader {
    public:
      static void read(const lua::Value& table, ProxyOptions<Memory>& values);

    private:
      static std::size_t positive(const lua::Value& field, std::size_t fallback);
      static void capture(const lua::Value& table, ProxyCaptureLimits& limits);

      static constexpr std::size_t maximum_path_bytes = 1024;
    };

  }
}

// Interface: telar_config/runtime_values.cppm
export {
  namespace telar::runtime::config {

    template <Allocator Memory>
    struct CommandValues {
      static constexpr std::size_t maximum_arguments = 32;

      // The arguments as views into this value.
      struct Views {
        ds::Array<std::string_view, maximum_arguments> words{};
        std::size_t count = 0;

        [[nodiscard]] std::span<const std::string_view> span() const noexcept;
      };

      explicit CommandValues(Memory& memory);
      [[nodiscard]] Views views() const noexcept;

      Vector<String<Memory>, Memory> arguments;
      std::chrono::milliseconds timeout{15'000};
      std::chrono::milliseconds idle_timeout{300'000};
    };

    template <Allocator Memory>
    struct RuntimeValues {
      explicit RuntimeValues(Memory& memory);

      String<Memory> history_path;
      String<Memory> session_path;
      HistoryFilters history_filters;
      CommandValues<Memory> engine;
      CommandValues<Memory> descriptions;
      ProxyOptions<Memory> proxy;
      plugins::Specifications plugins;
      FixedText<PATH_MAX> configuration_directory;
      AgentManifests manifests = builtin_manifests;
      LimitNotices limits;
      GraphicsLimits graphics;
      control::Policy control_policy{};
      bool capture_output = false;
      bool persist_session = true;
      bool resume_agents = true;
      bool shell_integration = true;
      bool ssh_integration = true;
    };

    template <Allocator Memory>
    RuntimeValues(Memory& memory) -> RuntimeValues<Memory>;

  }
}

// Interface: telar_config/runtime_reader.cppm
export {
  namespace telar::runtime::config {

    template <Allocator Memory>
    class RuntimeReader {
    public:
      explicit RuntimeReader(RuntimeValues<Memory>& values);
      void read(const lua::Value& runtime);

    private:
      void graphics(const lua::Value& table);
      static void path(const lua::Value& field, String<Memory>& destination);
      static void patterns(const lua::Value& field, HistoryPatternList& destination);
      void history(const lua::Value& table);
      void session(const lua::Value& table);
      static void helper(const lua::Value& table, CommandValues<Memory>& destination, bool engine);

      RuntimeValues<Memory>& values_;
    };

    template <Allocator Memory>
    RuntimeReader(RuntimeValues<Memory>& values) -> RuntimeReader<Memory>;

  }
}

// The templates above are built in runtime.cpp and runtime_reader.cpp: the manifest lists for
// their two shapes, the proxy settings for the erased Memory family and the stacks of base
// allocators that callers build directly, and the configuration values for Memory and
// ConcurrentMemory. Any other allocator goes behind a MemoryAdapter.
namespace telar::runtime {

  extern template class ManifestTextList<8, 128>;
  extern template class ManifestTextList<16, 64>;
  extern template class ProxyHostPolicy<Memory>;
  extern template class ProxyHostPolicy<ConcurrentMemory>;
  extern template class ProxyHostPolicy<SystemAllocator>;
  extern template class ProxyHostPolicy<BudgetAllocator<SystemAllocator>>;
  extern template class ProxyHostPolicy<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;
  extern template struct ProxyOptions<Memory>;
  extern template struct ProxyOptions<ConcurrentMemory>;
  extern template struct ProxyOptions<SystemAllocator>;
  extern template struct ProxyOptions<BudgetAllocator<SystemAllocator>>;
  extern template struct ProxyOptions<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;

}

namespace telar::runtime::config {

  extern template class ProxyReader<Memory>;
  extern template class ProxyReader<ConcurrentMemory>;
  extern template class ProxyReader<SystemAllocator>;
  extern template class ProxyReader<BudgetAllocator<SystemAllocator>>;
  extern template class ProxyReader<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>;
  extern template struct CommandValues<Memory>;
  extern template struct CommandValues<ConcurrentMemory>;
  extern template struct RuntimeValues<Memory>;
  extern template struct RuntimeValues<ConcurrentMemory>;
  extern template class RuntimeReader<Memory>;
  extern template class RuntimeReader<ConcurrentMemory>;

}
