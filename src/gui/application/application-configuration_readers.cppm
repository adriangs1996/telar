module;

// What the configuration's interpreter gives the GUI, read into the features' values: the
// actions a binding names and what an extended action describes, the content a component's render
// returns, the definitions of the bars, panels and picks, and the options of a pick. Reading them takes the
// interpreter's state and keeps references in its registry, so they live here, beside the
// generation that runs it, and not in a feature.
export module telar.gui.application:configuration_readers;

import std;

import telar.lua;
import telar.config.core;
import telar.gui.features.components;
import telar.config.client;
import telar.gui.foundation.actions;
import telar.gui.foundation.keys;
import telar.base.ds;

namespace telar::gui::application {

  // Maps what runtime::config::ExtendedActionReader read onto the GUI's descriptions.
  class ActionDescriptionReader {
  public:
    static ExtendedActionDescription read(const runtime::lua::Value& value, const runtime::config::ClientDefinitions& definitions);

  private:
    static ExtendedActionDescription description(const runtime::config::NotificationActionSetting& setting);
    static ExtendedActionDescription description(const runtime::config::PluginActionSetting& setting);
    static ExtendedActionDescription description(const runtime::config::DefinitionActionSetting& setting);
  };

  class BindingActionReader {
  public:
    explicit BindingActionReader(lua_State& state, runtime::config::RetainedActionValidator& validator, runtime::config::RetainedCommandTabRegistry& commands, std::uint64_t generation);

    [[nodiscard]] ds::Option<BindingAction> read(const runtime::lua::Value& value, bool expression = false);

  private:
    [[nodiscard]] BindingAction command(const runtime::config::CommandTabView& command);

    // The configuration admits only the names the GUI binds.
    static BindingAction builtin(const runtime::lua::Value& value, std::string_view name);

    [[nodiscard]] BindingAction referenced(const runtime::lua::Value& value, BindingActionKind kind) const;

    lua_State& state_;
    runtime::config::RetainedActionValidator& validator_;
    runtime::config::RetainedCommandTabRegistry& commands_;
    std::uint64_t generation_;
  };

  template <typename Reader>
  concept BindingActionSource = requires(Reader& reader, const runtime::lua::Value& value) {
    { reader.read(value, false) } -> std::same_as<ds::Option<BindingAction>>;
  };

  class BindingReader {
    using Reader = runtime::config::ClientReader;

  public:
    static_assert(BindingLimits::bindings == runtime::config::BindingReader::maximum_bindings);
    static_assert(BindingLimits::keys == runtime::config::BindingSetting::maximum_keys);

    template <BindingActionSource Actions>
    [[tbc::generic]] static void apply(const runtime::lua::Value& client, InputConfiguration& input, Actions& actions) {
      const auto settings = Reader::input(client);
      if (settings.prefix) {
        input.setPrefix(*settings.prefix);
      }

      constexpr std::uint64_t nanoseconds_per_millisecond = 1'000'000;

      if (settings.sequence_timeout_ms) {
        input.sequence_timeout_ns = *settings.sequence_timeout_ms * nanoseconds_per_millisecond;
      }

      if (Reader::listsBindings(client)) {
        input.length = 0;
      }

      const auto listed = Reader::bindings(client, input.prefix, [&](const runtime::config::BindingSetting& setting, const runtime::lua::Value& value) {
        KeyBinding<BindingAction> binding{.prefixed = setting.prefixed};

        std::ranges::copy(std::span{setting.keys}.first(setting.length), binding.keys.viewMut().begin());
        binding.length = setting.length;
        if (const auto action = actions.read(value, setting.expression)) {
          binding.action = *action;
          input.configured.atMut(input.length++) = binding;
        }
      });
      if (listed) {
        input.dropped = *listed - std::min(*listed, BindingLimits::bindings);
      }
    }
  };

  template <std::size_t MaximumReferences>
  class ActionReferences {
  public:
    explicit ActionReferences(lua_State& state) noexcept;

    ~ActionReferences();

    ActionReferences(const ActionReferences&) = delete;
    ActionReferences& operator=(const ActionReferences&) = delete;
    ActionReferences(ActionReferences&&) = delete;
    ActionReferences& operator=(ActionReferences&&) = delete;

    void keep(BindingAction action);

    [[nodiscard]] bool contains(BindingAction action) const noexcept;

    // Release actions omitted by the final fit, including empty containers.
    template <features::components::Capacity Bounds>
    void keepOnly(const features::components::Content<Bounds>& content);

    void swap(ActionReferences& other) noexcept;

    void clear() noexcept;

  private:
    lua_State* state_;
    ds::Array<BindingAction, MaximumReferences> references_{};
    std::size_t count_ = 0;
  };

  // What reads a component's click action from its configuration value.
  class ComponentActions {
  public:
    [[nodiscard]] virtual ds::Option<BindingAction> read(const runtime::lua::Value& value) = 0;

  protected:
    ComponentActions() noexcept = default;
    ComponentActions(const ComponentActions&) noexcept = default;
    ComponentActions& operator=(const ComponentActions&) noexcept = default;
    ComponentActions(ComponentActions&&) noexcept = default;
    ComponentActions& operator=(ComponentActions&&) noexcept = default;
    ~ComponentActions() = default;
  };

  // A caller's action reader as ComponentActions. Generic over the caller's reader.
  template <typename Reader>
  class [[tbc::generic]] ComponentActionsOf final : public ComponentActions {
  public:
    explicit ComponentActionsOf(Reader& reader) noexcept
        : reader_(reader) {}

    [[nodiscard]] ds::Option<BindingAction> read(const runtime::lua::Value& value) override {
      return reader_.read(value);
    }

  private:
    Reader& reader_;
  };

  using StagedActionReferences = ActionReferences<features::components::StagedContent::capacity.actions>;

  extern template class ActionReferences<features::components::StagedContent::capacity.actions>;
  extern template void StagedActionReferences::keepOnly<features::components::bar_capacity>(const features::components::Content<features::components::bar_capacity>& content);
  extern template void StagedActionReferences::keepOnly<features::components::panel_capacity>(const features::components::Content<features::components::panel_capacity>& content);

  // Numbers each extended action the reader reads and keeps it in `references` until the fit
  // decides which ones stay.
  class ComponentActionReader final : public ComponentActions {
  public:
    explicit ComponentActionReader(ComponentActions& reader, StagedActionReferences& references, std::uint32_t& next_reference) noexcept;

    [[nodiscard]] ds::Option<BindingAction> read(const runtime::lua::Value& value) override;

  private:
    ComponentActions& reader_;
    StagedActionReferences& references_;
    std::uint32_t& next_reference_;
  };

  enum class ComponentSurface : std::uint8_t {
    bar,
    panel,
  };

  class ContentReader {
    using Place = runtime::config::ComponentPlace;
    using Position = runtime::config::ComponentPosition;
    using Parent = runtime::config::ComponentParent;
    using Shape = runtime::config::ComponentShape;

  public:
    static_assert(features::components::Node::no_parent == Position::no_parent && features::components::Node::default_priority == Position::default_priority);

    explicit ContentReader(lua_State& state, ComponentActions& actions, runtime::config::LimitNotices& limits, features::components::StagedContent& staged, ComponentSurface surface = ComponentSurface::bar);

    // Count before retaining actions so omitted components cannot retain commands.
    template <features::components::Capacity Bounds>
    void read(const runtime::lua::Value& value, features::components::Content<Bounds>& output);

  private:
    // What the walk builds from each component it places.
    struct Builder {
      ds::Option<Parent> node(const runtime::lua::Value& value, const Shape& shape, const Position& position);

      ds::Option<Parent> append(const runtime::lua::Value& value, const Shape& shape, features::components::Input& input, const Position& position);

      static runtime::config::ComponentBudget::Usage usage(const Shape& shape) noexcept;

      void report(features::components::Capacity bounds);

      ComponentActions& actions_;
      runtime::config::LimitNotices& limits_;
      features::components::StagedContent& staged_;
      ComponentSurface surface_ = ComponentSurface::bar;
      runtime::config::ComponentBudget budget_{};
      runtime::config::ComponentBudget::Usage demand_{};
      features::components::StagedContent::Parents had_children_{};
      bool counting_ = true;
    };

    lua_State& state_;
    Builder builder_;
  };

  extern template void ContentReader::read<features::components::bar_capacity>(const runtime::lua::Value& value, features::components::BarContent& output);
  extern template void ContentReader::read<features::components::panel_capacity>(const runtime::lua::Value& value, features::components::PanelContent& output);

  template <features::components::Capacity Bounds>
  class ComponentSnapshot {
  public:
    explicit ComponentSnapshot(lua_State& state) noexcept;

    void read(const runtime::lua::Value& value, ComponentActions& actions, runtime::config::LimitNotices& limits, features::components::StagedContent& staged, std::uint32_t& next_reference);

    [[nodiscard]] const features::components::Content<Bounds>& content() const noexcept;

    [[nodiscard]] bool contains(BindingAction action) const noexcept;

    void clear() noexcept;

  private:
    lua_State& state_;
    StagedActionReferences references_;
    features::components::Content<Bounds> content_;
  };

  using BarSnapshot = ComponentSnapshot<features::components::BarContent::capacity>;
  using PanelSnapshot = ComponentSnapshot<features::components::PanelContent::capacity>;

  extern template class ComponentSnapshot<features::components::bar_capacity>;
  extern template class ComponentSnapshot<features::components::panel_capacity>;

  // Calls a render function with the context the render sees, as a protected call runs it.
  class ComponentInvocation {
  public:
    // `field` names the function inside the referenced table; without it the reference is the
    // function. `item`, a JSON document, becomes the call's second argument.
    explicit ComponentInvocation(int reference, const features::components::Context& context, const char* field = "render", ds::Option<std::string_view> item = ds::none) noexcept;

    static int invoke(lua_State* state);

  private:
    void pushContext(lua_State* state) const;

    int reference_;
    const features::components::Context& context_;
    const char* field_;
    ds::Option<std::string_view> item_;
  };

}

export namespace telar::gui::application {

  // The components of a generation: their definitions and the content each bar and the panel last
  // rendered. It keeps the actions that content holds in the interpreter's registry.
  class ComponentConfiguration {
  public:
    explicit ComponentConfiguration(lua_State& state);

    [[nodiscard]] const features::components::Definitions& definitions() const noexcept;

    // Reads the bars' sources, the slots, the panels and the picks a client table defines, over
    // what the layers before it defined, and keeps their tables in the registry.
    void readDefinitions(const runtime::lua::Value& client);

    template <typename Actions>
    [[tbc::generic]] void readFixed(Actions& actions, runtime::config::LimitNotices& limits) {
      ComponentActionsOf<Actions> reader{actions};

      readFixedSources(reader, limits);
    }

    template <typename Actions>
    [[tbc::generic]] void readBar(features::components::Position position, const runtime::lua::Value& value, Actions& actions, runtime::config::LimitNotices& limits) {
      ComponentActionsOf<Actions> reader{actions};

      readBarContent(position, value, reader, limits);
    }

    template <typename Actions>
    [[tbc::generic]] void readPanel(const runtime::lua::Value& value, Actions& actions, runtime::config::LimitNotices& limits) {
      ComponentActionsOf<Actions> reader{actions};

      readPanelContent(value, reader, limits);
    }

    [[nodiscard]] const features::components::BarContent& bar(features::components::Position position) const;

    [[nodiscard]] const features::components::PanelContent& panel() const noexcept;

    void closePanel() noexcept;

    [[nodiscard]] bool contains(BindingAction action) const noexcept;

    template <typename Visitor>
    [[tbc::generic]] void visitActions(const Visitor& visitor) const {
      const auto visit = [&](const auto& content) {
        for (const auto& node : content.nodes()) {
          if (const auto action = content.action(node)) {
            visitor(*action);
          }
        }
      };

      for (const auto& bar : bars_) {
        visit(bar.content());
      }

      visit(panel_.content());
    }

  private:
    // Keeps the source's table in the registry, where its render function and command are.
    [[nodiscard]] features::components::Source readSource(const runtime::lua::Value& value, bool panel = false);

    [[nodiscard]] features::components::Source readSource(const runtime::lua::Value& value, const runtime::config::SourceSetting& setting);

    void readFixedSources(ComponentActions& actions, runtime::config::LimitNotices& limits);

    void readBarContent(features::components::Position position, const runtime::lua::Value& value, ComponentActions& actions, runtime::config::LimitNotices& limits);

    void readPanelContent(const runtime::lua::Value& value, ComponentActions& actions, runtime::config::LimitNotices& limits);

    lua_State& state_;
    features::components::Definitions definitions_;
    ds::Array<BarSnapshot, features::components::Definitions::positions> bars_;
    PanelSnapshot panel_;
    features::components::StagedContent staged_;
    std::uint32_t next_reference_ = 0;
  };

  // Each read replaces output in place: a PickItems takes 432 KiB, too large to stage on
  // the Lua thread's stack. After a failure output holds the options read before it, so a
  // caller that must keep its last complete list reads into a fresh PickItems.
  class PickItemsReader {
  public:
    static void read(const runtime::lua::Value& value, features::components::PickItems& output, runtime::config::LimitNotices& limits);

    // The options a pick definition lists.
    static void definition(const runtime::lua::Value& pick, features::components::PickItems& output, runtime::config::LimitNotices& limits);

    static void lines(std::string_view text, features::components::PickItems& output, runtime::config::LimitNotices& limits);

  private:
    template <typename Read>
    static void keep(const Read& read, features::components::PickItems& output, runtime::config::LimitNotices& limits);
  };

}
