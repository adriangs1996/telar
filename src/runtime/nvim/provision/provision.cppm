export module telar.runtime.nvim.provision;

import std;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.wire.nvim;

export namespace telar::runtime {

  // The Neovim release telar provisions: `telar integration install editor` installs it under
  // the data directory, where the runtime looks for this version.
  [[nodiscard]] std::string_view pinnedNeovim() noexcept;

  // What of a host decides the Neovim an editor pane runs and where its configuration is kept.
  struct NvimHost {
    // Where telar keeps its own files: $XDG_DATA_HOME, or ~/.local/share.
    std::string_view data_home;
    // A Neovim the user named, $TELAR_NVIM; empty for none.
    std::string_view configured;
    // A Neovim that came in telar's own package, beside its programs; empty for none.
    std::string_view shipped;
  };

  // The Neovim an editor pane starts on a host, and the configuration it starts it with. The
  // program is the one the user named, else the one telar provisioned, else the one its
  // package brought, else whatever `nvim` the runtime's PATH has, which the editor then asks
  // for its version. The configuration is telar's own, written under the data directory, and
  // the user's layer over it is the one in telar's configuration directory, editor/init.lua:
  // the one of the user's own Neovim is never read.
  class NvimProvision {
  public:
    // The name Neovim runs under: its configuration is $XDG_CONFIG_HOME/telar/editor, and its
    // plugins and its state are kept under telar/editor of its other directories. Never the
    // user's own `nvim`.
    static constexpr std::string_view own_name = "telar/editor";

    explicit NvimProvision(ConcurrentMemory& memory);

    // Looks at the host as it is now: a Neovim added since the last pane is found by the next.
    void resolve(const NvimHost& host);

    // The program to start: a path, or `nvim` to be found along the PATH.
    [[nodiscard]] std::string_view program() const noexcept;

    // telar's own init.lua; empty when it could not be written, and Neovim then starts on none.
    [[nodiscard]] std::string_view ownInit() const noexcept;

  private:
    ConcurrentMemory& memory_;
    ds::String<ConcurrentMemory> program_;
    ds::String<ConcurrentMemory> init_;
  };

  // The environment of a Neovim an editor pane starts with `arguments`, as the runtime builds
  // them or as a session saved them: on telar's own configuration, or on none, both of which
  // only the runtime names with -u, it keeps its files under NvimProvision::own_name, and
  // TELAR_EDITOR_RUNTIME names the parsers and queries this telar brings, share/telar/editor
  // beside its programs, when it has them.
  [[nodiscard]] std::span<const EnvironmentEntry> nvimEnvironment(std::span<const std::string_view> arguments) noexcept;

  // What taking a client's editor configuration changed: the files written because they were new
  // or differed, and the files removed because the client had none of them.
  struct NvimConfigurationChange {
    std::size_t written = 0;
    std::size_t removed = 0;
  };

  // Makes `directory`, the absolute path of the editor's configuration, hold `files` and nothing
  // else, creating it if it has to. A file that differs is replaced whole; a file or a link the
  // client did not send is removed, and so is a directory that is left empty. A name that starts
  // with a dot is neither taken nor removed, so a checkout's .git stays where it is. A path that
  // is not a plain relative one, names a dot entry or comes twice refuses the whole
  // configuration before anything is written, with std::invalid_argument; one that cannot be
  // written throws SystemError, and what was written before it stays.
  NvimConfigurationChange mirrorNvimConfiguration(ConcurrentMemory& memory, std::string_view directory, std::span<const NvimConfigurationFile> files);

}
