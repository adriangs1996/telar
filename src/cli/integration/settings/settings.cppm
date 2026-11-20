export module telar.cli.integration.settings;

import std;
import telar.tbc;

import telar.config.core;
import telar.platform.paths;

import telar.base.text.json;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.ds;

// Interface: integration_options.cppm
export {
  namespace telar::runtime::cli {

    enum class IntegrationAction : std::uint8_t {
      install,
      uninstall,
      status,
    };

    struct IntegrationOptions {
      IntegrationAction action = IntegrationAction::status;
      AgentProvider provider = AgentProvider::unknown;
      // Neovim instead of an agent: `settings` then names its site directory.
      bool neovim = false;
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

    tbc::val_a<ds::Option<ds::String<Memory>>> read(tbc::mut_a<Memory> memory, const ds::String<Memory>& path, std::size_t maximum_bytes);

  }
}

// Interface: integration/extension.cppm
export {
  namespace telar::runtime::cli::integration {

    template <EnvironmentLookup Environment>
    int runExtension(Memory& memory, const IntegrationOptions& options, const Environment& environment, std::string_view executable);
    extern template int runExtension<ProcessEnvironment>(Memory& memory, const IntegrationOptions& options, const ProcessEnvironment& environment, std::string_view executable);

  }
}

// Interface: integration/neovim.cppm
export {
  namespace telar::runtime::cli::integration {

    // Installs, removes or reports telar's Neovim plugin under Neovim's site directory,
    // $XDG_DATA_HOME/$NVIM_APPNAME/site, which Neovim and lazy.nvim load without configuration.
    template <EnvironmentLookup Environment>
    int runNeovim(Memory& memory, const IntegrationOptions& options, const Environment& environment);
    extern template int runNeovim<ProcessEnvironment>(Memory& memory, const IntegrationOptions& options, const ProcessEnvironment& environment);

  }
}

// Interface: integration/hook_settings.cppm
export {
  namespace telar::runtime::cli::integration {

    class HookSettings {
    public:
      explicit HookSettings(Memory& memory, Provider provider, std::string_view executable);

      [[nodiscard]] bool installed(const JsonNode<Memory>& settings, std::string_view event) const noexcept;

      bool install(JsonNode<Memory>& settings) const;

      bool uninstall(JsonNode<Memory>& settings) const;

    private:
      [[nodiscard]] bool isOwnCommand(const JsonNode<Memory>& hook) const noexcept;

      template <typename Node>
      tbc::val_a<Node*> findHook(tbc::mut_a<Node> entry) const noexcept;

      bool installEvents(JsonNode<Memory>& hooks, std::span<const std::string_view> events, std::string_view command, std::string_view timeout) const;

      // A hook's command and how long the agent waits for it.
      struct HookCommand {
        std::string_view command;
        std::string_view timeout;
      };

      [[nodiscard]] JsonNode<Memory> newEntry(HookCommand command) const;

      bool removeEvents(JsonNode<Memory>& hooks, std::span<const std::string_view> events) const;
      // Erases telar's own hooks from a list of them, noting in `changed` whether it erased any;
      // whether the list is left empty.
      bool removeOwnCommands(JsonNode<Memory>& commands, bool& changed) const;

      Memory& memory_;
      static constexpr std::string_view worktree_timeout = "360";
      Provider provider_;
      ds::String<Memory> marker_;
      ds::String<Memory> command_;
      ds::String<Memory> worktree_command_;
    };

  }
}

// Interface: integration/settings.cppm
export {
  namespace telar::runtime::cli::integration {

    // The agent skill `telar --skill NAME` prints, `telar` or `coordinator`, or nullopt for any other name.
    ds::Option<std::string_view> skillText(std::string_view name) noexcept;

    template <EnvironmentLookup Environment>
    int runSettings(Memory& memory, const IntegrationOptions& options, const Environment& environment, std::string_view executable);
    extern template int runSettings<ProcessEnvironment>(Memory& memory, const IntegrationOptions& options, const ProcessEnvironment& environment, std::string_view executable);

  }
}

// Not exported. runExtension and runSettings, templates their importers name, run these, so they
// keep module linkage: an internal one would be exposed to the importers
// (-Wreference-tu-local-entity-in-other-tu).
namespace telar::runtime::cli::integration {

  int extensionCommand(Memory& memory, const IntegrationOptions& options, const EnvironmentSource& environment, std::string_view executable);

  int settingsCommand(Memory& memory, const IntegrationOptions& options, const EnvironmentSource& environment, std::string_view executable);

}

// Interface: integration.cppm
export {
  namespace telar::runtime::cli {

    int runIntegration(Memory& memory, const IntegrationOptions& options);

  }
}
