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

      [[nodiscard]] bool expired(std::int64_t now) const noexcept;
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
      [[nodiscard]] bool matches(std::string_view text) const noexcept;
      [[nodiscard]] std::span<const FixedText<TextCapacity>> entries() const noexcept;

    private:
      ds::Array<FixedText<TextCapacity>, Capacity> entries_;
      std::size_t count_ = 0;
    };

    enum class AgentInterruptKey : std::uint8_t {
      none,
      escape,
      escape_twice,
      control_c,
    };

    struct AgentCommandTool {
      static constexpr std::size_t tool_bytes = 64;
      static constexpr std::size_t field_bytes = 32;

      FixedText<tool_bytes> tool;
      FixedText<field_bytes> field;
    };

    struct AgentManifest {
      static constexpr std::size_t name_bytes = 32;
      static constexpr std::size_t placeholder_bytes = 96;
      static constexpr std::size_t icon_bytes = 8;
      static constexpr std::size_t maximum_processes = 8;
      static constexpr std::size_t process_bytes = 128;
      static constexpr std::size_t maximum_phrases = 16;
      static constexpr std::size_t phrase_bytes = 64;
      static constexpr std::size_t maximum_command_tools = 8;

      using ProcessList = ManifestTextList<maximum_processes, process_bytes>;
      using PhraseList = ManifestTextList<maximum_phrases, phrase_bytes>;

      void addCommandTool(std::string_view tool, std::string_view field);
      [[nodiscard]] std::string_view commandField(std::string_view tool) const noexcept;
      [[nodiscard]] std::string_view displayName() const noexcept;

      // The manifest's own placeholder, or one built in the caller's storage.
      tbc::val_a<std::string_view> placeholderTitle(tbc::mut_a<FixedText<placeholder_bytes>> storage) const;

      AgentProvider provider = AgentProvider::unknown;
      tbc::val_a<FixedText<name_bytes>> name;
      tbc::val_a<FixedText<name_bytes>> display_name;
      tbc::val_a<FixedText<placeholder_bytes>> placeholder;
      FixedText<icon_bytes> icon;
      AgentAttachmentMarkers attachments = AgentAttachmentMarkers::none;
      AgentInterruptKey interrupt = AgentInterruptKey::none;
      ProcessList process_names;
      ProcessList process_paths;
      PhraseList brand;
      PhraseList identity;
      PhraseList working;
      PhraseList blocked;
      PhraseList ready_prompt;
      ds::Array<AgentCommandTool, maximum_command_tools> command_tools;
      std::size_t tool_count = 0;
    };

    class AgentManifests {
    public:
      AgentManifest& add(std::string_view name);
      AgentManifest* tryAdd(std::string_view name);
      [[nodiscard]] const AgentManifest* find(AgentProvider provider) const noexcept;
      [[nodiscard]] AgentProvider named(std::string_view name) const noexcept;
      [[nodiscard]] AgentProvider fromExecutable(std::string_view name) const noexcept;
      [[nodiscard]] AgentProvider fromPath(std::string_view path) const noexcept;
      // The state the phrases of the provider's manifest name in the text; for an unknown provider,
      // the phrases of every manifest, and the provider the text's brand names.
      [[nodiscard]] ds::Option<AgentSignal> detect(std::string_view text, AgentProvider provider = AgentProvider::unknown) const noexcept;
      [[nodiscard]] std::span<const AgentManifest> entries() const noexcept;

      static constexpr Byte first_custom_provider = first_custom_agent_provider;
      static constexpr Byte maximum_custom_agents = max_agent_provider_index - first_custom_provider + 1;

    private:
      [[nodiscard]] AgentProvider inferProvider(std::string_view text) const noexcept;

      static constexpr std::size_t capacity = 32;

      ds::Array<AgentManifest, capacity> entries_;
      std::size_t count_ = 0;
      Byte custom_count_ = 0;
    };

  }
}

// Interface: telar_config/agents/builtin_manifests.cppm
export {
  namespace telar::runtime {

    AgentManifests makeBuiltinManifests();

    // The manifests telar ships with, built on first use.
    const AgentManifests& builtinManifests();

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
      [[nodiscard]] bool matches(std::string_view text) const noexcept;

    private:
      static constexpr std::size_t maximum_patterns = 64;
      static constexpr std::size_t pattern_bytes = 256;

      ds::Array<FixedText<pattern_bytes>, maximum_patterns> patterns_;
      std::size_t count_ = 0;
    };

    class HistoryFilters {
    public:
      [[nodiscard]] bool allowsPane(std::string_view command, std::string_view directory) const noexcept;
      [[nodiscard]] bool allowsAgent(std::string_view command, std::string_view directory, bool redact = true) const noexcept;
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

    // The filters a history keeps when the configuration names none, built on first use.
    const HistoryFilters& defaultHistoryFilters() noexcept;

  }
}

// Interface: telar_config/proxy/capture_limits.cppm
export {
  namespace telar::runtime {

    struct ProxyCaptureLimits {
      static constexpr std::size_t kibibyte = 1024;
      static constexpr std::size_t mebibyte = kibibyte * kibibyte;
      static constexpr std::size_t maximum_exchange_bytes = 64 * mebibyte;
      static constexpr std::size_t maximum_total_bytes = kibibyte * mebibyte;
      static constexpr auto maximum_join_timeout = std::chrono::hours{1};
      static constexpr std::size_t default_part_bytes = 16 * mebibyte;
      static constexpr std::size_t default_exchange_bytes = 32 * mebibyte;
      static constexpr std::size_t default_total_bytes = 128 * mebibyte;
      static constexpr auto default_join_timeout = std::chrono::minutes{15};

      std::size_t part_bytes = default_part_bytes;
      std::size_t exchange_bytes = default_exchange_bytes;
      std::size_t total_bytes = default_total_bytes;
      std::chrono::milliseconds join_timeout{default_join_timeout};
      bool enabled = false;

      [[nodiscard]] bool valid() const noexcept;
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

      // A policy allocates its patterns from the allocator in region `a`.
      explicit ProxyHostPolicy(tbc::mut_a<Memory> memory);
      // Copying allocates, so it is explicit; the copy shares this policy's allocator.
      [[nodiscard]] tbc::val_a<ProxyHostPolicy> clone() const;
      static bool validPattern(std::string_view pattern) noexcept;
      bool append(std::string_view pattern);
      void finish();
      void clear() noexcept;
      [[nodiscard]] bool contains(std::string_view hostname) const noexcept;
      [[nodiscard]] std::span<const ds::String<Memory>> patterns() const noexcept;

    private:
      [[nodiscard]] bool find(std::string_view pattern) const noexcept;

      static constexpr std::string_view wildcard_prefix = "*.";
      tbc::val_a<ds::Vec<ds::String<Memory>, Memory>> patterns_;
    };

  }
}

// Interface: telar_config/proxy/options.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    struct ProxyOptions {
      explicit ProxyOptions(tbc::mut_a<Memory> memory);
      // Copying allocates, so it is explicit; the copy shares these options' allocator.
      [[nodiscard]] tbc::val_a<ProxyOptions> clone() const;

      tbc::val_a<ds::String<Memory>> authority_directory;
      tbc::val_a<ProxyHostPolicy<Memory>> intercept_hosts;
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

      explicit CommandValues(tbc::mut_a<Memory> memory);
      // Copying allocates, so it is explicit; the copy shares these values' allocator.
      [[nodiscard]] tbc::val_a<CommandValues> clone() const;
      [[nodiscard]] Views views() const noexcept;

      static constexpr std::chrono::milliseconds default_timeout{15'000};
      static constexpr std::chrono::milliseconds default_idle_timeout{300'000};

      tbc::val_a<ds::Vec<ds::String<Memory>, Memory>> arguments;
      std::chrono::milliseconds timeout{default_timeout};
      std::chrono::milliseconds idle_timeout{default_idle_timeout};
    };

    template <Allocator Memory>
    struct RuntimeValues {
      explicit RuntimeValues(tbc::mut_a<Memory> memory);
      // Copying allocates, so it is explicit; the copy shares these values' allocator.
      [[nodiscard]] tbc::val_a<RuntimeValues> clone() const;

      tbc::val_a<ds::String<Memory>> history_path;
      tbc::val_a<ds::String<Memory>> session_path;
      HistoryFilters history_filters;
      tbc::val_a<CommandValues<Memory>> engine;
      tbc::val_a<CommandValues<Memory>> descriptions;
      tbc::val_a<ProxyOptions<Memory>> proxy;
      plugins::Specifications plugins;
      FixedText<PATH_MAX> configuration_directory;
      AgentManifests manifests = builtinManifests();
      tbc::val_a<LimitNotices> limits;
      GraphicsLimits graphics;
      control::Policy control_policy{};
      bool capture_output = false;
      bool persist_session = true;
      bool resume_agents = true;
      bool shell_integration = true;
      bool ssh_integration = true;
      // Turns on the plan tools an agent keeps off by default, so its card shows its plan.
      bool agent_plans = true;
    };

    template <Allocator Memory>
    RuntimeValues(Memory& memory) -> RuntimeValues<Memory>;

  }
}

// Interface: telar_config/runtime_reader.cppm
export {
  namespace telar::runtime::config {

    // The filters of a `runtime.history` table, added to `filters`: what the history does not keep.
    void readHistoryFilters(const lua::Value& history, HistoryFilters& filters);

    template <Allocator Memory>
    class RuntimeReader {
    public:
      explicit RuntimeReader(RuntimeValues<Memory>& values);
      void read(const lua::Value& runtime);

    private:
      void graphics(const lua::Value& table);
      static void path(const lua::Value& field, ds::String<Memory>& destination);
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

  extern template class ManifestTextList<AgentManifest::maximum_processes, AgentManifest::process_bytes>;
  extern template class ManifestTextList<AgentManifest::maximum_phrases, AgentManifest::phrase_bytes>;
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
