module telar.gui.ui.app.chrome.components;

import std;
import telar.gui.qt;
import telar.gui.ui.design.elements;
import telar.gui.ui.kit.config;
import telar.gui.ui.kit.machines;
import telar.gui.ui.kit.models;
import telar.gui.ui.kit.process.surface_command;
import telar.gui.application;
import telar.base.ds;
import telar.wire.vocabulary;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  namespace {

    using Clock = ComponentSlotState::Clock;

    void registerComponentFonts() {
      static const bool ready = [] {
        constexpr ds::Array paths{":/telar/fonts/IBMPlexSans-Regular.ttf", ":/telar/fonts/IBMPlexSans-SemiBold.ttf", ":/telar/fonts/SymbolsNerdFontMono-Regular.ttf", ":/telar/fonts/JetBrainsMono-Regular.ttf", ":/telar/fonts/TelarForma-Regular.ttf"};

        for (const auto* const path : paths) {
          if (QFontDatabase::addApplicationFont(QString::fromLatin1(path)) < 0) {
            throw std::runtime_error{"Could not register a bundled UI font"};
          }
        }

        return true;
      }();

      static_cast<void>(ready);
    }

    ComponentSlotState& surfaceState(ComponentSurfaceState& state, std::size_t index, bool panel) {
      return panel ? state.panel : state.bars.atCheckedMut(index);
    }

    const ComponentSlotState& surfaceState(const ComponentSurfaceState& state, std::size_t index, bool panel) {
      return panel ? state.panel : state.bars.at(index);
    }

    const application::components::Source& surfaceSource(const application::components::Definitions& definitions, std::size_t index, bool panel) {
      if (!panel) {
        return definitions.source(static_cast<application::components::Position>(index));
      }

      const auto panels = definitions.panels();
      if (index >= panels.size()) {
        throw std::out_of_range{"Panel is no longer configured"};
      }

      return panels[index].source;
    }

    QString commandError(SurfaceCommandFailure failure) {
      switch (failure) {
      case SurfaceCommandFailure::launch:
        return u"Could not launch command"_s;
      case SurfaceCommandFailure::process:
        return u"Command failed"_s;
      case SurfaceCommandFailure::timeout:
        return u"Command timed out"_s;
      case SurfaceCommandFailure::cancelled:
        return u"Command cancelled"_s;
      case SurfaceCommandFailure::invalid_output:
        return u"Command returned invalid text"_s;
      }

      return {};
    }

    template <application::components::Capacity Bounds>
    Clock::time_point nextClock(const application::components::Content<Bounds>& content) {
      constexpr auto second = std::chrono::milliseconds{1000};
      constexpr auto minute = second * 60;
      auto period = minute;
      bool found = false;

      for (const auto& node : content.nodes()) {
        if (node.kind == application::components::Kind::clock) {
          found = true;
          if (application::components::Clock::showsSeconds(content.text(node.text))) {
            period = second;
            break;
          }
        }
      }

      if (!found) {
        return Clock::time_point::max();
      }

      const auto wall = QDateTime::currentMSecsSinceEpoch();

      return Clock::now() + std::chrono::milliseconds{period.count() - (wall % period.count())};
    }

  }

  BindingContext sessionBindingContext(const GuiSession& session) {
    BindingContext context{.sidebar_visible = session.configuration.sidebar_visible};
    const auto* active = session.activeTab();
    if (active == nullptr) {
      return context;
    }

    context.focused_pane_id = active->focused_pane;
    context.active_tab_index = active->position;
    context.pane_count = static_cast<std::uint16_t>(std::ranges::count_if(active->layout.nodes(), [](const auto& node) {
      return std::holds_alternative<ClientLayoutPane>(node);
    }));

    context.tab_count = static_cast<std::uint16_t>(std::ranges::count_if(session.tabs, [&](const auto& tab) {
      return sameWorkspace(tab->location.workspace, active->location.workspace);
    }));

    return context;
  }

  ComponentsController::ComponentsController(Store& store, ConfigurationSource& configuration, ElementSlots& elements, ApplicationAllocator& memory, QObject* parent)
      : QObject(parent),
        store_(store),
        configuration_(configuration),
        elements_(elements),
        memory_(memory),
        pick_(*this, memory, configuration) {
    registerComponentFonts();
    timer_.setSingleShot(true);
    connect(&timer_, &QTimer::timeout, this, &ComponentsController::tick);
    connect(qobject_cast<QGuiApplication*>(QCoreApplication::instance()), &QGuiApplication::applicationStateChanged, this, [this](Qt::ApplicationState state) {
      if (state == Qt::ApplicationActive) {
        project();
        tick();
      }
    });
  }

  void ComponentsController::configure() {
    if (surfaces_.generation != configuration_.configurationGeneration()) {
      reset();
    } else {
      changed();
    }
  }

  bool ComponentsController::panelOpen() const noexcept {
    return surfaces_.open_panel.hasValue();
  }

  bool ComponentsController::panelCurrent() const noexcept {
    return surfaces_.open_panel && surfaces_.generation == configuration_.configurationGeneration();
  }

  ds::Option<ComponentsController::Activation> ComponentsController::activation(int source, int node, const QString& generation, const QString& revision) const {
    if (source < 0 || node < 0 || generation != QString::number(surfaces_.generation)) {
      return ds::none;
    }

    const auto index = static_cast<std::size_t>(source);
    const bool panel = index == ComponentSurfaceState::bar_slots;
    if (configuration_.definitions() == nullptr || index > ComponentSurfaceState::bar_slots || (panel && !surfaces_.open_panel)) {
      return ds::none;
    }

    const auto& state = surfaceState(surfaces_, index, panel);
    if (revision != QString::number(state.revision)) {
      return ds::none;
    }

    const auto activate = [&](const auto* rendered) -> ds::Option<Activation> {
      if (rendered == nullptr || static_cast<std::size_t>(node) >= rendered->content.nodes().size() || node >= state.nodes.size()) {
        return ds::none;
      }

      const auto& content = rendered->content;
      const auto& item = content.nodes()[static_cast<std::size_t>(node)];

      return Activation{.action = content.action(item), .url = content.text(item.url), .identity = state.nodes.at(node).toMap().value(u"actionIdentity"_s).toString(), .actions = &rendered->actions};
    };

    return panel ? activate(state.panel.get()) : activate(bar(index));
  }

  PickOwner ComponentsController::pickOwner() const {
    const auto& client = store_.client(store_.machines().active());

    return {.source = client.key, .runtime = client.runtime_generation, .generation = configuration_.configurationGeneration()};
  }

  bool ComponentsController::pickOwnerCurrent(const PickOwner& owner) const {
    return commandCurrent(owner.generation, owner.source, owner.runtime);
  }

  application::components::Context ComponentsController::pickContext() const {
    return context();
  }

  // A pick's choice may change what any surface shows: each renders again now.
  void ComponentsController::pickCommitted() {
    const auto now = ComponentSlotState::Clock::now();

    for (auto& state : surfaces_.bars.viewMut()) {
      state.next = now;
    }

    if (surfaces_.open_panel) {
      surfaces_.panel.next = now;
    }

    timer_.start(std::chrono::milliseconds{0});
  }

  void ComponentsController::pickFailed(const QString& message) {
    failed(message);
  }

  QVariantMap ComponentsController::pick() const {
    auto state = pick_.state();

    if (pick_.isOpen()) {
      state.insert(u"geometry"_s, pickGeometry());
    }

    return state;
  }

  QVariantMap ComponentsController::pickGeometry() const {
    const auto density = display_.density;
    const Rect viewport{.width = static_cast<float>(display_.viewport.width), .height = static_cast<float>(display_.viewport.height)};
    const auto rows = static_cast<std::uint16_t>(std::min<std::size_t>(pick_.itemCount(), std::numeric_limits<std::uint16_t>::max()));
    const auto geometry = application::palette::PaletteGeometry::measure(viewport, display_.chrome, {.pick_rows = rows});
    const auto local = [&](Rect area) {
      area.x -= geometry.bounds.x;
      area.y -= geometry.bounds.y;

      return toQRectF(area, density);
    };

    return {
        {u"bounds"_s, toQRectF(geometry.bounds, density)},
        {u"heading"_s, local(geometry.heading)},
        {u"search"_s, local(geometry.search)},
        {u"results"_s, local(application::palette::PaletteGeometry::inset(geometry.results, display_.chrome.textPx(application::palette::PaletteRowWindow::content_inset)))},
        {u"footer"_s, local(geometry.footer)},
        {u"rowHeight"_s, static_cast<double>(geometry.row_height) / density},
    };
  }

  void ComponentsController::setDisplay(const application::window::DisplayMetrics& display) {
    display_ = display;
    if (pick_.isOpen()) {
      pickChanged();
    }
  }

  void ComponentsController::activate(int source, int node, const QString& generation, const QString& revision, const QPointF& anchor) {
    const auto pressed = activation(source, node, generation, revision);
    if (!pressed) {
      return;
    }

    const auto& action = pressed->action;
    ds::Option<application::terminal::links::LinkTarget> link;

    try {
      const auto named = action && action->kind == BindingActionKind::extended ? configuration_.namedAction(*action, pressed->actions) : ds::none;
      if (pressed->identity != componentActionIdentity(action, pressed->url, named)) {
        return;
      }

      if (!action && !pressed->url.empty()) {
        link = application::terminal::links::LinkTarget::fromUri(pressed->url);
      }
    } catch (const std::exception& error) {
      failed(QString::fromUtf8(error.what()));

      return;
    }

    if (action) {
      bindingRequested(*action, *pressed->actions, anchor);
    } else if (link) {
      linkRequested(*link);
    }
  }

  void ComponentsController::setWindow(QQuickWindow& window) {
    window_ = &window;
  }

  void ComponentsController::rememberPickFocus() {
    if (!pick_.isOpen()) {
      pick_return_focus_ = window_ != nullptr ? window_->activeFocusItem() : nullptr;
    }
  }

  void ComponentsController::openPick(std::size_t index) {
    pick_.open(index);
  }

  void ComponentsController::closePick() {
    const bool open = pick_.isOpen();

    pick_.close();
    if (open) {
      restorePickFocus();
    } else {
      pick_return_focus_.clear();
    }
  }

  void ComponentsController::restorePickFocus() {
    const auto target = std::exchange(pick_return_focus_, {});

    if (panelCurrent()) {
      if (target != nullptr && target->window() == window_ && target->isVisible() && target->isEnabled()) {
        target->forceActiveFocus(Qt::OtherFocusReason);
      }

      return;
    }

    focusRestoreRequested();
  }

  void ComponentsController::filterPick(const QString& query) {
    pick_.filter(query);
  }

  void ComponentsController::choosePick(int row, const QString& identity) {
    try {
      pick_.choose(row, identity);
      if (!pick_.isOpen()) {
        restorePickFocus();
      }
    } catch (const std::exception& error) {
      failed(QString::fromUtf8(error.what()));
    }
  }

  bool ComponentsController::pickOpen() const {
    return pick_.isOpen();
  }

  QVariantMap ComponentsController::elementBars() const {
    return element_bars_;
  }

  void ComponentsController::refreshElementBars(const QVariantMap& item) {
    elements_.begin(ElementSlots::bar_slots);
    if (!elements_.active()) {
      elements_.finish(ElementSlots::bar_slots);
      if (!element_bars_.isEmpty()) {
        element_bars_.clear();
        elementBarsChanged();
      }

      return;
    }

    auto bars = elements_.elements(ElementSlots::bar_slots, u"window"_s, item);

    elements_.finish(ElementSlots::bar_slots);
    if (bars != element_bars_) {
      element_bars_ = std::move(bars);
      elementBarsChanged();
    }
  }

  application::components::Context ComponentsController::context() const {
    const auto local = QDateTime::currentDateTime();
    const auto date = local.date();
    const auto time = local.time();
    constexpr int days_per_week = 7;
    application::components::Context context;

    context.client = sessionBindingContext(store_.session());
    context.time = {
        .unix_seconds = local.toSecsSinceEpoch(),
        .year = static_cast<std::uint16_t>(date.year()),
        .month = static_cast<std::uint8_t>(date.month()),
        .day = static_cast<std::uint8_t>(date.day()),
        .hour = static_cast<std::uint8_t>(time.hour()),
        .minute = static_cast<std::uint8_t>(time.minute()),
        .second = static_cast<std::uint8_t>(time.second()),
        .weekday = static_cast<std::uint8_t>(date.dayOfWeek() % days_per_week),
    };

    const auto& sample = application::status_bar::metrics(store_.session()).sample();
    if (sample.revision != 0) {
      context.metrics = sample;
    }

    if (const auto* pane = store_.session().focusedPane()) {
      context.pane_title = pane->title;
    }

    return context;
  }

  void ComponentsController::reset() {
    command_.cancel();
    configuration_.closePanel();
    surfaces_ = {};
    surfaces_.generation = configuration_.configurationGeneration();
    surfaces_.epoch = ++next_revision_;
    const auto* definitions = configuration_.definitions();
    if (definitions != nullptr) {
      for (std::size_t index = 0; index < surfaces_.bars.size(); ++index) {
        auto& state = surfaces_.bars.atMut(index);

        state.revision = ++next_revision_;
        state.identity = state.revision;
        const auto kind = definitions->source(static_cast<application::components::Position>(index)).kind;
        if (kind == application::components::SourceKind::fixed || application::components::builtinSource(kind)) {
          projectSource(index, false);
        }
      }
    }

    changed();
    timer_.start(std::chrono::milliseconds{0});
  }

  void ComponentsController::projectSource(std::size_t index, bool panel) {
    const auto* definitions = configuration_.definitions();
    if (definitions == nullptr) {
      return;
    }

    auto& state = surfaceState(surfaces_, index, panel);
    const auto time = context().time;
    const auto& theme = configuration_.configuration().theme;
    const auto project = [&](const auto& content, const ConfigurationSource::Actions& actions) {
      const auto resolve = [&](BindingAction action) {
        return configuration_.namedAction(action, &actions);
      };

      state.nodes = componentRecords(content, theme, time, resolve);
      state.clock_next = nextClock(content);
    };

    const auto kind = panel ? application::components::SourceKind::dynamic : definitions->source(static_cast<application::components::Position>(index)).kind;

    if (panel) {
      if (state.panel) {
        project(state.panel->content, state.panel->actions);
      } else {
        state.nodes.clear();
        state.clock_next = Clock::time_point::max();
      }
    } else if (application::components::builtinSource(kind)) {
      const ConfigurationSource::Actions none{memory_};

      state.nodes = componentRecords(application::components::builtinContent(kind), theme, time, [&](BindingAction action) {
        return configuration_.namedAction(action, &none);
      });

      state.clock_next = Clock::time_point::max();
    } else if (const auto* content = bar(index)) {
      project(content->content, content->actions);
    } else {
      state.nodes.clear();
      state.clock_next = Clock::time_point::max();
    }

    state.revision = ++next_revision_;
  }

  const ComponentSlotState::Bar* ComponentsController::bar(std::size_t index) const {
    const auto* definitions = configuration_.definitions();
    const auto position = static_cast<application::components::Position>(index);
    if (definitions != nullptr && definitions->source(position).kind == application::components::SourceKind::fixed) {
      return configuration_.fixedBar(position);
    }

    return surfaces_.bars.at(index).bar.get();
  }

  // An action is still valid only while the content that offered it is on screen.
  bool ComponentsController::actionsLive(const ConfigurationSource::Actions& actions) const {
    for (std::size_t index = 0; index < surfaces_.bars.size(); ++index) {
      const auto* shown = bar(index);
      if (shown != nullptr && &shown->actions == &actions) {
        return true;
      }
    }

    const auto& panel = surfaces_.panel.panel;

    return (panel && &panel->actions == &actions) || elements_.owns(actions);
  }

  void ComponentsController::project() {
    for (std::size_t index = 0; index < surfaces_.bars.size(); ++index) {
      projectSource(index, false);
    }

    if (surfaces_.open_panel) {
      projectSource(*surfaces_.open_panel, true);
    }

    changed();
  }

  bool ComponentsController::commandCurrent(std::uint64_t generation, application::machines::MachineClientKey source, std::uint64_t runtime) const {
    const auto* client = store_.find(source);

    return generation == configuration_.configurationGeneration() && client != nullptr && client->key.machine.slot == store_.machines().active() && client->runtime_generation == runtime;
  }

  void ComponentsController::render(std::size_t index, bool panel) {
    const auto* definitions = configuration_.definitions();
    if (definitions == nullptr) {
      return;
    }

    const auto& source = surfaceSource(*definitions, index, panel);
    auto& state = surfaceState(surfaces_, index, panel);
    if (state.rendering || (source.kind == application::components::SourceKind::command && command_.active())) {
      return;
    }

    state.next = source.interval ? Clock::now() + *source.interval : Clock::time_point::max();
    try {
      if (source.kind == application::components::SourceKind::dynamic) {
        applyRender(index, panel, context());
      } else if (source.kind == application::components::SourceKind::command) {
        const auto& client = store_.client(store_.machines().active());
        const ComponentCommandOwner owner{
            .index = index,
            .panel = panel,
            .generation = configuration_.configurationGeneration(),
            .panel_identity = surfaces_.panel_identity,
            .source = client.key,
            .runtime = client.runtime_generation,
        };

        SurfaceCommandRequest request;

        request.arguments = configuration_.commandArguments(source.reference, "command");
        request.timeout = source.timeout;
        request.output = source.has_render ? SurfaceOutputUse::lines : SurfaceOutputUse::line;
        command_owner_ = owner;
        command_.start(request, [this, owner](const SurfaceCommandResult& result) {
          commandFinished(owner, result);
        });
      }
    } catch (const std::exception& error) {
      state.error = toQString(error.what());
    }

    changed();
  }

  // The render runs on the Lua thread; its result replaces the surface only if nothing that
  // owned the surface changed meanwhile.
  void ComponentsController::applyRender(std::size_t index, bool panel, const application::components::Context& context, bool truncated) {
    auto& state = surfaceState(surfaces_, index, panel);
    const auto epoch = surfaces_.epoch;
    const auto identity = surfaces_.panel_identity;
    const auto finish = [this, index, panel, epoch, identity, truncated](auto outcome) {
      const bool same_panel = !panel || (surfaces_.open_panel == index && surfaces_.panel_identity == identity);
      if (epoch != surfaces_.epoch || !same_panel) {
        return;
      }

      auto& current = surfaceState(surfaces_, index, panel);

      current.rendering = false;
      if (outcome.stale) {
        return;
      }

      if (!outcome.value) {
        current.error = outcome.error;
      } else {
        if constexpr (std::is_same_v<decltype(outcome.value.getMut()), ConfigurationSource::PanelRender&>) {
          current.panel = std::move(outcome.value.getMut()).intoShared();
          surfaces_.last_render_ms = QDateTime::currentMSecsSinceEpoch();
        } else {
          current.bar = std::move(outcome.value.getMut()).intoShared();
        }

        current.error = truncated ? u"Command output exceeded its limit; showing what fits"_s : QString{};
        projectSource(index, panel);
      }

      changed();
      timer_.start(std::chrono::milliseconds{0});
    };

    state.rendering = true;
    if (panel) {
      configuration_.renderPanel(index, context, finish);
    } else {
      configuration_.renderBar(static_cast<application::components::Position>(index), context, finish);
    }
  }

  void ComponentsController::commandFinished(const ComponentCommandOwner& owner, const SurfaceCommandResult& result) {
    command_owner_.reset();
    const bool same_panel = !owner.panel || (surfaces_.open_panel == owner.index && surfaces_.panel_identity == owner.panel_identity);
    if (!commandCurrent(owner.generation, owner.source, owner.runtime) || !same_panel) {
      timer_.start(std::chrono::milliseconds{0});
      return;
    }

    auto& state = surfaceState(surfaces_, owner.index, owner.panel);

    try {
      if (result.failure) {
        state.error = commandError(*result.failure);
      } else {
        auto rendered = context();

        rendered.output = std::string_view{result.output.constData(), static_cast<std::size_t>(result.output.size())};
        applyRender(owner.index, owner.panel, rendered, result.truncated);
      }
    } catch (const std::exception& error) {
      state.rendering = false;
      state.error = toQString(error.what());
    }

    changed();

    timer_.start(std::chrono::milliseconds{0});
  }

  void ComponentsController::tick() {
    if (configuration_.definitions() == nullptr) {
      return;
    }

    const auto now = Clock::now();
    bool rendered = false;
    // Projecting a source may change the surfaces, so each step reads them again.
    const auto tick = [&](std::size_t index, bool panel) {
      const auto* definitions = configuration_.definitions();
      if (definitions == nullptr) {
        return;
      }

      const auto source = surfaceSource(*definitions, index, panel);

      if (surfaceState(surfaces_, index, panel).clock_next <= now) {
        projectSource(index, panel);
        changed();
      }

      const auto& state = surfaceState(surfaces_, index, panel);
      const bool live = source.kind == application::components::SourceKind::dynamic || source.kind == application::components::SourceKind::command;
      if (!rendered && live && !state.rendering && state.next <= now && (source.kind != application::components::SourceKind::command || !command_.active())) {
        rendered = true;
        render(index, panel);
      }
    };

    if (surfaces_.open_panel) {
      tick(*surfaces_.open_panel, true);
    }

    for (std::size_t index = 0; index < surfaces_.bars.size(); ++index) {
      tick(index, false);
    }

    arm();
  }

  void ComponentsController::arm() {
    const auto* definitions = configuration_.definitions();
    if (definitions == nullptr) {
      return;
    }

    auto next = Clock::time_point::max();
    const auto consider = [&](std::size_t index, bool panel) {
      const auto& state = surfaceState(surfaces_, index, panel);
      const auto& source = surfaceSource(*definitions, index, panel);

      next = std::min(next, state.clock_next);
      const bool live = source.kind == application::components::SourceKind::dynamic || source.kind == application::components::SourceKind::command;
      if (live && !state.rendering && (source.kind != application::components::SourceKind::command || !command_.active())) {
        next = std::min(next, state.next);
      }
    };

    for (std::size_t index = 0; index < surfaces_.bars.size(); ++index) {
      consider(index, false);
    }

    if (surfaces_.open_panel) {
      consider(*surfaces_.open_panel, true);
    }

    if (next != Clock::time_point::max()) {
      const auto delay = std::max(std::chrono::milliseconds{0}, std::chrono::ceil<std::chrono::milliseconds>(next - Clock::now()));

      timer_.start(delay);
    }
  }

  QVariantMap ComponentsController::bars() const {
    constexpr ds::Array names{"left", "center", "right", "top", "footerLeft", "footerCenter", "footerRight"};
    constexpr ds::Array kinds{"empty", "tabs", "metrics", "machines", "content", "content", "content"};
    const application::components::Definitions defaults;
    const auto* configured = configuration_.definitions();
    const auto& definitions = configured == nullptr ? defaults : *configured;
    QVariantMap result;

    for (std::size_t index = 0; index < names.size(); ++index) {
      const auto& state = surfaces_.bars[index];

      result.insert(QString::fromLatin1(names[index]), QVariantMap{
                                                           {u"kind"_s, QString::fromLatin1(kinds[static_cast<std::size_t>(definitions.source(static_cast<application::components::Position>(index)).kind)])},
                                                           {u"source"_s, static_cast<int>(index)},
                                                           {u"nodes"_s, state.nodes},
                                                           {u"error"_s, state.error},
                                                           {u"generation"_s, QString::number(surfaces_.generation)},
                                                           {u"revision"_s, QString::number(state.revision)},
                                                           {u"identity"_s, QString::number(state.identity)},
                                                       });
    }

    return result;
  }

  QVariantMap ComponentsController::panel() const {
    const auto* definitions = configuration_.definitions();
    if (!surfaces_.open_panel || definitions == nullptr || *surfaces_.open_panel >= definitions->panels().size()) {
      return {{u"open"_s, false}};
    }

    const auto& definition = definitions->panels()[*surfaces_.open_panel];
    const auto& state = surfaces_.panel;

    return {
        {u"open"_s, true},
        {u"title"_s, toQString(definition.heading.title.view())},
        {u"width"_s, definition.width},
        {u"nodes"_s, state.nodes},
        {u"error"_s, state.error},
        {u"renderedAt"_s, surfaces_.last_render_ms},
        {u"generation"_s, QString::number(surfaces_.generation)},
        {u"revision"_s, QString::number(state.revision)},
        {u"identity"_s, QString::number(state.identity)},
        {u"source"_s, static_cast<int>(ComponentSurfaceState::bar_slots)},
        {u"anchor"_s, surfaces_.panel_anchor},
    };
  }

  void ComponentsController::togglePanel(std::size_t index, QPointF anchor) {
    const auto* definitions = configuration_.definitions();
    if (definitions == nullptr || index >= definitions->panels().size()) {
      return;
    }

    if (surfaces_.open_panel == index) {
      closePanel();
      return;
    }

    closePanel();
    surfaces_.open_panel = index;
    surfaces_.panel_anchor = anchor;
    surfaces_.panel_identity = ++next_revision_;
    surfaces_.panel.revision = surfaces_.panel_identity;
    surfaces_.panel.identity = surfaces_.panel_identity;
    timer_.start(std::chrono::milliseconds{0});
    changed();
  }

  void ComponentsController::closePanel() {
    if (command_owner_ && command_owner_->panel) {
      command_.cancel();
    }

    surfaces_.open_panel.reset();
    surfaces_.panel = {};
    surfaces_.last_render_ms = 0;
    configuration_.closePanel();
    changed();
    arm();
  }

  void ComponentsController::refreshPanel() {
    if (surfaces_.open_panel) {
      surfaces_.panel.next = Clock::now();
      timer_.start(std::chrono::milliseconds{0});
    }
  }

}
