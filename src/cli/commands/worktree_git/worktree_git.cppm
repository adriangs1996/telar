export module telar.cli.commands.worktree_git;

import std;
import telar.tbc;

import telar.cli.console.command_limit;

import telar.platform.paths;
import telar.platform.process;

import telar.cli.console.output;

import telar.base.memory.allocators;
import telar.base.text.json;
import telar.wire.vocabulary;
import telar.wire.layout;
import telar.git.checkout;
import telar.platform.primitives;
import telar.cli.session.runtime_observer;
import telar.cli.session.control_session;
import telar.base.ds;

// Interface: repository_identity.cppm
export {
  namespace telar::runtime::cli::repository {

    // The origin as `host/path`, lowercase host, default port, `.git` and slashes dropped.
    tbc::val_a<Text> normalize(tbc::mut_a<Memory> memory, std::string_view url);

    // The origin without the credentials an authority may carry.
    tbc::val_a<Text> sanitized(tbc::mut_a<Memory> memory, std::string_view origin);

  }
}

// Interface: repository_git.cppm
export {
  namespace telar::runtime::cli::repository {

    inline constexpr std::size_t max_git_output = std::size_t{8} * 1024 * 1024;
    inline constexpr std::size_t max_bundle_bytes = std::size_t{256} * 1024 * 1024;
    inline constexpr std::chrono::seconds git_timeout{600};

    class Git {
    public:
      // What git prints is read into `memory`, region `a`.
      Git(tbc::mut_a<Memory> memory, std::string_view root);

      tbc::val_a<Text> read(std::initializer_list<std::string_view> arguments);

      tbc::val_a<Text> read(std::span<const std::string_view> arguments);

      // `revisions` are rev-list arguments: the ref, then any exclusions.
      void bundle(std::span<const std::string_view> revisions, int descriptor);

    private:
      tbc::val_a<std::pair<int, Text>> execute(Command<Memory>& command, bool bounded);

      tbc::mut_a<Memory> memory_;
      tbc::val_a<HardenedGit<Memory>> git_;
    };

    void ready(Git& git, std::string_view commit);

  }
}

// Interface: session_arguments.cppm
export {
  namespace telar::runtime::cli::sessions {

    inline constexpr std::size_t workspace_name_bytes = 256;
    inline constexpr std::size_t tab_label_bytes = 128;
    inline constexpr std::size_t branch_bytes = 200;
    inline constexpr std::size_t title_bytes = 96;
    inline constexpr std::size_t brief_bytes = 512;
    inline constexpr std::size_t command_words = 32;
    inline constexpr unsigned default_wait_seconds = 600;
    inline constexpr unsigned max_wait_seconds = 86400;
    inline constexpr TerminalSize launch_size{.cols = 160, .rows = 48};
    inline constexpr TerminalSize workspace_size{.cols = 80, .rows = 24};

    void text(std::string_view value, std::size_t maximum, const char* error, bool empty = false);

    void printable(std::string_view value, std::size_t maximum);

    // A branch of the repository whose checkout is at `root`.
    struct RepositoryBranch {
      std::string_view root;
      std::string_view branch;
    };

    // Where a branch's worktree is checked out unless told otherwise: beside the repository, under
    // `<root>-worktrees/`, named after the branch with slashes and backslashes as dashes. Appended
    // to `path`.
    template <typename Text>
    void appendWorktreeCheckout(Text& path, RepositoryBranch checkout);
    extern template void appendWorktreeCheckout<ds::String<Memory>>(ds::String<Memory>& path, RepositoryBranch checkout);

    void branch(std::string_view value);

    void single(tbc::mut_a<ds::Option<std::string_view>> field, tbc::val_a<std::string_view> value, const char* error);

    struct Target {
      ds::Option<std::uint64_t> id;

      static Target parse(std::string_view value);

      std::uint64_t resolve(const char* variable) const;
    };

    struct WorkspaceOptions {
      enum class Action : std::uint8_t {
        create,
        list,
        get,
        rename,
        select,
      };
      Action action{};
      Target target{};
      ds::Option<std::string_view> name, directory, worktree, socket;
      Arguments command;
      ds::Option<std::uint16_t> columns;
      bool json = false;

      static WorkspaceOptions parse(Arguments words);
    };

    struct TabOptions {
      enum class Action : std::uint8_t {
        list,
        get,
        create,
        rename,
        close,
        move,
      };
      Action action{};
      Target workspace{};
      Target target{};
      ds::Option<std::string_view> label, socket;
      TabMoveDirection direction{};
      ds::Option<std::uint64_t> relative;
      bool background = false, json = false;

      static TabOptions parse(Arguments words);
    };

  }
}

// Interface: session_channel.cppm
export {
  namespace telar::runtime::cli::sessions {

    // The canonical path of a directory that exists.
    tbc::val_a<Text> realDirectory(tbc::mut_a<Memory> memory, std::string_view path);

    void wireTabLabel(std::string_view value, bool empty = false);

    // Catalog subscriptions also carry unrelated broadcasts. Keep them on a separate
    // connection from exchanges. The protocol is ControlSession's; Channel adds
    // the sessions commands' runtime start and their descriptions of failures.
    class Channel {
    public:
      Channel(Memory& memory, ds::Option<std::string_view> socket, bool start);

      // `reason` reports the runtime's own words for a refusal; otherwise the
      // refusal's generic description. Generic over the protocol's messages, an
      // open set, so it stays a template here.
      template <typename Reply, typename Request>
      [[tbc::generic]] inline Reply exchange(Request request, bool reason = true) {
        try {
          return session_.getMut().template exchange<Reply>(request);
        } catch (...) {
          rethrowTranslated(reason);
        }
      }

      WorkspaceList catalog();

      [[nodiscard]] const char* socket() const;

      // The conversation itself, for commands shared with families that hold a bare session.
      ControlSession& control() noexcept;

    private:
      static ServerOptions socketOptions(ds::Option<std::string_view> socket);

      // An errno a connection can meet is named as everywhere; anything else is described.
      static const char* connectionFailure(int code) noexcept;

      // Rethrows the exception being handled as the failure the command reports.
      [[noreturn]] static void rethrowTranslated(bool reason = true);

      static constexpr unsigned reply_timeout_seconds = 30;
      RuntimePaths<Memory> paths_;
      ds::Option<ControlSession> session_;
    };

    void checkLocation(TabLocation actual, TabLocation expected);

    ClientDescriptor chooseClient(std::span<const ClientDescriptor> clients, std::uint64_t wanted);

  }
}

// Interface: workspace.cppm
export {
  namespace telar::runtime::cli::sessions {

    int workspace(Memory& memory, const WorkspaceOptions& options);

  }
}

// Interface: worktree_git.cppm
export {
  namespace telar::runtime::cli::sessions {

    struct GitWorktree {
      Text path, branch;
    };

    // Decides which worktrees `WorktreeGit::listed` keeps, by path.
    class WorktreeFilter {
    public:
      virtual bool operator()(std::string_view path) const = 0;

    protected:
      WorktreeFilter() = default;
      WorktreeFilter(const WorktreeFilter&) = default;
      WorktreeFilter(WorktreeFilter&&) = default;
      WorktreeFilter& operator=(const WorktreeFilter&) = default;
      WorktreeFilter& operator=(WorktreeFilter&&) = default;
      ~WorktreeFilter() = default;
    };

    class WorktreeGit {
    public:
      // What it returns is in `memory`, and borrows nothing of it: a run keeps no state between runs.
      explicit WorktreeGit(tbc::mut_a<Memory> memory);

      // Mutations retain only the tail of diagnostics; diff streams both byte
      // streams. Every invocation uses literal argv and a bounded deadline.
      tbc::val_a<Text> run(std::span<const std::string_view> arguments, const char* failure = "NotARepository", bool stream = false, bool hardened = false, std::span<const std::pair<std::string_view, std::string_view>> environment = {}) const;

      tbc::val_a<Text> run(std::initializer_list<std::string_view> arguments, const char* failure = "NotARepository", bool stream = false, bool hardened = false) const;

      [[nodiscard]] tbc::val_a<Text> line(std::initializer_list<std::string_view> arguments, bool hardened = false) const;

      [[nodiscard]] tbc::val_a<Text> root(std::string_view directory) const;

      [[nodiscard]] tbc::val_a<Text> currentBranch(std::string_view directory) const;

      [[nodiscard]] bool succeeds(std::initializer_list<std::string_view> arguments, bool hardened = false) const;

      void add(std::string_view root, std::string_view directory, std::string_view branch, std::string_view base) const;

      [[nodiscard]] tbc::val_a<ds::Vec<GitWorktree, Memory>> listed(std::string_view directory, const WorktreeFilter& keep) const;

      // The merge check runs through the untrusted Git: hooks, filters and lazy
      // fetches off. A clone that could still fetch lazily, on a Git too old to
      // switch that off, counts as not merged and asks a person.
      [[nodiscard]] bool merged(RepositoryBranch checkout) const;

    private:
      tbc::mut_a<Memory> memory_;
    };

  }
}

// Interface: worktree_options.cppm
export {
  namespace telar::runtime::cli::sessions {

    inline constexpr std::size_t machine_label_bytes = 32;

    CoordinatorReference coordinatorReference(std::string_view value);

    void machineLabel(std::string_view value);

    struct WorktreeOptions {
      enum class Action : std::uint8_t {
        create,
        exec,
        list,
        open,
        diff,
        remove,
        fetch,
        resolve,
      };
      Action action{};
      ds::Option<std::string_view> branch, title, from, label, workspace, directory, machine, dispatched_from, repository, socket;
      ds::Option<CoordinatorReference> coordinator;
      Arguments command;
      std::uint64_t client = 0;
      unsigned timeout = default_wait_seconds;
      bool json = false, setup = false, uncommitted = false, stat = false, force = false, delete_branch = false, wait = false;

      static WorktreeOptions parse(Arguments words);
    };

  }
}
