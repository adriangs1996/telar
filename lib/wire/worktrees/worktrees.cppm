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
export extern "C++" {
  namespace telar {

    struct RegisterWorktree {
      std::uint64_t request_id{};
      std::uint64_t source{};
      ds::Option<std::uint64_t> created_by{};
      WorktreeOrigin origin{};
      std::string_view path{};
      std::string_view branch{};
      std::string_view base{};
      std::string_view title{};
      std::string_view brief{};
      std::string_view dispatched_from{};
      ds::Option<CoordinatorReference> coordinator{};

      void validate() const;
    };

    template <>
    struct MessageSchema<RegisterWorktree>
        : Schema<Direction::client, ClientTag::register_worktree, Field<&RegisterWorktree::request_id, NonzeroU64, "request_id">, Field<&RegisterWorktree::source, NonzeroU64, "source">, Field<&RegisterWorktree::created_by, OptionalValue<NonzeroU64>, "created_by">, Field<&RegisterWorktree::origin, EnumByte<WorktreeOrigin, 1>, "origin">, Field<&RegisterWorktree::path, Text16<4096, false>, "path">, Field<&RegisterWorktree::branch, DisplayText16<200, false>, "branch">, Field<&RegisterWorktree::base, DisplayText16<200>, "base">, Field<&RegisterWorktree::title, DisplayText16<96>, "title">, Field<&RegisterWorktree::brief, MessageText16<512>, "brief">, Field<&RegisterWorktree::dispatched_from, DisplayText16<32>, "dispatched_from">, Field<&RegisterWorktree::coordinator, OptionalValue<ValueCodec<CoordinatorReference>>, "coordinator">> {};

    struct LaunchWorktree {
      std::uint64_t request_id{};
      std::uint64_t worktree{};
      std::string_view label{};
      TerminalSize size{};
      Launch launch{};
    };

    template <>
    struct MessageSchema<LaunchWorktree>
        : Schema<Direction::client, ClientTag::launch_worktree, Field<&LaunchWorktree::request_id, NonzeroU64, "request_id">, Field<&LaunchWorktree::worktree, NonzeroU64, "worktree">, Field<&LaunchWorktree::label, DisplayText16<128>, "label">, Field<&LaunchWorktree::size, ValueCodec<TerminalSize>, "size">, Field<&LaunchWorktree::launch, ValueCodec<Launch>, "launch">> {};

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
