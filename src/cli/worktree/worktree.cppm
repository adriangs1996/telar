export module telar.cli.worktree;

import std;
import telar.tbc;

import telar.cli.worktree_git;

import telar.cli.command_limit;

import telar.cli.machine_ssh;
import telar.cli.project_setup;
import telar.cli.history;
import telar.platform.paths;
import telar.machines;
import telar.base.memory.allocators;
import telar.base.ds;

// Interface: repository_options.cppm
export {
  namespace telar::runtime::cli {

    struct RepositoryOptions {
      enum class Action : std::uint8_t {
        prepare,
        receive,
        tips,
      };
      Action action;
      ds::Option<std::string_view> machine = ds::none;
      std::string_view from = "HEAD";
      ds::Option<std::string_view> workspace = ds::none;
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
      Text path;
      Text commit;
      Text repository;
      bool reused;

      // Writes the repository as one JSON line to standard output.
      void print(bool receiver = false) const;
    };

    template <Allocator Memory>
    tbc::val_a<PreparedRepository> receive(tbc::mut_a<Memory> memory, const RepositoryOptions& options);

  }
}

// Interface: repository_prepare.cppm
export {
  namespace telar::runtime::cli::repository {

    // The destination side of the history negotiation: HEAD and the newest ref
    // tips of the clone `receive` would update, one per line, or nothing without
    // a clone. A clone `receive` published has only its detached HEAD.
    template <Allocator Memory>
    tbc::val_a<Text> tips(tbc::mut_a<Memory> memory, const RepositoryOptions& options);

    // Runs the given telar words on the other machine with the descriptor as
    // stdin (-1 for none) and returns their stdout.
    class RepositoryCapture {
    public:
      virtual Text operator()(std::span<const std::string_view> words, int input) = 0;

    protected:
      RepositoryCapture() = default;
      RepositoryCapture(const RepositoryCapture&) = default;
      RepositoryCapture& operator=(const RepositoryCapture&) = default;
      RepositoryCapture(RepositoryCapture&&) = default;
      RepositoryCapture& operator=(RepositoryCapture&&) = default;
      ~RepositoryCapture() = default;
    };

    // Repository preparation: bundles `options.from`, less what the other
    // machine's clone already holds, and has that machine's telar receive it
    // through `capture`.
    tbc::val_a<PreparedRepository> prepare(tbc::mut_a<Memory> memory, const RepositoryOptions& options, std::string_view remote_program, RepositoryCapture& capture);

    // Shared by `repository prepare` and `worktree create --machine`.
    tbc::val_a<PreparedRepository> prepare(tbc::mut_a<Memory> memory, const RepositoryOptions& options, const machines::MachineProfile& profile);

    int run(Memory& memory, const RepositoryOptions& options);

  }
}

// Interface: worktree.cppm
export {
  namespace telar::runtime::cli::sessions {

    int worktree(Memory& memory, const WorktreeOptions& options);

  }
}
