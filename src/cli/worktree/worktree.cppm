export module telar.cli.worktree;

import std;

export import telar.cli.history;
export import telar.cli.worktree_git;
export import telar.cli.tab;

export import telar.cli.command_limit;

export import telar.platform.fs;
export import telar.platform.paths;
export import telar.platform.process;

import telar.cli.machine_ssh;
import telar.cli.project_setup;
export import telar.base.text;
export import telar.base.text.json;
export import telar.base.text.utf8;
import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.content;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.worktrees;
import telar.platform.primitives;

// Interface: repository_options.cppm
export {
  namespace telar::runtime::cli {

    struct RepositoryOptions {
      enum class Action {
        prepare,
        receive,
        tips,
      };
      Action action;
      std::optional<std::string_view> machine = std::nullopt;
      std::string_view from = "HEAD";
      std::optional<std::string_view> workspace = std::nullopt;
      std::string_view identity;
      std::string_view transport;
      std::string_view commit;
      std::string_view ref;
      std::uint64_t bytes = 0;
      bool json = false;

      static RepositoryOptions parse(Arguments words);
    };

  }
}

// Interface: repository_receive.cppm
export {
  namespace telar::runtime::cli::repository {

    struct PreparedRepository {
      std::string path;
      std::string commit;
      std::string repository;
      bool reused;

      std::string json(bool receiver = false) const;
    };

    template <Allocator Memory>
    PreparedRepository receive(Memory& memory, const RepositoryOptions& options);

  }
}

// Interface: repository_prepare.cppm
export {
  namespace telar::runtime::cli::repository {

    // The destination side of the history negotiation: HEAD and the newest ref
    // tips of the clone `receive` would update, one per line, or nothing without
    // a clone. A clone `receive` published has only its detached HEAD.
    template <Allocator Memory>
    std::string tips(Memory& memory, const RepositoryOptions& options);

    // Runs the given telar words on the other machine with the descriptor as
    // stdin (-1 for none) and returns their stdout.
    class RepositoryCapture {
    public:
      virtual std::string operator()(std::span<const std::string_view> words, int input) = 0;

    protected:
      ~RepositoryCapture() = default;
    };

    // Repository preparation: bundles `options.from`, less what the other
    // machine's clone already holds, and has that machine's telar receive it
    // through `capture`.
    template <Allocator Memory>
    PreparedRepository prepare(Memory& memory, const RepositoryOptions& options, std::string_view remote_program, RepositoryCapture& capture);
    extern template PreparedRepository prepare<Memory>(Memory& memory, const RepositoryOptions& options, std::string_view remote_program, RepositoryCapture& capture);

    // Shared by `repository prepare` and `worktree create --machine`.
    template <Allocator Memory>
    PreparedRepository prepare(Memory& memory, const RepositoryOptions& options, const machines::MachineProfile& profile);

    template <Allocator Memory>
    int run(Memory& memory, const RepositoryOptions& options);
    extern template int run<Memory>(Memory& memory, const RepositoryOptions& options);

  }
}

// Interface: worktree.cppm
export {
  namespace telar::runtime::cli::sessions {

    template <Allocator Memory>
    int worktree(Memory& memory, const WorktreeOptions& options);
    extern template int worktree<Memory>(Memory& memory, const WorktreeOptions& options);

  }
}
