export module telar.wire.worktrees;

// Worktree registration, launch and removal.

import std;
import telar.wire.vocabulary;
import telar.base.ds;

// The schemas specialize `MessageSchema`, which telar.wire.vocabulary declares in its global
// fragment; naming the template here keeps it reachable from importers.
export namespace telar {
  using telar::MessageSchema;
}

// Declared in the global module, with the vocabulary these schemas build on, so the module's
// implementation unit defines their members there too.
// NOLINTBEGIN(misc-use-internal-linkage): exported, and declared in the global module for worktrees.cpp.
export extern "C++" {
  namespace telar {

    struct RegisterWorktree {
      static constexpr std::size_t maximum_path_bytes = 4096;
      // Of the branch and of the base it starts from.
      static constexpr std::size_t maximum_branch_bytes = 200;
      static constexpr std::size_t maximum_title_bytes = 96;
      static constexpr std::size_t maximum_brief_bytes = 512;
      static constexpr std::size_t maximum_dispatched_from_bytes = 32;

      std::uint64_t request_id{};
      std::uint64_t source{};
      ds::Option<std::uint64_t> created_by;
      WorktreeOrigin origin{};
      std::string_view path;
      std::string_view branch;
      std::string_view base;
      std::string_view title;
      std::string_view brief;
      std::string_view dispatched_from;
      ds::Option<CoordinatorReference> coordinator;

      void validate() const;
    };

    template <>
    struct MessageSchema<RegisterWorktree>
        : Schema<Direction::client, ClientTag::register_worktree, Field<&RegisterWorktree::request_id, NonzeroU64, "request_id">, Field<&RegisterWorktree::source, NonzeroU64, "source">, Field<&RegisterWorktree::created_by, OptionalValue<NonzeroU64>, "created_by">, Field<&RegisterWorktree::origin, EnumByte<WorktreeOrigin, 1>, "origin">, Field<&RegisterWorktree::path, Text16<RegisterWorktree::maximum_path_bytes, false>, "path">, Field<&RegisterWorktree::branch, DisplayText16<RegisterWorktree::maximum_branch_bytes, false>, "branch">, Field<&RegisterWorktree::base, DisplayText16<RegisterWorktree::maximum_branch_bytes>, "base">, Field<&RegisterWorktree::title, DisplayText16<RegisterWorktree::maximum_title_bytes>, "title">, Field<&RegisterWorktree::brief, MessageText16<RegisterWorktree::maximum_brief_bytes>, "brief">, Field<&RegisterWorktree::dispatched_from, DisplayText16<RegisterWorktree::maximum_dispatched_from_bytes>, "dispatched_from">, Field<&RegisterWorktree::coordinator, OptionalValue<ValueCodec<CoordinatorReference>>, "coordinator">> {};

    struct LaunchWorktree {
      static constexpr std::size_t maximum_label_bytes = 128;

      std::uint64_t request_id{};
      std::uint64_t worktree{};
      std::string_view label;
      TerminalSize size{};
      Launch launch{};
    };

    template <>
    struct MessageSchema<LaunchWorktree>
        : Schema<Direction::client, ClientTag::launch_worktree, Field<&LaunchWorktree::request_id, NonzeroU64, "request_id">, Field<&LaunchWorktree::worktree, NonzeroU64, "worktree">, Field<&LaunchWorktree::label, DisplayText16<LaunchWorktree::maximum_label_bytes>, "label">, Field<&LaunchWorktree::size, ValueCodec<TerminalSize>, "size">, Field<&LaunchWorktree::launch, ValueCodec<Launch>, "launch">> {};

    struct ForgetWorktree {
      std::uint64_t request_id{};
      std::uint64_t worktree{};
    };

    template <>
    struct MessageSchema<ForgetWorktree>
        : Schema<Direction::client, ClientTag::forget_worktree, Field<&ForgetWorktree::request_id, NonzeroU64, "request_id">, Field<&ForgetWorktree::worktree, NonzeroU64, "worktree">> {};

    struct WorktreeRegistered {
      std::uint64_t request_id{};
      std::uint64_t worktree{};
      bool created{};
    };

    template <>
    struct MessageSchema<WorktreeRegistered>
        : Schema<Direction::server, ServerTag::worktree_registered, Field<&WorktreeRegistered::request_id, NonzeroU64, "request_id">, Field<&WorktreeRegistered::worktree, NonzeroU64, "worktree">, Field<&WorktreeRegistered::created, BoolByte, "created">> {};

  }
}
// NOLINTEND(misc-use-internal-linkage)
