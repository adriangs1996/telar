export module telar.runtime.nvim.provision;

import std;
import telar.base.ds;
import telar.base.memory.allocators;

export namespace telar::runtime {

  // The Neovim release telar provisions: `telar integration install editor` installs it under
  // the data directory, where the runtime looks for this version.
  [[nodiscard]] std::string_view pinnedNeovim() noexcept;

  // What of a host decides the Neovim an editor pane runs and the configuration it loads.
  struct NvimHost {
    // Where telar keeps its own files: $XDG_DATA_HOME, or ~/.local/share.
    std::string_view data_home;
    // Where the user's configurations are: $XDG_CONFIG_HOME, or ~/.config.
    std::string_view config_home;
    // A Neovim the user named, $TELAR_NVIM; empty for none.
    std::string_view configured;
  };

  // The Neovim an editor pane starts on a host, and the configuration it starts it with. The
  // program is the one the user named, else the one telar provisioned, else whatever `nvim`
  // the runtime's PATH has, which the editor then asks for its version. The configuration is
  // the user's when the host has one; otherwise telar's own, written under the data directory.
  class NvimProvision {
  public:
    // The name Neovim keeps its plugins and its state under while it runs telar's
    // configuration: never the user's `nvim`, nor telar's own directory.
    static constexpr std::string_view own_name = "telar-nvim";

    explicit NvimProvision(ConcurrentMemory& memory);

    // Looks at the host as it is now: a Neovim or a configuration added since the last pane
    // is found by the next.
    void resolve(const NvimHost& host);

    // The program to start: a path, or `nvim` to be found along the PATH.
    [[nodiscard]] std::string_view program() const noexcept;

    // telar's own init.lua, when the host has no configuration; empty when it has one, or
    // when telar's could not be written.
    [[nodiscard]] std::string_view ownInit() const noexcept;

  private:
    ConcurrentMemory& memory_;
    ds::String<ConcurrentMemory> program_;
    ds::String<ConcurrentMemory> init_;
  };

}
