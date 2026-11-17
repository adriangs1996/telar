// What a project, a tab and a task card say of the agents in them: how many work, wait or
// finished, the cue a tab shows, and the facts and line a card gives up as its row runs short.
export module telar.gui.features.activity:labels;

import std;

import telar.tbc;
import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.gui.foundation.text;

// Interface: presentation/project_activity.cppm
export {
  namespace telar::gui::features::activity {

    struct ProjectActivity {
      static constexpr std::size_t attention_capacity = 8;
      using Text = LabelText;
      using Attention = BoundedText<attention_capacity>;

      std::size_t worktrees = 0;
      std::size_t working = 0;
      std::size_t finished = 0;
      std::size_t waiting = 0;
      std::optional<std::size_t> urgent;
      std::optional<std::string_view> path;

      template <Allocator Memory>
      // The activity names the project's path in the replica, region `a`.
      [[nodiscard]] static tbc::view<ProjectActivity, tbc::lt::a> derive(tbc::view<const WorkspaceReplica<Memory>&, tbc::lt::a> workspaces, std::span<const Agent<Memory>> agents, std::uint64_t project) noexcept;

      [[nodiscard]] tbc::view<std::optional<std::string_view>, tbc::lt::a> summary(tbc::view<Text&, tbc::lt::a> storage) const;

      [[nodiscard]] Attention attentionLabel() const;
    };

    extern template tbc::view<ProjectActivity, tbc::lt::a> ProjectActivity::derive<Memory>(tbc::view<const WorkspaceReplica<Memory>&, tbc::lt::a> workspaces, std::span<const Agent<Memory>> agents, std::uint64_t project) noexcept;
    extern template tbc::view<ProjectActivity, tbc::lt::a> ProjectActivity::derive<ConcurrentMemory>(tbc::view<const WorkspaceReplica<ConcurrentMemory>&, tbc::lt::a> workspaces, std::span<const Agent<ConcurrentMemory>> agents, std::uint64_t project) noexcept;

  }
}

// Interface: presentation/tab_activity.cppm
export {
  namespace telar::gui::features::activity {

    struct TabActivity {
      static constexpr float dot_side = 6;
      static constexpr float spinner_side = 12;
      static constexpr float spinner_fraction = 0.3F;
      static constexpr unsigned spinner_steps = 8;
      static constexpr std::uint64_t spinner_interval_ns = 120'000'000;

      enum class Kind : std::uint8_t {
        none,
        dot,
        spinner,
        progress,
      };

      Kind kind = Kind::none;
      PaletteRole color = PaletteRole::teal;
      std::optional<PaletteRole> attention = std::nullopt;

      [[nodiscard]] float width() const noexcept;

      // `focused` is the progress of the tab's focused pane, `remove` when it has none.
      template <Allocator Memory>
      [[nodiscard]] static TabActivity derive(const Tab<Memory>& tab, PaneProgressState focused, std::span<const Agent<Memory>> agents, bool selected) noexcept;
    };

    extern template TabActivity TabActivity::derive<Memory>(const Tab<Memory>& tab, PaneProgressState focused, std::span<const Agent<Memory>> agents, bool selected) noexcept;
    extern template TabActivity TabActivity::derive<ConcurrentMemory>(const Tab<ConcurrentMemory>& tab, PaneProgressState focused, std::span<const Agent<ConcurrentMemory>> agents, bool selected) noexcept;

  }
}

// Interface: presentation/task_card_labels.cppm
export {
  namespace telar::gui::features::activity {

    struct TaskCardLabels {
      static constexpr std::size_t text_capacity = label_text_capacity;
      // The share of a card's second row its context may take from the signal: less while the
      // agent waits on the person, more once it rests, all of it when there is no signal.
      static constexpr float context_share = 0.5F;
      static constexpr float waiting_context_share = 0.38F;
      static constexpr float resting_context_share = 0.6F;
      using Text = LabelText;

      struct Activity {
        std::string_view text;
        PaletteRole color = PaletteRole::overlay1;
        bool plan = false;
      };

      // A worktree's facts in the pieces a card gives up one by one when its row runs short.
      struct Facts {
        Text added;
        Text removed;
        Text files;
        Text ahead;
        Text command;
      };

      template <Allocator Memory>
      [[nodiscard]] static Facts facts(const Worktree<Memory>& task);

      // The line that matters most in the agent's state: what it asks, why it failed, the plan step
      // or event it works on, or its last answer.
      template <Allocator Memory>
      [[nodiscard]] static Activity activity(const Agent<Memory>& agent) noexcept;

      [[nodiscard]] static float contextShare(AgentStatus state, bool signal) noexcept;

      template <Allocator Memory>
      [[nodiscard]] static tbc::view<std::string_view, tbc::lt::static_storage> commandState(const Worktree<Memory>& task, bool connected) noexcept;

      template <Allocator Memory>
      // The facts are written into the storage, or are the state alone when they do not fit: region `a`.
      [[nodiscard]] static tbc::view<std::string_view, tbc::lt::a> commandFacts(std::string_view machine, const Worktree<Memory>& task, bool connected, tbc::view<Text&, tbc::lt::a> storage);

    private:
      static void append(Text& storage, std::string_view text);

      static void decimal(Text& storage, std::uint32_t value);
    };

    extern template TaskCardLabels::Facts TaskCardLabels::facts<Memory>(const Worktree<Memory>& task);
    extern template TaskCardLabels::Facts TaskCardLabels::facts<ConcurrentMemory>(const Worktree<ConcurrentMemory>& task);
    extern template TaskCardLabels::Activity TaskCardLabels::activity<Memory>(const Agent<Memory>& agent) noexcept;
    extern template TaskCardLabels::Activity TaskCardLabels::activity<ConcurrentMemory>(const Agent<ConcurrentMemory>& agent) noexcept;
    extern template tbc::view<std::string_view, tbc::lt::static_storage> TaskCardLabels::commandState<Memory>(const Worktree<Memory>& task, bool connected) noexcept;
    extern template tbc::view<std::string_view, tbc::lt::static_storage> TaskCardLabels::commandState<ConcurrentMemory>(const Worktree<ConcurrentMemory>& task, bool connected) noexcept;
    extern template tbc::view<std::string_view, tbc::lt::a> TaskCardLabels::commandFacts<Memory>(std::string_view machine, const Worktree<Memory>& task, bool connected, tbc::view<TaskCardLabels::Text&, tbc::lt::a> storage);
    extern template tbc::view<std::string_view, tbc::lt::a> TaskCardLabels::commandFacts<ConcurrentMemory>(std::string_view machine, const Worktree<ConcurrentMemory>& task, bool connected, tbc::view<TaskCardLabels::Text&, tbc::lt::a> storage);

  }
}
