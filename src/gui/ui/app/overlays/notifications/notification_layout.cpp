module telar.gui.ui.app.overlays.notifications;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.models;
import telar.gui.ui.kit.scene;
import telar.gui.application;
import telar.base.ds;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.gui.foundation.fonts;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  namespace {

    QRectF logicalBounds(Rect bounds, qreal density) {
      return {static_cast<qreal>(bounds.x) / density, static_cast<qreal>(bounds.y) / density, static_cast<qreal>(bounds.width) / density, static_cast<qreal>(bounds.height) / density};
    }

    QString accent(NotificationLevel level) {
      switch (level) {
      case NotificationLevel::info:
        return u"blue"_s;
      case NotificationLevel::success:
        return u"green"_s;
      case NotificationLevel::warning:
        return u"yellow"_s;
      case NotificationLevel::failure:
        return u"red"_s;
      }

      return {};
    }

    QString symbol(NotificationLevel level) {
      switch (level) {
      case NotificationLevel::info:
        return u"i"_s;
      case NotificationLevel::success:
        return u"✓"_s;
      case NotificationLevel::warning:
        return u"!"_s;
      case NotificationLevel::failure:
        return u"×"_s;
      }

      return {};
    }

  }

  NotificationLayout::NotificationLayout(QQuickItem* parent)
      : QQuickItem(parent) {
    connect(&cards_, &QAbstractItemModel::rowsAboutToBeRemoved, this, [this](const QModelIndex&, int first, int last) {
      retireRemovedFocus(first, last);
    });

    bindWindow();
  }

  NotificationLayout::~NotificationLayout() {
    if (clock_) {
      clock_->detach(*this);
    }
  }

  NotificationsController* NotificationLayout::controller() const noexcept {
    return controller_;
  }

  void NotificationLayout::setController(NotificationsController* controller) {
    if (controller_ == controller) {
      return;
    }

    if (controller_) {
      disconnect(controller_, nullptr, this, nullptr);
    }

    controller_ = controller;
    if (controller_) {
      connect(controller, &NotificationsController::changed, this, &NotificationLayout::scheduleLayout);
      connect(controller, &NotificationsController::viewChanged, this, &NotificationLayout::scheduleLayout);
      connect(controller, &NotificationsController::displayChanged, this, &NotificationLayout::invalidate);
      connect(controller, &QObject::destroyed, this, &NotificationLayout::invalidate);
    }

    invalidate();
    controllerChanged();
  }

  QAbstractItemModel* NotificationLayout::cards() noexcept {
    return &cards_;
  }

  QRectF NotificationLayout::host() const noexcept {
    return host_;
  }

  QVariantMap NotificationLayout::style() const {
    return style_;
  }

  bool NotificationLayout::eligible() const noexcept {
    return controller_ && !controller_->center().items().empty() && isVisible() && width() > 0 && height() > 0;
  }

  ds::Option<std::uint64_t> NotificationLayout::deadline(std::uint64_t now_ns) const {
    if (!controller_ || controller_->center().items().empty()) {
      return ds::none;
    }

    const auto interval = clock_ ? clock_->frameInterval() : 1;
    const auto lifecycle = controller_->center().nextDeadline(now_ns, interval);
    const auto movement = stack_.nextDeadline(now_ns, interval);

    return movement && lifecycle ? std::min(*movement, *lifecycle) : lifecycle;
  }

  void NotificationLayout::sample(std::uint64_t now_ns) {
    now_ns_ = now_ns;
    polish();
  }

  void NotificationLayout::retireRemovedFocus(int first, int last) {
    if (!controller_ || window() == nullptr) {
      return;
    }

    auto* focused = window()->activeFocusItem();
    if (focused == nullptr || !isAncestorOf(focused)) {
      return;
    }

    const auto identity = focused->property("identity").toString();
    if (identity.isEmpty()) {
      return;
    }

    for (int index = first; index <= last; ++index) {
      const auto record = cards_.data(cards_.index(index), ListModel::record_role).toMap();
      if (record.value(u"key"_s).toString() == identity) {
        controller_->retireFocus(identity, focused);
        return;
      }
    }
  }

  void NotificationLayout::invalidate() {
    for (auto& content : contents_.viewMut()) {
      content.id = {};
    }

    scheduleLayout();
  }

  void NotificationLayout::scheduleLayout() {
    polish();
    if (clock_) {
      clock_->requestSynchronization();
    }
  }

  void NotificationLayout::bindWindow() {
    if (clock_) {
      clock_->detach(*this);
    }

    clock_ = window() == nullptr ? nullptr : &WindowAnimationClock::forWindow(*window());
    if (clock_) {
      clock_->attach(*this);
    }

    invalidate();
  }

  void NotificationLayout::refreshFonts() {
    auto* catalog = &WindowFontCatalog::forWindow(*window());
    if (catalog_ != catalog) {
      disconnect(font_connection_);
      catalog_ = catalog;
      font_connection_ = connect(catalog, &WindowFontCatalog::fontsChanged, this, &NotificationLayout::invalidate);
    }

    collection_ = catalog->collection();
    fonts_ = ResidentFonts::shared(collection_);
  }

  float NotificationLayout::measure(WindowFontCatalog& catalog, ResidentFonts& fonts, std::string_view text, std::uint16_t pixels, bool emphasized) {
    const auto role = emphasized ? fonts::FontRole::emphasized : fonts::FontRole::regular;

    catalog.request(text, role);

    return static_cast<float>(fonts::TextLayout<ConcurrentMemory>::measure(fonts, text, {.pixel_height = pixels, .preferred = role}));
  }

  NotificationLayout::Content& NotificationLayout::content(const application::notifications::NotificationItem& item, float width) {
    const auto contents = contents_.viewMut();
    auto found = std::ranges::find(contents, item.id, &Content::id);
    if (found == contents.end()) {
      const auto retained = controller_->center().items();

      found = std::ranges::find_if(contents, [&](const auto& candidate) {
        return candidate.id.value == 0 || std::ranges::none_of(retained, [&](const auto& existing) {
          return existing.id == candidate.id;
        });
      });
    }

    if (found == contents.end()) {
      throw std::logic_error{"NotificationContentCapacityExceeded"};
    }

    if (found->id != item.id || std::not_equal_to<>{}(found->width, width)) {
      found->id = item.id;
      found->width = width;
      found->message.assign(item.message.view());
      // The window owns its catalog; this layout only observes it.
      const auto measure_body = [catalog = tbc::raw(catalog_.data()), &fonts = *fonts_, pixels = chrome_.body](std::string_view label) {
        return measure(*catalog, fonts, label, pixels, false);
      };

      found->body.wrap(found->message.view(), width - metrics_.px(application::notifications::NotificationMetrics::text_insets), measure_body);
      found->height = metrics_.height(found->body.count(), item.clickable());
      auto made = contentRecord(item, *found);

      found->record = std::move(made.record);
      found->action_advance = made.action_advance;
      found->action_line_height = made.action_line_height;
    }

    return *found;
  }

  NotificationLayout::ContentRecord NotificationLayout::contentRecord(const application::notifications::NotificationItem& item, const Content& content) const {
    const application::notifications::NotificationCardGeometry geometry{.bounds = {.width = content.width, .height = content.height}, .metrics = metrics_};
    QVariantList body;

    for (std::size_t index = 0; index < content.body.count(); ++index) {
      body.append(QVariantMap{{u"text"_s, toQString(content.body.line(index))}, {u"bounds"_s, logicalBounds(geometry.body(index), density_)}});
    }

    auto action = application::notifications::NotificationActionLabel::target(item.target.kind);
    application::notifications::NotificationActionLabel::Buffer link_label;
    const auto measure_action = [catalog = tbc::raw(catalog_.data()), &fonts = *fonts_, pixels = chrome_.small](std::string_view label) {
      return measure(*catalog, fonts, label, pixels, true);
    };

    if (!item.link.view().empty()) {
      action = application::notifications::NotificationActionLabel::fitHost(item.linkHost(), geometry.bodyWidth(), measure_action, link_label);
    }

    QVariantList shadows;

    for (std::size_t layer = 0; layer < application::notifications::NotificationMetrics::shadow_layers; ++layer) {
      const auto spread = metrics_.px(static_cast<float>(application::notifications::NotificationMetrics::shadow_layers - layer) * application::notifications::NotificationMetrics::shadow_spread);

      shadows.append(QVariantMap{{u"bounds"_s, logicalBounds({.x = -spread, .y = -spread + metrics_.px(application::notifications::NotificationMetrics::shadow_offset), .width = content.width + (2 * spread), .height = content.height + (2 * spread)}, density_)}, {u"radius"_s, (static_cast<qreal>(metrics_.px(application::notifications::NotificationMetrics::radius) + spread)) / density_}});
    }

    const auto action_bounds = geometry.action();
    const auto action_line_height = static_cast<float>(fonts_->face(fonts::FontRole::emphasized).metrics(chrome_.small).line_height);
    const auto action_advance = measure_action(action);
    const auto accessible = item.link.view().empty() ? toQString(item.title.view()) + u": "_s + toQString(item.message.view()) : toQString(item.title.view()) + u", opens "_s + toQString(item.linkHost()) + u": "_s + toQString(item.message.view());

    return {
        .record = {
            {u"key"_s, controller_->identity(item.id)},
            {u"title"_s, toQString(item.title.view())},
            {u"titleBounds"_s, logicalBounds(geometry.title(), density_)},
            {u"body"_s, body},
            {u"action"_s, toQString(action)},
            {u"actionBounds"_s, logicalBounds(action_bounds, density_)},
            {u"iconBounds"_s, logicalBounds(geometry.icon(), density_)},
            {u"closeBounds"_s, logicalBounds(geometry.close(), density_)},
            {u"symbol"_s, symbol(item.level)},
            {u"accent"_s, accent(item.level)},
            {u"shadows"_s, shadows},
            {u"clickable"_s, item.clickable()},
            {u"accessible"_s, accessible},
        },
        .action_advance = action_advance,
        .action_line_height = action_line_height,
    };
  }

  void NotificationLayout::rebuild() {
    const auto machine_view = controller_ ? controller_->machineView() : 0;
    if (machine_view != machine_view_) {
      machine_view_ = machine_view;
      for (auto& content : contents_.viewMut()) {
        content.clear();
      }

      stack_ = {};
    }

    if (!eligible() || window() == nullptr) {
      cards_.reconcile({});
      stack_ = {};
      return;
    }

    density_ = window()->effectiveDevicePixelRatio();
    refreshFonts();
    const auto& display = controller_->display();

    chrome_ = display.chrome;
    metrics_ = {.ratio = chrome_.ratio, .title_row = ChromeMetrics::lineHeight(chrome_.title), .body_row = ChromeMetrics::lineHeight(chrome_.body), .small_row = ChromeMetrics::lineHeight(chrome_.small)};
    const auto physical_host = controller_->host();
    const auto host = logicalBounds(physical_host, density_);
    const QVariantMap style{
        {u"radius"_s, static_cast<qreal>(metrics_.px(application::notifications::NotificationMetrics::radius)) / density_},
        {u"iconRadius"_s, static_cast<qreal>(metrics_.px(application::notifications::NotificationMetrics::icon_radius)) / density_},
        {u"closeRadius"_s, static_cast<qreal>(metrics_.px(application::notifications::NotificationMetrics::close_radius)) / density_},
        {u"borderWidth"_s, static_cast<qreal>(metrics_.px(application::notifications::NotificationMetrics::border_width)) / density_},
        {u"focusBorderWidth"_s, static_cast<qreal>(metrics_.px(application::notifications::NotificationMetrics::focus_border_width)) / density_},
        {u"borderAlpha"_s, application::notifications::NotificationMetrics::border_alpha},
        {u"iconAlpha"_s, application::notifications::NotificationMetrics::icon_alpha},
        {u"shadowAlpha"_s, application::notifications::NotificationMetrics::shadow_alpha},
        {u"titlePixels"_s, chrome_.title / density_},
        {u"bodyPixels"_s, chrome_.body / density_},
        {u"smallPixels"_s, chrome_.small / density_},
    };
    if (host_ != host || style_ != style) {
      host_ = host;
      style_ = style;
      layoutChanged();
    }

    now_ns_ = std::max(now_ns_, clock_ ? clock_->now() : system::AwakeClock::nowNanoseconds());
    const auto placements = stack_.prepare({.items = controller_->center().items(), .host = physical_host, .ratio = metrics_.ratio, .now_ns = now_ns_}, [&](const application::notifications::NotificationItem& item) {
      return controller_->targetVisible(item.target);
    },
        [&](const application::notifications::NotificationItem& item, float width) {
          return content(item, width).height;
        });

    QList<QVariantMap> records;

    for (const auto& placement : placements.items()) {
      const auto& item = controller_->center().items()[placement.index];
      const auto& cached = content(item, placement.bounds.width);
      const application::notifications::NotificationCardGeometry geometry{.bounds = placement.bounds, .metrics = metrics_};
      auto underline = geometry.actionUnderline(cached.action_line_height, cached.action_advance);

      underline.x -= placement.bounds.x;
      underline.y -= placement.bounds.y;
      auto record = cached.record;

      record.insert(u"underlineBounds"_s, logicalBounds(underline, density_));
      record.insert(u"bounds"_s, logicalBounds(placement.bounds, density_));
      record.insert(u"opacity"_s, placement.opacity);
      record.insert(u"enabled"_s, item.phase != application::notifications::NotificationItem::Phase::exiting);
      records.append(record);
    }

    cards_.reconcile(std::move(records));
    const auto motion_end = stack_.nextDeadline(now_ns_, std::numeric_limits<std::uint64_t>::max());
    if (motion_end_ns_ != motion_end) {
      motion_end_ns_ = motion_end;
      if (clock_) {
        clock_->requestSynchronization();
      }
    }
  }

  void NotificationLayout::updatePolish() {
    try {
      rebuild();
    } catch (const std::exception&) {
      cards_.reconcile({});
    }
  }

  void NotificationLayout::itemChange(ItemChange change, const ItemChangeData& data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemSceneChange) {
      bindWindow();
    } else if (change == ItemDevicePixelRatioHasChanged) {
      invalidate();
    } else if (change == ItemVisibleHasChanged) {
      polish();
    }
  }

  void NotificationLayout::geometryChange(const QRectF& current, const QRectF& previous) {
    QQuickItem::geometryChange(current, previous);
    if (current.size() != previous.size()) {
      invalidate();
    }
  }

}
