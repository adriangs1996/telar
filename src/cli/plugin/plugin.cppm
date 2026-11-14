export module telar.cli.plugin;

import std;
import telar.tbc;

export import telar.cli.command_limit;
export import telar.platform.paths;

export import telar.plugins;

import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.platform.primitives;
import telar.cli.server;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.process;
import telar.tls;
import telar.cli.base.command_error;

// Interface: cli_install.cppm
export {
  namespace telar::runtime::cli {

    CommandError fileError(int code);

    struct CliInstallOptions {
      std::string_view action;
      std::optional<std::string_view> directory;
    };

    CliInstallOptions parseCliInstall(std::span<char* const> args);

    int runCliInstall(std::span<char* const> args);

  }
}

// Interface: plugin_options.cppm
export {
  namespace telar::runtime::cli {

    enum class PluginAction {
      inspect,
      install,
      trust,
      untrust,
    };

    struct PluginOptions {
      PluginAction action;
      std::string_view path;
      std::array<plugins::Capability, static_cast<std::size_t>(plugins::Capability::count)> capabilities{};
      std::size_t capability_count = 0;

      // The plugin command's options, with their error names.
      static PluginOptions parse(std::span<char* const> arguments);

    private:
      static PluginAction parseAction(std::string_view action);
    };

  }
}

// Interface: plugin.cppm
export {
  namespace telar::runtime::cli {

    // A failure after the arguments parsed prints `error: NAME` with the error
    // name.
    template <Allocator Memory, EnvironmentLookup Environment>
    void runPlugin(Memory& memory, const PluginOptions& options, const Environment& environment);
    extern template void runPlugin<Memory, ProcessEnvironment>(Memory& memory, const PluginOptions& options, const ProcessEnvironment& environment);

  }
}

// Interface: proxy_options.cppm
export {
  namespace telar::runtime::cli {

    enum class ProxyTrustAction {
      install,
      uninstall,
      status,
    };

    struct ProxyTrustOptions {
      ProxyTrustAction action = ProxyTrustAction::status;
      std::string_view directory;
      std::string_view linux_backend;

      // The proxy trust command's options, with their error names.
      static ProxyTrustOptions parse(std::span<char* const> arguments);
    };

  }
}

// Interface: proxy_trust.cppm
export {
  namespace telar::runtime::cli {

    template <ConcurrentAllocator Memory, EnvironmentLookup Environment>
    int runProxyTrust(Memory& memory, const ProxyTrustOptions& options, const Environment& environment);
    extern template int runProxyTrust<ConcurrentMemory, ProcessEnvironment>(ConcurrentMemory& memory, const ProxyTrustOptions& options, const ProcessEnvironment& environment);

  }
}

// Interface: routed_options.cppm
export {
  namespace telar::runtime::cli {

    // Each `ClientAction`'s wire name, in the enum's order.
    inline constexpr std::array<std::string_view, 34> client_action_names{
        "workspace_select",
        "tab_create",
        "tab_select",
        "tab_next",
        "tab_previous",
        "pane_create",
        "pane_split",
        "pane_close",
        "pane_focus",
        "pane_resize",
        "pane_fullscreen",
        "pane_scroll",
        "sidebar_get",
        "sidebar_show",
        "sidebar_hide",
        "sidebar_resize",
        "workspace_list_expand",
        "workspace_list_collapse",
        "client_open_goto",
        "client_open_history",
        "client_copy_mode",
        "notification_dismiss",
        "client_open_link",
        "client_clipboard_copy",
        "pane_copy",
        "layout_get",
        "layout_apply",
        "config_reload",
        "config_show",
        "plugin_list",
        "plugin_get",
        "plugin_enable",
        "plugin_disable",
        "plugin_run"
    };

    inline constexpr std::array<std::string_view, 4> pane_directions{"left", "right", "up", "down"};

    std::string_view clientActionName(ClientAction action);

    // `CopySelection.fromText`: "ROW,COLUMN:ROW,COLUMN".
    void copyRange(std::string_view text);

    // A command a window performs: the family and verb name a `ClientAction` ("pane copy" is `pane_copy`), and the
    // runtime forwards it to the client `--client` names.
    // A routed command's options; its text and socket view the command's words, region `a`.
    struct RoutedOptions {
      ClientAction action{};
      std::uint64_t client_id = 0;
      std::uint64_t target_id = 0;
      std::int64_t value = 0;
      tbc::view<std::string_view, tbc::lt::a> text{};
      bool json = false;
      tbc::view<const char*, tbc::lt::a> socket = nullptr;

      // `words` starts at the family. Not a routed command: nullopt, so the
      // family's own parser reads it.
      static std::optional<RoutedOptions> parse(Arguments words);

    private:
      static std::optional<ClientAction> parseAction(std::string_view group, std::string_view verb, std::string_view nested);

      // A tab created in the background never reaches a UI: the runtime opens it.
      // Focusing the current pane or a neighbor is the runtime's, too.
      static bool excluded(ClientAction action, Arguments rest);

      void positionals(Cursor& cursor);

      void options(Cursor& cursor);
    };

  }
}
