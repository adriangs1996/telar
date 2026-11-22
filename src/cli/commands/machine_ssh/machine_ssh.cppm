export module telar.cli.commands.machine_ssh;

import std;
import telar.tbc;
import telar.sys.posix;

import telar.machines;

import telar.base.text.json;
import telar.base.text;
import telar.cli.console.output;
import telar.cli.commands.plugin;
import telar.platform.paths;
import telar.platform.process;
import telar.base.memory.allocators;
import telar.base.ds;
import telar.base.memory.containers;
import telar.cli.console.command_limit;

// Interface: config_receive.cppm
export {
  namespace telar::runtime::cli::config_receive {

    inline constexpr std::size_t max_file_bytes = 1024 * std::size_t{1024};
    inline constexpr std::size_t max_total_bytes = 16 * max_file_bytes;
    inline constexpr std::size_t max_files = 4096;

    // Directories that hold credentials, which no configuration sync reads or writes below.
    inline constexpr auto credential_directories = ds::Array<std::string_view, 8>{".ssh", ".gnupg", ".aws", ".kube", ".docker", "keychains", "gcloud", ".password-store"};

    bool acceptable(std::string_view path);

    int run(Memory& memory);

  }
}

// Interface: launch_process.cppm
export {
  namespace telar::runtime::cli::launch {

    inline constexpr int ssh_failure = 255;
    inline constexpr std::size_t output_limit = 256 * std::size_t{1024};

    // A program and its arguments, each a NUL-terminated text, as exec takes them.
    using Argv = ds::Vec<Text, Memory>;

    tbc::val_a<Argv> words(tbc::mut_a<Memory> memory, std::initializer_list<std::string_view> words);

    // Replaces this process with the program.
    [[noreturn]] void replace(std::span<const Text> arguments);

    // Runs a program on this terminal: it keeps the standard streams and this process group, and
    // nothing else this process holds.
    int inherit(std::span<const Text> arguments);

    struct Output {
      explicit Output(Memory& memory);

      int status = ssh_failure;
      Text out;
      Text err;
      std::size_t dropped = 0;

      [[nodiscard]] std::string_view errorLine() const;
    };

    // Runs a program with `input` on its standard input, keeping the tail of each output stream.
    // Input and output are polled together, so no size of either deadlocks against the child.
    tbc::val_a<Output> capture(tbc::mut_a<Memory> memory, std::span<const Text> arguments, std::string_view input, std::chrono::seconds timeout);

    // As `capture`, with the contents of an open regular file as the input, or none for -1.
    tbc::val_a<Output> captureFile(tbc::mut_a<Memory> memory, std::span<const Text> arguments, int file, std::chrono::seconds timeout);

    // The value as one single-quoted shell word.
    void appendQuoted(Text& output, std::string_view value);

    Text quote(Memory& memory, std::string_view value);

  }
}

// Interface: machine_options.cppm
export {
  namespace telar::runtime::cli {

    struct MachineOptions {
      enum class Action : std::uint8_t {
        add,
        remove,
        rename,
        enable,
        disable,
        list,
        check,
        setup,
        receive_config,
      };
      Action action;
      std::string_view label;
      std::string_view value;
      ds::Option<std::string_view> color;
      ds::Option<std::string_view> new_label;
      ds::Option<std::string_view> binary;
      bool disabled = false;
      bool check = false;
      bool json = false;
      bool setup = false;
      bool confirm = false;
      ds::Array<bool, 4> skip{};

      static MachineOptions parse(std::span<char* const> args);
    };

  }
}

// Interface: machine_store.cppm
export {
  namespace telar::runtime::cli::machine {

    using namespace machines;

    Text profilesPath(Memory& memory);

    MachineProfiles load(Memory& memory, const Text& path);

    // This machine's label: the one saved, else its host name.
    inline constexpr std::size_t local_label_bytes = 256;
    using LocalLabel = FixedText<local_label_bytes>;

    LocalLabel localLabel(const MachineProfiles& profiles);

    struct Random {
      static void fill(std::span<std::uint8_t> bytes);
    };

    MachineProfile newProfile(const MachineProfiles& profiles, const MachineOptions& options);

    void change(MachineProfiles& profiles, const MachineOptions& options);

    const char* describe(std::string_view error);

    int report(const std::exception& error);

    int list(Memory& memory, const MachineProfiles& profiles, bool json);

  }
}

// Interface: machine_ssh.cppm
export {
  namespace telar::runtime::cli::machine {

    inline constexpr std::size_t command_limit = 64 * std::size_t{1024};
    inline constexpr auto probe_timeout = std::chrono::seconds{60};
    inline constexpr auto install_timeout = std::chrono::seconds{900};
    using Discovery = machines::MachineDiscovery<PATH_MAX>;

    tbc::val_a<Text> decode(tbc::mut_a<Memory> memory, std::string_view word);

    using launch::Argv;

    // The SSH argv that runs `command` there, with a terminal there only when `terminal`.
    tbc::val_a<Argv> ssh(tbc::mut_a<Memory> memory, std::string_view destination, std::string_view command, bool terminal = false);

    // `GIT_SSH_COMMAND` for Git traffic to `destination` over the same options.
    tbc::val_a<Text> gitSshCommand(tbc::mut_a<Memory> memory, std::string_view destination);

    // The shell command that runs `words` as one telar command there.
    template <typename Words>
    tbc::val_a<Text> remoteCommand(tbc::mut_a<Memory> memory, const MachineProfile& profile, const Words& words);
    extern template Text remoteCommand<std::span<const std::string_view>>(Memory& memory, const MachineProfile& profile, const std::span<const std::string_view>& words);

    // Runs one telar command on the machine with this terminal's streams and
    // returns its exit status. When stdin and stdout are a terminal, so is the
    // command's there, so it can ask the person here.
    template <typename Words>
    int forward(Memory& memory, const MachineProfile& profile, const Words& words);
    extern template int forward<std::span<const std::string_view>>(Memory& memory, const MachineProfile& profile, const std::span<const std::string_view>& words);
    extern template int forward<std::span<char* const>>(Memory& memory, const MachineProfile& profile, const std::span<char* const>& words);

    // Runs one telar command on the machine, reading `input` (or nothing), and
    // returns its stdout. Its stderr passes through; a failure throws `failure`.
    template <typename Words>
    tbc::val_a<Text> capture(tbc::mut_a<Memory> memory, const MachineProfile& profile, const Words& words, const char* failure, int input = -1);
    extern template Text capture<std::span<const std::string_view>>(Memory& memory, const MachineProfile& profile, const std::span<const std::string_view>& words, const char* failure, int input);

    // The saved machine `label` names, or nullopt for this machine's own label.
    tbc::val_a<ds::Option<MachineProfile>> resolve(tbc::mut_a<Memory> memory, std::string_view label);

    MachineError sshFailure(const launch::Output& output);

    Discovery discover(Memory& memory, const MachineProfile& profile, Text& detail);

    int check(Memory& memory, const MachineProfile& profile, bool json);

  }
}

// Not exported. remoteCommand, a template its importers name, reaches it, so it keeps module
// linkage: an internal one would be exposed to the importers (-Wreference-tu-local-entity-in-other-tu).
namespace telar::runtime::cli::machine {

  // Appends `argument` as one shell-safe word: `a`, then its bytes in URL-safe base64.
  void appendEncoded(Text& result, std::string_view argument);

}

// Interface: machines/config_filter.cppm
export {
  namespace telar::runtime::cli::machine::filter {

    // The names of what a filter dropped, each once.
    using Notes = ds::Vec<Text, Memory>;

    tbc::val_a<Text> rewriteHome(tbc::mut_a<Memory> memory, std::string_view bytes, std::string_view from, std::string_view replacement);

    tbc::val_a<Text> stripJsonc(tbc::mut_a<Memory> memory, std::string_view bytes);

    void json(Memory& memory, const JsonValue& value, ds::String<Memory>& output, Notes& dropped);

    tbc::val_a<Text> toml(tbc::mut_a<Memory> memory, std::string_view bytes, Notes& dropped);

    ds::Option<std::pair<std::size_t, std::string_view>> findSecret(std::string_view bytes);

  }
}

// Interface: window_launch_options.cppm
export {
  namespace telar::runtime::cli {

    // The options view the command line, which outlives them.
    struct WindowOptions {
      static constexpr std::size_t maximum_command_words = 64;

      ds::Option<std::string_view> config;
      ds::Option<std::string_view> profile;
      ds::Option<std::string_view> theme;
      ds::Option<std::string_view> remote;
      ds::Option<std::string_view> machine;
      bool no_config = false;
      bool fresh = false;
      bool login_shell = false;
      ds::Array<std::string_view, maximum_command_words> command_words{};
      std::size_t command_count = 0;

      // The command the window runs in its first pane, when given.
      [[nodiscard]] std::span<const std::string_view> command() const noexcept;

      // One of the theme names, whatever case and alias `name` uses.
      static std::string_view canonicalTheme(std::string_view name);

      static WindowOptions parse(std::span<char* const> input, bool gui = false);
    };

  }
}

// Interface: window_launch.cppm
export {
  namespace telar::runtime::cli {

    void relaunchLogin(Memory& memory, std::span<char* const> words);

    int openWindow(Memory& memory, const WindowOptions& options);

  }
}
