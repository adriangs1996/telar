export module telar.cli.integration.settings;

import std;
import telar.tbc;

export import telar.config.core;
export import telar.platform.error;
export import telar.platform.fs;
export import telar.platform.paths;

export import telar.cli.base.command_error;
export import telar.base.text.json;
import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.platform.primitives;

// Interface: integration_options.cppm
export {
  namespace telar::runtime::cli {

    enum class IntegrationAction {
      install,
      uninstall,
      status,
    };

    struct IntegrationOptions {
      IntegrationAction action = IntegrationAction::status;
      AgentProvider provider = AgentProvider::unknown;
      std::string_view settings;
      bool legacy = false;

      // The integration command's options, with their error names.
      static IntegrationOptions parse(std::span<char* const> arguments);
    };

  }
}

// Interface: integration/provider.cppm
export {
  namespace telar::runtime::cli::integration {

    using Provider = config::IntegrationProvider;

  }
}

// Interface: integration/files.cppm
export {
  namespace telar::runtime::cli::integration {

    template <Allocator Memory>
    std::optional<String<Memory>> read(Memory& memory, const String<Memory>& path, std::size_t maximum_bytes);
    extern template std::optional<String<Memory>> read<Memory>(Memory& memory, const String<Memory>& path, std::size_t maximum_bytes);

  }
}

// Interface: integration/extension.cppm
export {
  namespace telar::runtime::cli::integration {

    template <Allocator Memory, EnvironmentLookup Environment>
    int runExtension(Memory& memory, const IntegrationOptions& options, const Environment& environment, std::string_view executable);
    extern template int runExtension<Memory, ProcessEnvironment>(Memory& memory, const IntegrationOptions& options, const ProcessEnvironment& environment, std::string_view executable);

  }
}

// Interface: integration/hook_settings.cppm
export {
  namespace telar::runtime::cli::integration {

    template <Allocator Memory>
    class HookSettings {
    public:
      explicit HookSettings(Memory& memory, Provider provider, std::string_view executable);

      bool installed(const JsonNode<Memory>& settings, std::string_view event) const noexcept;

      bool install(JsonNode<Memory>& settings) const;

      bool uninstall(JsonNode<Memory>& settings) const;

    private:
      bool isOwnCommand(const JsonNode<Memory>& hook) const noexcept;

      template <typename Node>
      tbc::view<Node*, tbc::lt::a> findHook(tbc::view<Node&, tbc::lt::a> entry) const noexcept;

      bool installEvents(JsonNode<Memory>& hooks, std::span<const std::string_view> events, std::string_view command, std::string_view timeout) const;

      JsonNode<Memory> newEntry(std::string_view command, std::string_view timeout) const;

      bool removeEvents(JsonNode<Memory>& hooks, std::span<const std::string_view> events) const;

      Memory& memory_;
      static constexpr std::string_view worktree_timeout = "360";
      Provider provider_;
      String<Memory> marker_;
      String<Memory> command_;
      String<Memory> worktree_command_;
    };

    extern template class HookSettings<Memory>;

    template <Allocator Memory>
    HookSettings(Memory& memory, Provider provider, std::string_view executable) -> HookSettings<Memory>;

  }
}

// Interface: integration/settings.cppm
export {
  namespace telar::runtime::cli::integration {

    template <Allocator Memory, EnvironmentLookup Environment>
    int runSettings(Memory& memory, const IntegrationOptions& options, const Environment& environment, std::string_view executable);
    extern template int runSettings<Memory, ProcessEnvironment>(Memory& memory, const IntegrationOptions& options, const ProcessEnvironment& environment, std::string_view executable);

  }
}

// Interface: integration.cppm
export {
  namespace telar::runtime::cli {

    int runIntegration(Memory& memory, const IntegrationOptions& options);

  }
}
