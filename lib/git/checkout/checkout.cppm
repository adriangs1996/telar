module;
#include "tbc/annotations.hpp"

export module telar.git.checkout;

import std;
import telar.tbc;
import telar.sys.posix;

import telar.base.memory.allocators;
import telar.platform.process;
import telar.base.ds;

// What telar reads from a checkout without the native reader in telar.git: the files under
// .git, HEAD and linked worktrees, and the git command run hardened against the repository.

// Interface: telar_platform/git_files.cppm
export {
  namespace telar::runtime {

    class GitFiles {
    public:
      static tbc::val_a<ds::Option<std::string_view>> join(std::string_view directory, std::string_view suffix, tbc::val_a<std::span<char>> buffer) noexcept;
      static tbc::val_a<ds::Option<std::string_view>> resolve(std::string_view directory, std::string_view path, tbc::val_a<std::span<char>> buffer) noexcept;
      static tbc::val_a<ds::Option<std::string_view>> directory(std::string_view root, tbc::val_a<std::span<char>> buffer) noexcept;
    };

  }
}

// Interface: telar_platform/git_head.cppm
export {
  namespace telar::runtime {

    class GitHead {
    public:
      ds::Option<std::string_view> read(std::string_view root) noexcept;
      static std::string_view parse(std::string_view contents) noexcept;

    private:
      static constexpr std::size_t head_bytes = 4096;

      ds::Array<char, PATH_MAX> path_;
      ds::Array<char, head_bytes> head_;
    };

  }
}

// Interface: telar_platform/git_observation_policy.cppm
export {
  namespace telar::runtime {

    struct GitRepositoryFacts {
      static constexpr std::size_t maximum_drivers = 8;
      ds::Array<std::string_view, maximum_drivers> drivers;
      std::size_t driver_count = 0;
      bool may_fetch = false;

      static ds::Option<GitRepositoryFacts> parse(std::string_view listing) noexcept;
    };

    inline constexpr auto git_observation_options = ds::Array<std::string_view, 53>{
        "git",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "hook.applypatch-msg.enabled=false",
        "-c",
        "hook.pre-applypatch.enabled=false",
        "-c",
        "hook.post-applypatch.enabled=false",
        "-c",
        "hook.pre-commit.enabled=false",
        "-c",
        "hook.pre-merge-commit.enabled=false",
        "-c",
        "hook.prepare-commit-msg.enabled=false",
        "-c",
        "hook.commit-msg.enabled=false",
        "-c",
        "hook.post-commit.enabled=false",
        "-c",
        "hook.pre-rebase.enabled=false",
        "-c",
        "hook.post-checkout.enabled=false",
        "-c",
        "hook.post-merge.enabled=false",
        "-c",
        "hook.pre-push.enabled=false",
        "-c",
        "hook.pre-receive.enabled=false",
        "-c",
        "hook.update.enabled=false",
        "-c",
        "hook.proc-receive.enabled=false",
        "-c",
        "hook.post-receive.enabled=false",
        "-c",
        "hook.post-update.enabled=false",
        "-c",
        "hook.reference-transaction.enabled=false",
        "-c",
        "hook.push-to-checkout.enabled=false",
        "-c",
        "hook.pre-auto-gc.enabled=false",
        "-c",
        "hook.post-rewrite.enabled=false",
        "-c",
        "hook.sendemail-validate.enabled=false",
        "-c",
        "hook.fsmonitor-watchman.enabled=false",
        "-c",
        "hook.post-index-change.enabled=false",
    };

    // Git run against a repository that may be hostile: no hooks, fsmonitor or prompts, no lazy
    // fetch, no inherited GIT_* environment, and every filter driver the repository configures
    // overridden to nothing. A repository that may fetch lazily needs git 2.45 or later, the first
    // that honors GIT_NO_LAZY_FETCH.
    template <Allocator Memory>
    class HardenedGit {
    public:
      // The repository's root and the overrides are copied into `memory`, region `a`.
      HardenedGit(tbc::mut_a<Memory> memory, std::string_view root);
      HardenedGit(const HardenedGit&) = delete;
      HardenedGit& operator=(const HardenedGit&) = delete;
      HardenedGit(HardenedGit&&) = delete;
      HardenedGit& operator=(HardenedGit&&) = delete;
      ~HardenedGit() = default;

      // Reads the repository's filter drivers and lazy-fetch facts, before any other command:
      // `run(command)` returns the command's exit status and its output; `reject()` throws the
      // caller's failure.
      template <typename Run, typename Reject>
      TBC_GENERIC void inspect(Run&& run, Reject&& reject) {
        // Stays generic over the caller's runner and failure; the listing is read in the implementation unit.
        const auto [status, text] = with({"config", "--show-scope", "-z", "--get-regexp", R"(^(filter\.|extensions\.partialclone$|remote\..*\.(promisor|partialclonefilter|uploadpack)$))"}, run);
        const auto may_fetch = overrideFilters(status, text);
        auto accepted = static_cast<bool>(may_fetch);

        if (accepted && *may_fetch) {
          const auto [version_status, version_text] = with({"version"}, std::forward<Run>(run));

          accepted = version_status == 0 && honorsLazyFetchControl(version_text);
        }

        if (!accepted) {
          std::forward<Reject>(reject)();
        }
      }

      // Hands `use` the command `git` with the hardening options and overrides, then `arguments`,
      // in the repository; a command keeps its address, so it lives for this call. The result borrows
      // only what `use` holds, region `a`, never `use` itself, as a Rust closure's result does.
      template <typename Use>
      TBC_GENERIC tbc::val_a<std::invoke_result_t<Use&, Command<Memory>&>> with(std::span<const std::string_view> arguments, tbc::holds<Use&&, tbc::lt::a> use) const {
        // Stays generic over the caller's use of the command; its command line is built in the implementation unit.
        auto command = commandFor(arguments);

        configure(command);
        return use(command);
      }

      template <typename Use>
      TBC_GENERIC tbc::val_a<std::invoke_result_t<Use&, Command<Memory>&>> with(std::initializer_list<std::string_view> arguments, tbc::holds<Use&&, tbc::lt::a> use) const {
        // Stays generic over the caller's use of the command.
        return with(std::span{arguments.begin(), arguments.size()}, std::forward<Use>(use));
      }

      // The environment every git telar runs gets: nothing inherited from GIT_*, no optional locks,
      // lazy fetches or prompts, and messages in the C locale.
      static void configure(Command<Memory>& command);

      // Whether `git version` names 2.45 or later.
      [[nodiscard]] static bool honorsLazyFetchControl(std::string_view version) noexcept;

    private:
      // Overrides each filter driver the `config` listing names and returns whether the repository
      // may fetch lazily; nullopt when the listing cannot be read.
      ds::Option<bool> overrideFilters(int status, std::string_view listing);

      // `git`, the hardening options and overrides, then `arguments`, run in the repository.
      [[nodiscard]] Command<Memory> commandFor(std::span<const std::string_view> arguments) const;

      tbc::mut_a<Memory> memory_;
      tbc::val_a<ds::String<Memory>> root_;
      tbc::val_a<ds::Vec<ds::String<Memory>, Memory>> overrides_;
    };

    extern template class HardenedGit<Memory>;
    extern template class HardenedGit<ConcurrentMemory>;

  }
}

// Interface: telar_platform/linked_worktree.cppm
export {
  namespace telar::runtime {

    class LinkedWorktree {
    public:
      struct Found {
        std::size_t root_length;
        std::string_view branch;
      };

      ds::Option<Found> find(std::string_view directory) noexcept;
      ds::Option<std::string_view> mainBranch(std::string_view root) noexcept;

    private:
      ds::Option<std::string_view> linkedBranch(std::string_view root) noexcept;

      static constexpr std::size_t head_bytes = 256;

      ds::Array<char, PATH_MAX> path_;
      ds::Array<char, head_bytes> head_;
    };

  }
}
