module telar.gui.ui.app.chrome.components.machine_chrome;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.machines;
import telar.gui.ui.kit.models;
import telar.gui.foundation.drawing;
import telar.gui.application;
import telar.base.ds;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.config.core;
import telar.gui.foundation.agents;
import telar.gui.foundation.fonts;
import telar.gui.foundation.text;
import telar.tbc;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  namespace {

    constexpr std::string_view segment_suffix = " ▾";

    QString machineKey(application::machines::MachineToken token) {
      return u"machine:"_s + QString::number(token.slot) + QLatin1Char(':') + QString::number(token.generation);
    }

  }

  MachineChromeLayout::MachineChromeLayout(QQuickItem* parent)
      : QQuickItem(parent) {}

  MachineChromeController* MachineChromeLayout::controller() const noexcept {
    return controller_;
  }

  bool MachineChromeLayout::segment() const noexcept {
    return mode_ == Mode::segment;
  }

  bool MachineChromeLayout::shown() const noexcept {
    return shown_;
  }

  bool MachineChromeLayout::roster() const noexcept {
    return roster_;
  }

  void MachineChromeLayout::setRoster(bool roster) {
    if (roster_ == roster) {
      return;
    }

    roster_ = roster;
    items_.reconcile({});
    observeSources();
    invalidate();
    rosterChanged();
  }

  qreal MachineChromeLayout::preferredWidth() const noexcept {
    return preferred_width_;
  }

  qreal MachineChromeLayout::preferredHeight() const noexcept {
    return preferred_height_;
  }

  QAbstractItemModel* MachineChromeLayout::items() noexcept {
    return &items_;
  }

  QVariantMap MachineChromeLayout::style() const {
    return style_;
  }

  void MachineChromeLayout::setController(MachineChromeController* controller) {
    if (controller_ == controller) {
      return;
    }

    if (controller_ != nullptr) {
      disconnect(controller_, nullptr, this, nullptr);
    }

    controller_ = controller;
    if (controller_ != nullptr) {
      connect(controller_, &MachineChromeController::machinesChanged, this, &MachineChromeLayout::observeSources);
      // The display sizes the rows the list asks room for, so it is read again with the sources.
      connect(controller_, &MachineChromeController::changed, this, &MachineChromeLayout::observeSources);
      connect(controller_, &MachineChromeController::changed, this, &MachineChromeLayout::invalidate);
      connect(controller_, &QObject::destroyed, this, [this] {
        controller_ = nullptr;
        observeSources();
        controllerChanged();
      });
    }

    observeSources();
    invalidate();
    controllerChanged();
  }

  void MachineChromeLayout::setSegment(bool segment) {
    setMode(segment ? Mode::segment : Mode::list);
  }

  bool MachineChromeLayout::inlineFacts() const noexcept {
    return mode_ == Mode::facts;
  }

  void MachineChromeLayout::setInlineFacts(bool enabled) {
    setMode(enabled ? Mode::facts : Mode::list);
  }

  void MachineChromeLayout::setMode(Mode mode) {
    if (mode_ == mode) {
      return;
    }

    const auto previous = mode_;

    mode_ = mode;
    items_.reconcile({});
    observeSources();
    invalidate();
    if ((previous == Mode::segment) != (mode_ == Mode::segment)) {
      segmentChanged();
    }

    if ((previous == Mode::facts) != (mode_ == Mode::facts)) {
      inlineFactsChanged();
    }
  }

  MachineChromeLayout::Source MachineChromeLayout::observe(application::machines::Machines::Slot slot) const {
    const auto& machines = controller_->store().machines();
    const auto& row = machines.row(slot);
    Source source{.token = machines.token(slot), .color = row.color, .active = slot == machines.active(), .attention = row.attention, .live = row.live, .phase = inlineFacts() ? row.phase : application::machines::MachinePhase::connecting, .cpu_percent = inlineFacts() ? row.cpu_percent : ds::none};

    source.label.assign(application::machines::MachineChromeGeometry::shownLabel(row.label.view()));

    if (mode_ == Mode::list && (roster_ || !source.active)) {
      collectCards(slot, source);
    }

    // The sidebar already lists the active machine's agents: its row keeps their count only.
    if (source.active) {
      source.card_count = 0;
    }

    return source;
  }

  void MachineChromeLayout::publishRows(std::size_t rows) {
    qreal height = 0;

    if (mode_ == Mode::list && controller_ != nullptr && controller_->display().density > 0) {
      height = static_cast<qreal>(application::machines::MachineChromeGeometry::listHeight(controller_->display().chrome, rows)) / controller_->display().density;
    }

    if (std::not_equal_to<>{}(height, preferred_height_)) {
      preferred_height_ = height;
      rowsChanged();
    }
  }

  void MachineChromeLayout::observeSources() {
    ds::Array<ds::Option<Source>, application::machines::MachineLimits::window_slots> incoming;
    // The roster names the only machine too: its menu is where another one is added.
    const bool shown = controller_ != nullptr && controller_->store().machines().count() > (roster_ ? 0U : 1U);
    const bool attention = controller_ != nullptr && controller_->store().machines().attentionElsewhere();
    std::size_t rows = 0;

    if (controller_ != nullptr) {
      for (std::size_t index = 0; index < incoming.size(); ++index) {
        const auto slot = static_cast<application::machines::Machines::Slot>(index);
        if (!controller_->store().machines().shown(slot)) {
          continue;
        }

        incoming.atMut(index) = observe(slot);
        rows += static_cast<std::size_t>(roster_ || !incoming[index]->active);
      }
    }

    publishRows(shown ? rows : 0);
    if (incoming != sources_ || attention != attention_elsewhere_) {
      sources_ = std::move(incoming);
      attention_elsewhere_ = attention;
      invalidate();
    }

    if (shown_ != shown) {
      shown_ = shown;
      invalidate();
      shownChanged();
    }
  }

  void MachineChromeLayout::invalidate() {
    polish();
  }

  void MachineChromeLayout::bindWindow() {
    disconnect(font_connection_);
    catalog_ = nullptr;
    fonts_.reset();
    if (window() != nullptr) {
      catalog_ = &WindowFontCatalog::forWindow(*window());
      font_connection_ = connect(catalog_, &WindowFontCatalog::fontsChanged, this, &MachineChromeLayout::invalidate);
    }

    invalidate();
  }

  float MachineChromeLayout::measure(std::string_view text, bool emphasized) const {
    const auto role = emphasized ? fonts::FontRole::emphasized : fonts::FontRole::regular;

    // The window owns its catalog; this layout only observes it.
    tbc::raw(catalog_.data())->request(text, role);
    const auto size = mode_ == Mode::facts ? chrome_.small : chrome_.body;

    return static_cast<float>(fonts::TextLayout<ConcurrentMemory>::measure(*fonts_, text, {.pixel_height = size, .preferred = role}));
  }

  QColor MachineChromeLayout::ink(std::string_view written) const {
    return controller_->ink(written);
  }

  QColor MachineChromeLayout::fill(CellColor value) const {
    return controller_->fill(value);
  }

  QVariantMap MachineChromeLayout::geometryRecord(const application::machines::MachineChromeGeometry::Control& geometry) const {
    return {
        {u"bounds"_s, toQRectF(geometry.bounds, density_)},
        {u"labelBounds"_s, toQRectF(geometry.label, density_)},
        {u"discBounds"_s, toQRectF(geometry.disc, density_)},
        {u"attentionBounds"_s, toQRectF(geometry.attention, density_)},
        {u"radius"_s, static_cast<qreal>(geometry.radius) / density_},
    };
  }

  QVariantMap MachineChromeLayout::controlRecord(const Source& source, Rect bounds, float advance) const {
    using Geometry = application::machines::MachineChromeGeometry;
    const bool segment = mode_ == Mode::segment;
    const bool attention = segment ? attention_elsewhere_ : source.attention && !source.active;
    const auto geometry = Geometry::control(bounds, chrome_, segment ? Geometry::Kind::segment : Geometry::Kind::switcher, advance, attention);
    auto record = geometryRecord(geometry);

    record.insert(u"key"_s, segment ? u"machine:picker"_s : machineKey(source.token));
    record.insert(u"text"_s, toQString(source.label.view()) + (segment ? u" ▾"_s : QString{}));
    record.insert(u"accessible"_s, segment ? u"Switch machine"_s : toQString(source.label.view()));
    record.insert(u"active"_s, !segment && source.active);
    record.insert(u"bold"_s, segment || source.active);
    record.insert(u"ink"_s, ink(source.color.view()));
    record.insert(u"enabled"_s, segment || source.live);

    return record;
  }

  void MachineChromeLayout::rebuild() {
    if (controller_ == nullptr || window() == nullptr || !shown_ || height() <= 0) {
      items_.reconcile({});
      if (std::not_equal_to<>{}(preferred_width_, 0)) {
        preferred_width_ = 0;
        layoutChanged();
      }

      return;
    }

    if (catalog_ == nullptr) {
      bindWindow();
    }

    density_ = window()->effectiveDevicePixelRatio();
    chrome_ = controller_->display().chrome;
    fonts_ = ResidentFonts::shared(catalog_->collection());
    const auto& theme = controller_->configuration().theme;
    auto active_background = toQColor(theme.chromeColor(PaletteRole::text));
    auto hover_background = active_background;

    active_background.setAlphaF(gui::ChromeStyle::selection_alpha);
    hover_background.setAlphaF(gui::ChromeStyle::hover_alpha);
    // The sidebar's rows sit beside its cards and follow the chrome text as they do.
    const auto length = [this](float logical) {
      return (mode_ == Mode::list ? static_cast<qreal>(chrome_.textPx(logical)) : static_cast<qreal>(chrome_.px(logical))) / density_;
    };

    QVariantMap style{
        {u"activeBackground"_s, active_background},
        {u"hoverBackground"_s, hover_background},
        {u"activeText"_s, toQColor(theme.chromeColor(PaletteRole::text))},
        {u"attention"_s, fill(theme.chrome[static_cast<std::size_t>(PaletteRole::yellow)])},
        {u"pixelSize"_s, (mode_ == Mode::facts ? chrome_.small : chrome_.body) / density_},
        {u"smallSize"_s, chrome_.small / density_},
        {u"rowRadius"_s, length(mode_ == Mode::list ? gui::ChromeStyle::surface_radius : gui::ChromeStyle::control_radius)},
        {u"tileWidth"_s, length(application::workbench::TabStripGeometry::tile_width)},
        {u"tileHeight"_s, length(application::workbench::TabStripGeometry::tile_height)},
        {u"tileRadius"_s, length(application::workbench::TabStripGeometry::tile_radius)},
    };

    if (mode_ == Mode::list) {
      const auto columns = application::machines::MachineChromeGeometry::listColumns(chrome_);

      style.insert(u"markCenter"_s, static_cast<qreal>(columns.mark_center) / density_);
      style.insert(u"textX"_s, static_cast<qreal>(columns.text_x) / density_);
    }

    QList<QVariantMap> records;
    const Rect area = isVisible() ? Rect{.width = static_cast<float>(width() * density_), .height = static_cast<float>(height() * density_)} : Rect{};
    qreal preferred = 0;

    switch (mode_) {
    case Mode::facts:
      preferred = factsRecords(area, records);
      break;
    case Mode::segment:
      preferred = segmentRecords(area, records);
      break;
    case Mode::list:
      preferred = listRecords(area, records);
      break;
    }

    if (style != style_ || std::not_equal_to<>{}(preferred, preferred_width_)) {
      style_ = std::move(style);
      preferred_width_ = preferred;
      layoutChanged();
    }

    items_.reconcile(std::move(records));
  }

  qreal MachineChromeLayout::segmentRecords(Rect area, QList<QVariantMap>& records) {
    for (const auto& source : sources_) {
      if (!source || !source->active) {
        continue;
      }

      BoundedText<application::machines::MachineLimits::label_bytes + segment_suffix.size()> text;

      text.append(source->label.view());
      text.append(segment_suffix);
      const auto advance = measure(text.view(), true);

      if (!area.empty()) {
        records.append(controlRecord(*source, area, advance));
      }

      return static_cast<qreal>(application::machines::MachineChromeGeometry::preferredSegment(chrome_, advance)) / density_;
    }

    return 0;
  }

  void MachineChromeLayout::collectCards(application::machines::Machines::Slot slot, Source& source) const {
    const auto& client = controller_->store().clients()[slot];
    if (!client || (*client)->phase != application::machines::MachinePhase::connected || !(*client)->session.ready()) {
      return;
    }

    const auto agents = std::span{(*client)->session.agents()};
    ds::Array<std::size_t, application::activity::AgentOrder::maximum_agents> chosen{};
    std::size_t count = 0;

    for (std::size_t index = 0; index < agents.size() && count < chosen.size(); ++index) {
      if (application::activity::AgentOrder::stacked(agents[index].status)) {
        chosen.atMut(count++) = index;
      }
    }

    const auto shown = std::min(count, stack_cards);
    auto stacked = chosen.viewMut().first(count);

    std::partial_sort(stacked.begin(), stacked.begin() + static_cast<std::ptrdiff_t>(shown), stacked.end(), [&](std::size_t left, std::size_t right) {
      return application::activity::AgentOrder::priority(agents[left]) < application::activity::AgentOrder::priority(agents[right]);
    });

    for (std::size_t rank = 0; rank < shown; ++rank) {
      const auto& agent = agents[chosen[rank]];

      source.cards.atMut(rank) = {.provider = static_cast<std::uint8_t>(agent.provider_kind), .status = static_cast<std::uint8_t>(agent.status)};
    }

    source.card_count = shown;
    source.agent_count = count;
  }

  QVariantMap MachineChromeLayout::listRecord(const Source& source, const application::machines::MachineChromeGeometry::ListRow& row) const {
    QVariantList cards;

    for (std::size_t rank = 0; rank < source.card_count; ++rank) {
      const auto card = source.cards[rank];
      const auto status = static_cast<AgentStatus>(card.status);
      const auto& pose = application::workbench::TabCardMotion::rest[rank];
      auto record = applicationMarkRecord(runtime::describeProvider(static_cast<AgentProvider>(card.provider)).display_name);

      record.insert(u"x"_s, static_cast<qreal>(chrome_.textPx(pose.x)) / density_);
      record.insert(u"y"_s, static_cast<qreal>(chrome_.textPx(pose.y)) / density_);
      record.insert(u"rotation"_s, pose.rotation);
      record.insert(u"scale"_s, pose.scale);
      record.insert(u"layer"_s, static_cast<int>(stack_cards - 1 - rank));
      // The row has no focused pane, so whichever card waits on the person is tinted, front one included.
      record.insert(u"attentionColor"_s, application::activity::AgentOrder::attention(status) == application::activity::AgentOrder::Attention::needs_input ? QString::fromLatin1(palette_names[static_cast<std::size_t>(AgentStatusPresentation::color(status))]) : QString{});
      cards.append(std::move(record));
    }

    const auto label = toQString(source.label.view());
    ds::Array<char, application::machines::MachineChromeGeometry::list_status_capacity> storage{};
    const auto status = application::machines::MachineChromeGeometry::listStatus(source.live, source.agent_count, storage.viewMut());

    return {
        {u"key"_s, machineKey(source.token)},
        {u"bounds"_s, toQRectF(row.bounds, density_)},
        {u"avatarBounds"_s, toQRectF(row.avatar, density_)},
        {u"dotBounds"_s, toQRectF(row.dot, density_)},
        {u"labelBounds"_s, toQRectF(row.label, density_)},
        {u"statusBounds"_s, toQRectF(row.status, density_)},
        {u"stackBounds"_s, toQRectF(row.stack, density_)},
        {u"markBounds"_s, toQRectF(row.mark, density_)},
        {u"text"_s, label},
        {u"initial"_s, MachineChromeController::initial(label)},
        {u"status"_s, toQString(status)},
        {u"ink"_s, ink(source.color.view())},
        {u"enabled"_s, source.live},
        {u"active"_s, source.active},
        {u"attention"_s, source.attention},
        {u"cards"_s, cards},
        {u"accessible"_s, label + (source.attention ? u", needs attention"_s : QString{}) + (source.card_count == 0 ? QString{} : u", "_s + QString::number(source.card_count) + u" agents active"_s)},
    };
  }

  qreal MachineChromeLayout::listRecords(Rect area, QList<QVariantMap>& records) {
    using Geometry = application::machines::MachineChromeGeometry;
    float widest = 0;
    std::size_t index = 0;

    for (const auto& source : sources_) {
      if (!source || (source->active && !roster_)) {
        continue;
      }

      const bool stacked = source->card_count != 0;
      ds::Array<char, Geometry::list_status_capacity> storage{};
      const auto status = Geometry::listStatus(source->live, source->agent_count, storage.viewMut());
      const auto advance = std::max(measure(source->label.view(), true), measure(status, false));

      widest = std::max(widest, Geometry::listNaturalWidth(chrome_, advance, stacked, roster_));
      // The sidebar sizes the area to the rows that fit; the item clips the rest.
      if (!area.empty()) {
        records.append(listRecord(*source, Geometry::listRow(area, chrome_, index, {.stacked = stacked, .marked = roster_, .described = !status.empty()})));
      }

      ++index;
    }

    return static_cast<qreal>(std::ceil(widest)) / density_;
  }

  QVariantMap MachineChromeLayout::factRecord(const Source& source, const application::machines::MachineFacts::Geometry& geometry) const {
    const auto glyph = application::machines::MachineFacts::glyph(source.phase, source.attention);
    const auto cpu = application::machines::MachineFacts::cpu(source.phase, source.cpu_percent);
    const auto role = application::machines::MachineFacts::glyphInk(source.phase, source.attention);

    return {
        {u"key"_s, machineKey(source.token)},
        {u"bounds"_s, toQRectF(geometry.bounds, density_)},
        {u"glyphBounds"_s, toQRectF(geometry.glyph, density_)},
        {u"labelBounds"_s, toQRectF(geometry.label, density_)},
        {u"cpuBounds"_s, toQRectF(geometry.cpu, density_)},
        {u"text"_s, toQString(source.label.view())},
        {u"glyph"_s, toQString(glyph)},
        {u"cpu"_s, toQString(cpu.view())},
        {u"bold"_s, source.active},
        {u"ink"_s, toQColor(controller_->configuration().theme.chromeColor(role))},
        {u"accessible"_s, toQString(source.label.view()) + u" "_s + toQString(application::machines::MachineFacts::phaseName(source.phase)) + (source.attention ? u" attention"_s : QString{}) + (cpu.view().empty() ? QString{} : u" "_s + toQString(cpu.view()))},
    };
  }

  qreal MachineChromeLayout::factsRecords(Rect area, QList<QVariantMap>& records) {
    auto left = area.x;
    bool any = false;

    for (const auto& source : sources_) {
      if (!source) {
        continue;
      }

      if (any) {
        left += chrome_.px(application::machines::MachineFacts::machine_gap);
      }

      const auto cpu = application::machines::MachineFacts::cpu(source->phase, source->cpu_percent);
      const application::machines::MachineFacts::Widths parts{.glyph = measure(application::machines::MachineFacts::glyph(source->phase, source->attention), false), .label = measure(source->label.view(), source->active), .cpu = cpu.view().empty() ? 0 : measure(cpu.view(), false)};
      const auto geometry = application::machines::MachineFacts::geometry({.x = left, .y = area.y, .height = area.height}, chrome_, parts);

      left = geometry.bounds.right();
      if (!area.empty()) {
        records.append(factRecord(*source, geometry));
      }

      any = true;
    }

    return (static_cast<qreal>(left - area.x)) / density_;
  }

  void MachineChromeLayout::activate(const QString& identity) {
    if (inlineFacts() || controller_ == nullptr || window() == nullptr || window() != controller_->window()) {
      return;
    }

    bool delivered = false;

    for (int index = 0; index < items_.rowCount(); ++index) {
      if (items_.data(items_.index(index), ListModel::record_role).toMap().value(u"key"_s).toString() == identity) {
        delivered = true;
        break;
      }
    }

    if (!delivered) {
      return;
    }

    if (identity == QLatin1StringView("machine:picker")) {
      controller_->pick();
      return;
    }

    for (const auto& source : sources_) {
      if (source && machineKey(source->token) == identity) {
        const auto token = source->token;

        controller_->select(token);

        return;
      }
    }
  }

  void MachineChromeLayout::updatePolish() {
    try {
      rebuild();
    } catch (const std::exception&) {
      items_.reconcile({});
    }
  }

  void MachineChromeLayout::geometryChange(const QRectF& current, const QRectF& previous) {
    QQuickItem::geometryChange(current, previous);
    invalidate();
  }

  void MachineChromeLayout::itemChange(ItemChange change, const ItemChangeData& data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemSceneChange) {
      bindWindow();
    } else if (change == ItemDevicePixelRatioHasChanged || change == ItemVisibleHasChanged) {
      invalidate();
    }
  }

}
