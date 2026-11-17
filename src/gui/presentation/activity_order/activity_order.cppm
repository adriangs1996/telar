export module telar.gui.presentation.activity_order;

import std;
import telar.tbc;

import telar.gui.presentation.application_mark;
import telar.gui.model.replicas;

import telar.gui.foundation.core;
import telar.gui.foundation.text;
import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.gui.model.records;

// Interface: presentation/agent_order.cppm
export {
  namespace telar::gui {

    struct AgentOrder {
      static constexpr std::size_t maximum_agents = 64;
      static constexpr std::size_t unknown_project = std::numeric_limits<std::size_t>::max();

      enum class Attention : std::uint8_t {
        needs_input,
        working,
        done,
        ready,
        unknown,
      };

      struct Entry {
        std::size_t agent = 0;
        std::optional<std::uint64_t> project = std::nullopt;
        std::optional<std::size_t> creator = std::nullopt;
        ActivityCard card = ActivityCard::agent;
        bool first_in_project = false;
      };

      // What arrange sorts agents by: attention first, then age and pane.
      using Priority = std::tuple<Attention, std::uint32_t, std::uint64_t, std::uint64_t>;

      struct Plan {
        std::array<Entry, maximum_agents> entries{};
        std::size_t count = 0;

        [[nodiscard]] std::span<const Entry> view() const noexcept;
      };

      [[nodiscard]] static Attention attention(AgentStatus status) noexcept;

      // An agent that works or waits on the person: what a stack of agent cards shows.
      [[nodiscard]] static bool stacked(AgentStatus status) noexcept;

      template <Allocator Memory>
      // The row is one of the replica's, region `a`; the agent only names it.
      [[nodiscard]] static tbc::view<const Worktree<Memory>*, tbc::lt::a> taskRow(tbc::view<const WorkspaceReplica<Memory>&, tbc::lt::a> workspaces, const Agent<Memory>& agent) noexcept;

      template <Allocator Memory>
      [[nodiscard]] static Priority priority(const Agent<Memory>& agent) noexcept;

      template <Allocator Memory>
      [[nodiscard]] static Plan arrange(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory>& workspaces) noexcept;

    private:
      template <Allocator Memory>
      [[nodiscard]] static std::size_t projectRank(std::optional<std::uint64_t> identity, std::span<const Workspace<Memory>> workspaces) noexcept;

      template <Allocator Memory>
      [[nodiscard]] static std::optional<std::uint64_t> projectOf(const WorkspaceReplica<Memory>& workspaces, const Agent<Memory>& agent) noexcept;

      template <Allocator Memory>
      [[nodiscard]] static std::optional<std::size_t> creatorOf(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory>& workspaces, std::span<const Entry> entries, const Entry& entry) noexcept;

      template <Allocator Memory>
      [[nodiscard]] static bool lessThan(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory>& workspaces, const Entry& left, const Entry& right) noexcept;
    };

    extern template tbc::view<const Worktree<Memory>*, tbc::lt::a> AgentOrder::taskRow<Memory>(tbc::view<const WorkspaceReplica<Memory>&, tbc::lt::a> workspaces, const Agent<Memory>& agent) noexcept;
    extern template tbc::view<const Worktree<ConcurrentMemory>*, tbc::lt::a> AgentOrder::taskRow<ConcurrentMemory>(tbc::view<const WorkspaceReplica<ConcurrentMemory>&, tbc::lt::a> workspaces, const Agent<ConcurrentMemory>& agent) noexcept;
    extern template AgentOrder::Priority AgentOrder::priority<Memory>(const Agent<Memory>& agent) noexcept;
    extern template AgentOrder::Priority AgentOrder::priority<ConcurrentMemory>(const Agent<ConcurrentMemory>& agent) noexcept;
    extern template AgentOrder::Plan AgentOrder::arrange<Memory>(std::span<const Agent<Memory>> agents, const WorkspaceReplica<Memory>& workspaces) noexcept;
    extern template AgentOrder::Plan AgentOrder::arrange<ConcurrentMemory>(std::span<const Agent<ConcurrentMemory>> agents, const WorkspaceReplica<ConcurrentMemory>& workspaces) noexcept;

  }
}

// Interface: presentation/activity_order.cppm
export {
  namespace telar::gui {

    template <Allocator Memory>
    class ActivityOrder {
    public:
      static constexpr std::size_t maximum_sources = 17;
      static constexpr std::size_t maximum_entries = maximum_sources * (AgentOrder::maximum_agents + WorkspaceReplica<Memory>::maximum_worktrees);

      struct Source {
        std::uint8_t slot = 0;
        std::span<const Agent<Memory>> agents;
        const WorkspaceReplica<Memory>& workspaces;
      };

      struct Entry {
        std::size_t source = 0;
        std::optional<std::size_t> agent = std::nullopt;
        std::optional<std::size_t> worktree = std::nullopt;
        std::optional<std::uint64_t> project = std::nullopt;
        ActivityCard card = ActivityCard::agent;
        std::optional<std::size_t> parent = std::nullopt;
        std::size_t depth = 0;
        bool coordinator = false;
        bool first_in_project = false;
      };

      struct Plan {
        std::array<Entry, maximum_entries> entries;
        std::size_t count = 0;

        [[nodiscard]] std::span<const Entry> view() const noexcept;
      };

      static void write(std::span<const Source> sources, std::uint8_t active_slot, Plan& output);

    private:
      enum class Visit : std::uint8_t {
        unseen,
        visiting,
        finished,
      };

      explicit ActivityOrder(std::span<const Source> sources, Plan& output);

      void collect(std::uint8_t active_slot);

      [[nodiscard]] auto identityAt(std::size_t index) const noexcept;

      [[nodiscard]] const Worktree<Memory>* rowOf(const Entry& entry) const noexcept;

      [[nodiscard]] std::optional<std::size_t> parentOf(std::span<const std::size_t> agents, std::size_t index) const noexcept;

      void findParents();

      void breakChainCycle(std::size_t start, std::span<Visit> visits, std::span<std::size_t> path) noexcept;

      void breakCycles() noexcept;

      struct Children {
        std::array<std::optional<std::size_t>, maximum_entries> first;
        std::array<std::optional<std::size_t>, maximum_entries> last;
        std::array<std::optional<std::size_t>, maximum_entries> next;
      };

      [[nodiscard]] Children linkChildren() noexcept;

      void emitForest() noexcept;

      std::span<const Source> sources_;
      Plan& output_;
      std::array<Entry, maximum_entries> nodes_;
      std::size_t count_ = 0;
    };

    extern template class ActivityOrder<Memory>;
    extern template class ActivityOrder<ConcurrentMemory>;

  }
}

// Interface: presentation/agent_status.cppm
export {
  namespace telar::gui {

    struct AgentStatusPresentation {
      static constexpr std::uint32_t seconds_per_minute = 60;
      static constexpr std::uint32_t seconds_per_hour = 60 * seconds_per_minute;
      static constexpr std::uint32_t seconds_per_day = 24 * seconds_per_hour;
      static constexpr std::uint32_t maximum_days = 9999;
      static constexpr std::size_t age_capacity = 8;
      static constexpr std::size_t text_capacity = 32;
      using Text = BoundedText<text_capacity>;
      using Age = BoundedText<age_capacity>;

      [[nodiscard]] static std::string_view word(AgentStatus status, AgentBlockedReason reason) noexcept;

      [[nodiscard]] static std::string_view glyph(AgentStatus status, AgentBlockedReason reason) noexcept;

      [[nodiscard]] static PaletteRole color(AgentStatus status) noexcept;

      [[nodiscard]] static Age age(std::uint32_t seconds, bool duration = false);

      [[nodiscard]] static Text text(AgentStatus status, AgentBlockedReason reason, std::uint32_t seconds, bool connected = true);

      [[nodiscard]] static float pulse(std::uint8_t frame) noexcept;
    };

  }
}

// Interface: presentation/progress_geometry.cppm
export {
  namespace telar::gui {

    struct ProgressGeometry {
      static constexpr float ring_side = 14;
      static constexpr float padding = 5;
      static constexpr float height = 20;
      static constexpr float ring_inset = 4;
      static constexpr float background_alpha = 0.1F;
      static constexpr float mark_stroke_ratio = 0.1F;
      static constexpr float mark_top_ratio = 0.32F;
      static constexpr float pause_height_ratio = 0.36F;
      static constexpr float error_height_ratio = 0.24F;
      static constexpr float error_dot_ratio = 0.63F;
      static constexpr std::array pause_offsets{-1.5F, 0.5F};

      Rect background;
      Rect ring;
      std::array<Rect, 2> marks{};
      std::size_t mark_count = 0;
      float mark_radius = 0;

      [[nodiscard]] static constexpr float compactWidth(float ratio = 1) noexcept {
        const auto scaled_padding = padding * ratio;

        return (ring_side * ratio) + (2 * scaled_padding);
      }

      [[nodiscard]] static ProgressGeometry derive(Rect area, float ratio, PaneProgressState state, bool compact = true) noexcept;
    };

  }
}

// Interface: presentation/pane_chrome.cppm
export {
  namespace telar::gui {

    struct PaneStatusChip {
      static constexpr float inset = 8;
      static constexpr float height = 20;
      static constexpr float radius = 6;
      static constexpr std::size_t text_capacity = 32;
      using Text = BoundedText<text_capacity>;

      [[nodiscard]] static Text text(AgentStatus status, AgentBlockedReason reason, std::uint32_t seconds);

      [[nodiscard]] static PaletteRole color(AgentStatus status) noexcept;
    };

    struct PaneProgressPresentation {
      static constexpr std::size_t text_capacity = 24;
      using Text = BoundedText<text_capacity>;

      [[nodiscard]] static Text text(PaneProgressState state, std::uint8_t percent);

      [[nodiscard]] static PaletteRole color(PaneProgressState state) noexcept;
    };

    struct PaneHeaderMetrics {
      float ratio = 1;
      float maximum_band_height = 0;
    };

    struct PaneHeaderMeasurements {
      float index = 0;
      float name = 0;
      float chip = 0;
      float paused = 0;
      float progress = 0;
      float compact_progress = 0;
      bool needs_attention = false;
    };

    struct PaneHeaderGeometry {
      static constexpr float margin = 8;
      static constexpr float part_gap = 6;
      static constexpr float chip_gap = 8;
      static constexpr float minimum_text_room = 12;

      Rect index;
      Rect name;
      Rect paused;
      Rect chip;
      Rect progress;
      bool compact_progress = false;

      bool operator==(const PaneHeaderGeometry&) const = default;

      [[nodiscard]] static PaneHeaderGeometry derive(Rect row, const PaneHeaderMetrics& metrics, const PaneHeaderMeasurements& measurements) noexcept;
    };

  }
}

// Interface: presentation/project_activity.cppm
export {
  namespace telar::gui {

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
  namespace telar::gui {

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
  namespace telar::gui {

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
