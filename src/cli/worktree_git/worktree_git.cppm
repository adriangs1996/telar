module;
#include "tbc/annotations.hpp"

export module telar.cli.worktree_git;

import std;
import telar.tbc;

import telar.cli.command_limit;

import telar.platform.paths;
import telar.platform.process;

import telar.cli.output;

import telar.base.memory.allocators;
import telar.base.text;
import telar.base.text.json;
import telar.wire.vocabulary;
import telar.wire.layout;
import telar.git.checkout;
import telar.platform.primitives;
import telar.cli.runtime_observer;
import telar.cli.control_session;

// Interface: repository_identity.cppm
export {
  namespace telar::runtime::cli::repository {

    std::string normalize(std::string_view url);

    std::string sanitized(std::string_view origin);

  }
}

// Interface: repository_git.cppm
export {
  namespace telar::runtime::cli::repository {

    inline constexpr std::size_t max_git_output = 8 * 1024 * 1024;
    inline constexpr std::size_t max_bundle_bytes = 256 * 1024 * 1024;
    inline constexpr std::chrono::seconds git_timeout{600};

    class Git {
    public:
      Git(Memory& memory, std::string_view root);

      std::string read(std::initializer_list<std::string_view> arguments);

      std::string read(std::span<const std::string_view> arguments);

      // `revisions` are rev-list arguments: the ref, then any exclusions.
      void bundle(std::span<const std::string_view> revisions, int descriptor);

    private:
      std::pair<int, std::string> execute(Command<Memory>& command, bool bounded);

      Memory& memory_;
      HardenedGit<Memory> git_;
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

    // Where a branch's worktree is checked out unless told otherwise: beside the repository, under
    // `<root>-worktrees/`, named after the branch with slashes and backslashes as dashes. Appended
    // to `path`.
    template <typename Text>
    void appendWorktreeCheckout(Text& path, std::string_view root, std::string_view branch);
    extern template void appendWorktreeCheckout<String<Memory>>(String<Memory>& path, std::string_view root, std::string_view branch);
    extern template void appendWorktreeCheckout<std::string>(std::string& path, std::string_view root, std::string_view branch);

    void branch(std::string_view value);

    void single(tbc::view<std::optional<std::string_view>&, tbc::lt::a> field, tbc::view<std::string_view, tbc::lt::a> value, const char* error);

    struct Target {
      std::optional<std::uint64_t> id{};

      static Target parse(std::string_view value);

      std::uint64_t resolve(const char* variable) const;
    };

    struct WorkspaceOptions {
      enum class Action {
        create,
        list,
        get,
        rename,
        select,
      };
      Action action{};
      Target target{};
      std::optional<std::string_view> name{}, directory{}, worktree{}, socket{};
      Arguments command{};
      std::optional<std::uint16_t> columns{};
      bool json = false;

      static WorkspaceOptions parse(Arguments words);
    };

    struct TabOptions {
      enum class Action {
        list,
        get,
        create,
        rename,
        close,
        move,
      };
      Action action{};
      Target workspace{}, target{};
      std::optional<std::string_view> label{}, socket{};
      TabMoveDirection direction{};
      std::optional<std::uint64_t> relative{};
      bool background = false, json = false;

      static TabOptions parse(Arguments words);
    };

  }
}

// Interface: session_channel.cppm
export {
  namespace telar::runtime::cli::sessions {

    std::string realDirectory(std::string_view path);

    void wireTabLabel(std::string_view value, bool empty = false);

    // Catalog subscriptions also carry unrelated broadcasts. Keep them on a separate
    // connection from exchanges. The protocol is ControlSession's; Channel adds
    // the sessions commands' runtime start and their descriptions of failures.
    class Channel {
    public:
      Channel(Memory& memory, std::optional<std::string_view> socket, bool start);

      // `reason` reports the runtime's own words for a refusal; otherwise the
      // refusal's generic description. Generic over the protocol's messages, an
      // open set, so it stays a template here.
      template <typename Reply, typename Request>
      TBC_GENERIC inline Reply exchange(Request request, bool reason = true) {
        try {
          return session_->template exchange<Reply>(request);
        } catch (...) {
          rethrowTranslated(reason);
        }
      }

      WorkspaceList catalog();

      const char* socket() const;

      // The conversation itself, for commands shared with families that hold a bare session.
      ControlSession& control() noexcept;

    private:
      static ServerOptions socketOptions(std::optional<std::string_view> socket);

      // An errno a connection can meet is named as everywhere; anything else is described.
      static const char* connectionFailure(int code) noexcept;

      // Rethrows the exception being handled as the failure the command reports.
      [[noreturn]] static void rethrowTranslated(bool reason = true);

      static constexpr unsigned reply_timeout_seconds = 30;
      RuntimePaths<Memory> paths_;
      std::optional<ControlSession> session_;
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
      std::string path, branch;
    };

    // Decides which worktrees `WorktreeGit::listed` keeps, by path.
    class WorktreeFilter {
    public:
      virtual bool operator()(std::string_view path) const = 0;

    protected:
      ~WorktreeFilter() = default;
    };

    class WorktreeGit {
    public:
      explicit WorktreeGit(Memory& memory);

      // Mutations retain only the tail of diagnostics; diff streams both byte
      // streams. Every invocation uses literal argv and a bounded deadline.
      std::string run(std::span<const std::string_view> arguments, const char* failure = "NotARepository", bool stream = false, bool hardened = false, std::span<const std::pair<std::string_view, std::string_view>> environment = {});

      std::string run(std::initializer_list<std::string_view> arguments, const char* failure = "NotARepository", bool stream = false, bool hardened = false);

      std::string line(std::initializer_list<std::string_view> arguments, bool hardened = false);

      std::string root(std::string_view directory);

      std::string currentBranch(std::string_view directory);

      bool succeeds(std::initializer_list<std::string_view> arguments, bool hardened = false);

      void add(std::string_view root, std::string_view directory, std::string_view branch, std::string_view base);

      std::vector<GitWorktree> listed(std::string_view directory, const WorktreeFilter& keep);

      // The merge check runs through the untrusted Git: hooks, filters and lazy
      // fetches off. A clone that could still fetch lazily, on a Git too old to
      // switch that off, counts as not merged and asks a person.
      bool merged(std::string_view root, std::string_view branch);

    private:
      Memory& memory_;
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
      enum class Action {
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
      std::optional<std::string_view> branch{}, title{}, from{}, label{}, workspace{}, directory{}, machine{}, dispatched_from{}, repository{}, socket{};
      std::optional<CoordinatorReference> coordinator{};
      Arguments command{};
      std::uint64_t client = 0;
      unsigned timeout = default_wait_seconds;
      bool json = false, setup = false, uncommitted = false, stat = false, force = false, delete_branch = false, wait = false;

      static WorktreeOptions parse(Arguments words);
    };

  }
}
