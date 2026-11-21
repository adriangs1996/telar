#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "nvim_item.hpp"
#include "nvim_keys.hpp"
#include "ui/kit/input/key_adapter.hpp"
#include "ui/kit/models/projection.hpp"
#include <QCursor>
#include <QDebug>
#include <QGuiApplication>
#include <QHoverEvent>
#include <QInputMethod>
#include <QInputMethodEvent>
#include <QMouseEvent>
#include <QQuickWindow>
#include <QVariantList>
#include <QWheelEvent>
#include <algorithm>
#include <cmath>
#include <exception>
#include <stdexcept>
#include <string_view>
#include <utility>

import telar.gui.foundation.core;
import telar.gui.foundation.fonts;
import telar.gui.foundation.keys;
import telar.gui.foundation.terminal;
import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  namespace {

    namespace nvim = application::nvim;

    // Where each kind of grid is stacked: the default grid under the windows, the rows messages
    // scroll in over them, and the floats over everything in the order Neovim composes them.
    constexpr int window_layer = 1;
    constexpr int message_layer = 2;
    constexpr int float_layer = 10;
    // The rows a notch of a wheel scrolls, and the most one event sends.
    constexpr qreal notch_rows = 3;
    constexpr qreal notch_angle = 120;
    constexpr int maximum_wheel_steps = 12;

    QString kindName(const nvim::Grid& grid) {
      switch (grid.placement) {
      case nvim::NvimPlacement::window:
        return QStringLiteral("window");
      case nvim::NvimPlacement::floating:
        return QStringLiteral("float");
      case nvim::NvimPlacement::message:
        return QStringLiteral("message");
      case nvim::NvimPlacement::external:
        return QStringLiteral("external");
      case nvim::NvimPlacement::hidden:
        return QStringLiteral("hidden");
      }

      return QStringLiteral("hidden");
    }

    int layerOf(const nvim::Grid& grid) noexcept {
      switch (grid.placement) {
      case nvim::NvimPlacement::window:
        return window_layer;
      case nvim::NvimPlacement::message:
        return message_layer;
      case nvim::NvimPlacement::floating:
        return float_layer + static_cast<int>(std::min<std::uint32_t>(grid.composition_index, std::numeric_limits<int>::max() - float_layer));
      case nvim::NvimPlacement::external:
      case nvim::NvimPlacement::hidden:
        return 0;
      }

      return 0;
    }

    // Text Neovim wrote, which may not be UTF-8: what is not is shown as the replacement mark.
    QString shown(std::string_view text) {
      return QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()));
    }

    QString messageKind(nvim::NvimMessageKind kind) {
      switch (kind) {
      case nvim::NvimMessageKind::error:
        return QStringLiteral("error");
      case nvim::NvimMessageKind::warning:
        return QStringLiteral("warning");
      case nvim::NvimMessageKind::confirm:
        return QStringLiteral("confirm");
      case nvim::NvimMessageKind::progress:
        return QStringLiteral("progress");
      case nvim::NvimMessageKind::search_count:
        return QStringLiteral("search");
      case nvim::NvimMessageKind::list:
        return QStringLiteral("list");
      case nvim::NvimMessageKind::plain:
        return QStringLiteral("plain");
      }

      return QStringLiteral("plain");
    }

    Byte mouseModifiers(Qt::KeyboardModifiers native) noexcept {
      const auto flags = NativeKeyAdapter::modifiers(native);
      Byte bits = 0;

      for (const auto& [modifier, bit] : {std::pair{KeyChord::Modifier::shift, nvim::mouse_shift}, std::pair{KeyChord::Modifier::control, nvim::mouse_control}, std::pair{KeyChord::Modifier::alt, nvim::mouse_alt}, std::pair{KeyChord::Modifier::super, nvim::mouse_command}}) {
        if ((flags & static_cast<unsigned>(modifier)) != 0) {
          bits = static_cast<Byte>(bits | bit);
        }
      }

      return bits;
    }

    ds::Option<nvim::NvimMouseButton> buttonOf(Qt::MouseButton button) noexcept {
      if (button == Qt::LeftButton) {
        return nvim::NvimMouseButton::left;
      }

      if (button == Qt::RightButton) {
        return nvim::NvimMouseButton::right;
      }

      if (button == Qt::MiddleButton) {
        return nvim::NvimMouseButton::middle;
      }

      return ds::none;
    }

    QString promptKind(nvim::NvimPromptKind kind) {
      switch (kind) {
      case nvim::NvimPromptKind::select:
        return QStringLiteral("select");
      case nvim::NvimPromptKind::input:
        return QStringLiteral("input");
      case nvim::NvimPromptKind::none:
        return {};
      }

      return {};
    }

    // The tabs or the buffers of a tab line, each as QML shows it.
    QVariantList tabRecords(std::span<const nvim::Tab> entries, std::string_view text) {
      QVariantList records;

      records.reserve(static_cast<qsizetype>(entries.size()));
      for (const auto& entry : entries) {
        records.append(QVariantMap{{QStringLiteral("handle"), static_cast<qulonglong>(entry.handle)}, {QStringLiteral("name"), shown(entry.name.of(text))}});
      }

      return records;
    }

  }

  NvimItem::NvimItem(QQuickItem* parent)
      : QQuickItem(parent) {
    setFlag(ItemAcceptsInputMethod);
    setFlag(ItemIsFocusScope, false);
    setAcceptedMouseButtons(Qt::LeftButton | Qt::RightButton | Qt::MiddleButton);
    setAcceptHoverEvents(true);
    setActiveFocusOnTab(false);
    blink_.setSingleShot(true);
    connect(&blink_, &QTimer::timeout, this, [this] {
      cursor_on_ = !cursor_on_;
      blink_.start(cursor_on_ ? blink_cursor_.blink_on_ms : blink_cursor_.blink_off_ms);
      emit frameShown();
    });
  }

  NvimItem::~NvimItem() {
    QObject::disconnect(font_catalog_connection_);
  }

  void NvimItem::setController(NvimController* controller) {
    if (controller_ == controller) {
      return;
    }

    if (controller_ != nullptr) {
      disconnect(controller_, nullptr, this, nullptr);
    }

    controller_ = controller;
    if (controller_ != nullptr) {
      connect(controller_, &NvimController::editorChanged, this, &NvimItem::refresh);
      connect(controller_, &NvimController::configurationChanged, this, &NvimItem::measure);
    }

    measure();
    refresh(pane_id_);
    emit controllerChanged();
  }

  void NvimItem::setPaneId(const QString& pane_id) {
    const auto next = pane_id.toULongLong();
    if (pane_id_ == next) {
      return;
    }

    pane_id_ = next;
    ready_ = false;
    layout_revision_ = 0;
    cmdline_revision_ = 0;
    menu_revision_ = 0;
    messages_revision_ = 0;
    tabs_revision_ = 0;
    prompt_revision_ = 0;
    refresh(pane_id_);
    polish();
    emit paneIdChanged();
  }

  const nvim::Editor* NvimItem::editorState() const noexcept {
    return controller_ == nullptr ? nullptr : controller_->editor(pane_id_);
  }

  const application::Pane<Memory>* NvimItem::pane() const noexcept {
    return controller_ == nullptr ? nullptr : controller_->pane(pane_id_);
  }

  void NvimItem::answer(bool accepted, int index, const QString& text) {
    if (controller_ != nullptr) {
      controller_->answer(pane_id_, accepted, index < 0 ? 0U : static_cast<std::uint32_t>(index), text);
    }
  }

  void NvimItem::chooseMenu(int item) {
    if (controller_ != nullptr && item >= 0) {
      controller_->choose(pane_id_, static_cast<std::uint32_t>(item), true);
    }
  }

  namespace {

    constexpr std::string_view sourceName(nvim::NvimPickSource source) noexcept {
      switch (source) {
      case nvim::NvimPickSource::files:
        return "files";
      case nvim::NvimPickSource::text:
        return "text";
      case nvim::NvimPickSource::buffers:
        return "buffers";
      }

      return "files";
    }

  }

  namespace {

    nvim::NvimPickSource sourceNamed(const QString& name) {
      if (name == QLatin1StringView{"text"}) {
        return nvim::NvimPickSource::text;
      }

      return name == QLatin1StringView{"buffers"} ? nvim::NvimPickSource::buffers : nvim::NvimPickSource::files;
    }

  }

  void NvimItem::pick(const QString& source) {
    if (controller_ != nullptr) {
      controller_->pick(pane_id_, sourceNamed(source));
    }
  }

  void NvimItem::searchPicker(const QString& query) {
    if (controller_ != nullptr) {
      controller_->search(pane_id_, query);
    }
  }

  void NvimItem::acceptPicker(int index, const QString& where) {
    if (controller_ == nullptr || index < 0) {
      return;
    }

    auto place = nvim::NvimOpenIn::place;

    if (where == QLatin1StringView{"split"}) {
      place = nvim::NvimOpenIn::split;
    } else if (where == QLatin1StringView{"vertical"}) {
      place = nvim::NvimOpenIn::vertical_split;
    } else if (where == QLatin1StringView{"tab"}) {
      place = nvim::NvimOpenIn::tab;
    }

    controller_->accept(pane_id_, {.index = static_cast<std::size_t>(index), .where = place});
  }

  void NvimItem::previewPicker(int index, const QRectF& area) {
    if (controller_ == nullptr || font_.cell.width() <= 0 || font_.cell.height() <= 0) {
      return;
    }

    constexpr qreal most = std::numeric_limits<std::uint16_t>::max();
    const auto cells = [&](qreal pixels, qreal cell, bool inward) {
      const auto count = pixels / cell;

      return static_cast<std::uint16_t>(std::clamp<qreal>(inward ? std::floor(count) : std::ceil(count), 0, most));
    };

    // The cells that fit whole inside the area: the float never passes its edges.
    preview_area_ = index < 0 ? nvim::PreviewArea{} : nvim::PreviewArea{.row = cells(area.y(), font_.cell.height(), false), .column = cells(area.x(), font_.cell.width(), false), .columns = cells(area.width() - font_.cell.width(), font_.cell.width(), true), .rows = cells(area.height() - font_.cell.height(), font_.cell.height(), true)};
    controller_->preview(pane_id_, index < 0 ? ds::Option<std::size_t>{} : ds::Option<std::size_t>{static_cast<std::size_t>(index)}, preview_area_);
  }

  void NvimItem::listPicker(const QVariantList& indices) {
    if (controller_ == nullptr) {
      return;
    }

    QList<std::uint32_t> marked;

    for (const auto& index : indices) {
      if (index.toInt() >= 0) {
        marked.append(static_cast<std::uint32_t>(index.toInt()));
      }
    }

    controller_->list(pane_id_, std::span<const std::uint32_t>{std::as_const(marked)});
  }

  void NvimItem::closePicker() {
    preview_area_ = {};
    if (controller_ != nullptr) {
      controller_->dismiss(pane_id_);
    }
  }

  void NvimItem::projectPicker(const nvim::Editor& editor) {
    if (picker_revision_ == editor.picker_revision) {
      return;
    }

    const auto& picker = editor.picker;
    const std::string_view text{picker.text.data(), picker.text.size()};
    QVariantList rows;

    picker_revision_ = editor.picker_revision;
    rows.reserve(static_cast<qsizetype>(picker.matches.size()));
    for (const auto& match : picker.matches) {
      const auto path = match.path.of(text);
      const auto slash = path.rfind('/');

      rows.append(QVariantMap{
          {QStringLiteral("name"), shown(slash == std::string_view::npos ? path : path.substr(slash + 1))},
          {QStringLiteral("directory"), shown(slash == std::string_view::npos ? std::string_view{} : path.substr(0, slash))},
          {QStringLiteral("line"), static_cast<int>(match.line)},
          {QStringLiteral("text"), shown(match.text.of(text))},
      });
    }

    picker_ = {
        {QStringLiteral("open"), picker.open},
        {QStringLiteral("source"), shown(sourceName(picker.source))},
        {QStringLiteral("query"), shown(picker.query.view())},
        {QStringLiteral("root"), shown(picker.root.view())},
        {QStringLiteral("loading"), picker.awaited != 0},
        {QStringLiteral("truncated"), picker.truncated},
        {QStringLiteral("rows"), rows},
    };

    if (!picker.open) {
      preview_area_ = {};
    }

    emit pickerChanged();
  }

  void NvimItem::send(const QString& keys) {
    if (controller_ != nullptr) {
      const auto bytes = keys.toUtf8();

      controller_->type(pane_id_, {bytes.constData(), static_cast<std::size_t>(bytes.size())});
    }
  }

  void NvimItem::measure() {
    if (controller_ == nullptr) {
      return;
    }

    try {
      const auto scale = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
      auto resolved = controller_->host().resolveFont(scale);

      font_ = std::move(resolved.font);
      font_grid_ = resolved.grid;
      font_scale_ = scale;
      ++appearance_;
      // Where each grid goes is counted in cells of this font.
      layout_revision_ = 0;
      emit metricsChanged();
      polish();
      refresh(pane_id_);
    } catch (const std::exception& error) {
      qWarning() << "Editor font:" << error.what();
    }
  }

  void NvimItem::refreshFonts() {
    auto* catalog = window() == nullptr ? nullptr : &WindowFontCatalog::forWindow(*window());
    if (font_catalog_ != catalog) {
      QObject::disconnect(font_catalog_connection_);
      font_catalog_ = catalog;
      if (catalog != nullptr) {
        font_catalog_connection_ = connect(catalog, &WindowFontCatalog::fontsChanged, this, [this] {
          font_collection_.reset();
          ++appearance_;
          polish();
          emit frameShown();
        });
      }
    }

    if (catalog != nullptr && controller_ != nullptr) {
      catalog->configure(controller_->configuration().font);
      if (font_collection_ != catalog->collection()) {
        font_collection_ = catalog->collection();
        fonts_ = ResidentFonts::shared(font_collection_);
        emit frameShown();
      }
    }
  }

  void NvimItem::requestFonts(std::span<const CellValue> cells) {
    if (!fonts_ || font_catalog_ == nullptr) {
      return;
    }

    const auto& primary = fonts_->face(fonts::FontRole::primary);

    for (const auto& cell : cells) {
      if (cell.width == CellWidth::continuation || cell.utf8().empty()) {
        continue;
      }

      try {
        if (!fonts::FontCoverage::covers(primary, cell.utf8())) {
          font_catalog_->request(cell.utf8(), fonts::FontRole::primary);
        }
      } catch (const std::invalid_argument&) {
        // Text that is not UTF-8 is drawn as the replacement mark, which the primary font has.
        const auto normalized = QString::fromUtf8(cell.utf8()).toUtf8();

        font_catalog_->request({normalized.constData(), static_cast<std::size_t>(normalized.size())}, fonts::FontRole::primary);
      }
    }
  }

  void NvimItem::resizeEditor() {
    if (controller_ == nullptr || window() == nullptr || font_.cell.width() <= 0 || font_.cell.height() <= 0 || width() <= 0 || height() <= 0) {
      return;
    }

    const TerminalGrid grid{.cell_width_px = font_grid_.width, .cell_height_px = font_grid_.height, .scale = font_scale_};
    if (const auto size = grid.fit(width(), height())) {
      controller_->resize(pane_id_, *size);
    }
  }

  void NvimItem::itemChange(ItemChange change, const ItemChangeData& data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemSceneChange || change == ItemDevicePixelRatioHasChanged) {
      measure();
    }
  }

  void NvimItem::geometryChange(const QRectF& current, const QRectF& previous) {
    QQuickItem::geometryChange(current, previous);
    if (current.size() != previous.size()) {
      polish();
    }
  }

  // QML gives a delegate its geometry and its window apart: the size is committed once both are
  // settled, never from a default grid.
  void NvimItem::updatePolish() {
    refreshFonts();
    resizeEditor();
  }

  QRectF NvimItem::gridBounds(const nvim::Grid& grid) const noexcept {
    const auto cell = font_.cell;
    const QSizeF size{grid.screen.columns() * cell.width(), grid.screen.rows() * cell.height()};

    // The default grid is the editor itself: the status lines and the separators are on it.
    if (grid.id == 1) {
      return {QPointF{}, size};
    }

    return {QPointF{grid.column * cell.width(), grid.row * cell.height()}, size};
  }

  void NvimItem::synchronizeGrids(const nvim::Editor& editor) {
    QList<QVariantMap> records;

    records.reserve(static_cast<qsizetype>(editor.grids.size()));
    for (const auto& grid : editor.grids) {
      const bool base = grid->id == 1;
      if (!base && (grid->placement == nvim::NvimPlacement::hidden || grid->placement == nvim::NvimPlacement::external)) {
        continue;
      }

      const auto bounds = gridBounds(*grid);

      records.append({
          {QStringLiteral("key"), QString::number(grid->id)},
          {QStringLiteral("gridId"), static_cast<int>(grid->id)},
          {QStringLiteral("kind"), base ? QStringLiteral("base") : kindName(*grid)},
          {QStringLiteral("x"), bounds.x()},
          {QStringLiteral("y"), bounds.y()},
          {QStringLiteral("width"), bounds.width()},
          {QStringLiteral("height"), bounds.height()},
          {QStringLiteral("layer"), base ? 0 : layerOf(*grid)},
          // What a scrollbar shows of the window's buffer, without asking Neovim.
          {QStringLiteral("topLine"), static_cast<qulonglong>(grid->top_line)},
          {QStringLiteral("bottomLine"), static_cast<qulonglong>(grid->bottom_line)},
          {QStringLiteral("lineCount"), static_cast<qulonglong>(grid->line_count)},
          {QStringLiteral("scrolledLines"), static_cast<qlonglong>(grid->scrolled_lines)},
          {QStringLiteral("marginTop"), grid->margin_top * font_.cell.height()},
          {QStringLiteral("marginBottom"), grid->margin_bottom * font_.cell.height()},
          // A float's frame, which the window draws in place of the cells of its border.
          {QStringLiteral("border"), static_cast<int>(grid->border)},
          {QStringLiteral("title"), shown(grid->title.view())},
          {QStringLiteral("footer"), shown(grid->footer.view())},
          // The float a picker asked for over its preview's cells: it is drawn over the picker.
          {QStringLiteral("preview"), grid->placement == nvim::NvimPlacement::floating && preview_area_.columns != 0 && std::cmp_equal(grid->row, preview_area_.row) && std::cmp_equal(grid->column, preview_area_.column) && grid->width == preview_area_.columns && grid->height == preview_area_.rows},
      });
    }

    grids_.reconcile(std::move(records));
  }

  namespace {

    // The character Neovim rules a row with between two windows one over the other, when no
    // status line stands there.
    bool rules(std::string_view text) noexcept {
      return text == "─" || text == "━" || text == "═";
    }

  }

  void NvimItem::synchronizeSeparators(const nvim::Editor& editor) {
    QVariantList separators;
    const auto* base = editor.grid(1);
    const auto width = font_.cell.width();
    const auto height = font_.cell.height();
    const auto add = [&](bool vertical, QRectF bounds) {
      separators.append(QVariantMap{
          {QStringLiteral("vertical"), vertical},
          {QStringLiteral("x"), bounds.x()},
          {QStringLiteral("y"), bounds.y()},
          {QStringLiteral("width"), bounds.width()},
          {QStringLiteral("height"), bounds.height()},
      });
    };

    for (const auto& grid : editor.grids) {
      if (base == nullptr || grid->id == 1 || grid->placement != nvim::NvimPlacement::window) {
        continue;
      }

      // A window that does not start at the editor's left edge has a separator's column there.
      if (grid->column > 0) {
        add(true, {(grid->column - 1) * width, grid->row * height, width, grid->height * height});
      }

      const auto above = grid->row - 1;
      if (above >= 0 && std::cmp_less(above, base->screen.rows()) && std::cmp_less(grid->column, base->screen.columns()) &&
          rules(base->screen.row(static_cast<std::size_t>(above))[static_cast<std::size_t>(grid->column)].utf8())) {
        add(false, {grid->column * width, above * height, grid->width * width, height});
      }
    }

    if (separators != separators_) {
      separators_ = std::move(separators);
      emit separatorsChanged();
    }
  }

  Qt::CursorShape NvimItem::pointerAt(QPointF position) const {
    const auto* editor = editorState();
    const auto where = hit(position);
    const auto* grid = editor == nullptr || !where ? nullptr : editor->grid(where->grid);
    if (grid == nullptr || !grid->mouse_enabled) {
      return Qt::ArrowCursor;
    }

    if (grid->id != 1) {
      // A link the editor has on the cell is pointed at, as in a terminal.
      const bool on_cell = where->row < grid->screen.rows() && where->column < grid->screen.columns();
      if (on_cell && (grid->screen.row(where->row)[where->column].style.flags & CellStyle::link) != 0) {
        return Qt::PointingHandCursor;
      }

      return grid->placement == nvim::NvimPlacement::window ? Qt::IBeamCursor : Qt::ArrowCursor;
    }

    for (const auto& separator : separators_) {
      const auto record = separator.toMap();
      const QRectF bounds{record.value(QStringLiteral("x")).toReal(), record.value(QStringLiteral("y")).toReal(), record.value(QStringLiteral("width")).toReal(), record.value(QStringLiteral("height")).toReal()};

      if (bounds.contains(position)) {
        return record.value(QStringLiteral("vertical")).toBool() ? Qt::SplitHCursor : Qt::SplitVCursor;
      }
    }

    // A status line with a window under it is dragged to resize the two.
    const bool between = std::ranges::any_of(editor->grids, [&](const auto& other) {
      return other->id != 1 && other->placement == nvim::NvimPlacement::window && other->row == where->row + 1 && where->column >= other->column && std::cmp_less(where->column, other->column + other->width);
    });

    return between ? Qt::SplitVCursor : Qt::ArrowCursor;
  }

  void NvimItem::hoverMoveEvent(QHoverEvent* event) {
    if (const auto shape = pointerAt(event->position()); cursor().shape() != shape) {
      setCursor(shape);
    }

    QQuickItem::hoverMoveEvent(event);
  }

  void NvimItem::synchronizeCursor(const nvim::Editor& editor) {
    QRectF bounds;

    if (const auto* grid = editor.grid(editor.cursor.grid); grid != nullptr && editor.cursor.visible) {
      const auto origin = gridBounds(*grid).topLeft();

      bounds = {origin.x() + (editor.cursor.column * font_.cell.width()), origin.y() + (editor.cursor.row * font_.cell.height()), font_.cell.width(), font_.cell.height()};
    }

    if (bounds != cursor_rect_) {
      cursor_rect_ = bounds;
      emit cursorChanged();
      if (hasActiveFocus()) {
        QGuiApplication::inputMethod()->update(Qt::ImCursorRectangle);
      }
    }

    if (editor.cursor != blink_cursor_) {
      restartBlink(editor);
    }

    if (const auto mode = shown(editor.mode.view()); mode != mode_) {
      mode_ = mode;
      emit modeChanged();
    }
  }

  // The cursor is lit when it moves, and blinks as the mode Neovim is in says.
  void NvimItem::restartBlink(const nvim::Editor& editor) {
    blink_cursor_ = editor.cursor;
    cursor_on_ = true;
    blink_.stop();
    if (editor.cursor.blink_on_ms != 0 && editor.cursor.blink_off_ms != 0 && hasActiveFocus()) {
      blink_.start(editor.cursor.blink_wait_ms + editor.cursor.blink_on_ms);
    }
  }

  void NvimItem::synchronizeSurfaces(const nvim::Editor& editor) {
    projectCmdline(editor);
    projectMenu(editor);
    projectMessages(editor);
    projectTabs(editor);
    projectPrompt(editor);
    projectPicker(editor);
  }

  void NvimItem::projectCmdline(const nvim::Editor& editor) {
    if (cmdline_revision_ == editor.cmdline_revision) {
      return;
    }

    const auto& line = editor.cmdline;
    const auto text = line.text.view();

    cmdline_revision_ = editor.cmdline_revision;
    cmdline_ = {
        {QStringLiteral("visible"), line.visible},
        {QStringLiteral("level"), static_cast<int>(line.level)},
        {QStringLiteral("first"), line.first == 0 ? QString{} : QString{QChar::fromLatin1(line.first)}},
        {QStringLiteral("special"), line.special == 0 ? QString{} : QString{QChar::fromLatin1(line.special)}},
        {QStringLiteral("prompt"), shown(line.prompt.view())},
        {QStringLiteral("text"), shown(text)},
        // The cursor counted in the characters QML lays out, not in Neovim's bytes.
        {QStringLiteral("position"), shown(text.substr(0, std::min<std::size_t>(line.position, text.size()))).size()},
        {QStringLiteral("indent"), static_cast<int>(line.indent)},
        {QStringLiteral("block"), shown(line.block.view())},
    };

    emit cmdlineChanged();
  }

  void NvimItem::projectMenu(const nvim::Editor& editor) {
    if (menu_revision_ == editor.menu_revision) {
      return;
    }

    const auto& menu = editor.menu;
    const std::string_view text{menu.text.data(), menu.text.size()};
    QVariantList items;

    menu_revision_ = editor.menu_revision;
    items.reserve(static_cast<qsizetype>(menu.items.size()));
    for (const auto& item : menu.items) {
      items.append(QVariantMap{
          {QStringLiteral("word"), shown(item.word.of(text))},
          {QStringLiteral("kind"), shown(item.kind.of(text))},
          {QStringLiteral("menu"), shown(item.menu.of(text))},
      });
    }

    QPointF anchor;
    const bool on_cmdline = menu.grid < 0;

    if (const auto* grid = on_cmdline ? nullptr : editor.grid(static_cast<std::uint32_t>(menu.grid))) {
      anchor = gridBounds(*grid).topLeft() + QPointF{menu.column * font_.cell.width(), menu.row * font_.cell.height()};
    }

    popup_menu_ = {
        {QStringLiteral("visible"), menu.visible},
        {QStringLiteral("selected"), menu.selected},
        {QStringLiteral("first"), static_cast<int>(menu.first)},
        {QStringLiteral("total"), static_cast<int>(menu.total)},
        {QStringLiteral("onCmdline"), on_cmdline},
        {QStringLiteral("column"), menu.column},
        {QStringLiteral("x"), anchor.x()},
        {QStringLiteral("y"), anchor.y()},
        {QStringLiteral("items"), items},
    };

    emit popupMenuChanged();
  }

  void NvimItem::projectMessages(const nvim::Editor& editor) {
    if (messages_revision_ == editor.messages_revision) {
      return;
    }

    const auto& messages = editor.messages;
    const std::string_view text{messages.text.data(), messages.text.size()};
    QVariantList items;

    messages_revision_ = editor.messages_revision;
    for (const auto& message : messages.items) {
      items.append(QVariantMap{
          {QStringLiteral("id"), static_cast<qulonglong>(message.id)},
          {QStringLiteral("kind"), messageKind(message.kind)},
          {QStringLiteral("text"), shown(message.text.of(text)).trimmed()},
      });
    }

    messages_ = {
        {QStringLiteral("mode"), shown(messages.mode.view())},
        {QStringLiteral("command"), shown(messages.command.view())},
        {QStringLiteral("ruler"), shown(messages.ruler.view())},
        {QStringLiteral("items"), items},
    };

    emit messagesChanged();
  }

  void NvimItem::projectTabs(const nvim::Editor& editor) {
    if (tabs_revision_ == editor.tabs_revision) {
      return;
    }

    const auto& tabs = editor.tabs;
    const std::string_view text{tabs.text.data(), tabs.text.size()};

    tabs_revision_ = editor.tabs_revision;
    tabline_ = {
        {QStringLiteral("currentTab"), static_cast<qulonglong>(tabs.current_tab)},
        {QStringLiteral("currentBuffer"), static_cast<qulonglong>(tabs.current_buffer)},
        {QStringLiteral("tabs"), tabRecords(tabs.tabs.view(), text)},
        {QStringLiteral("buffers"), tabRecords(tabs.buffers.view(), text)},
    };

    emit tablineChanged();
  }

  void NvimItem::projectPrompt(const nvim::Editor& editor) {
    if (prompt_revision_ == editor.prompt_revision) {
      return;
    }

    const auto& prompt = editor.prompt;
    const std::string_view text{prompt.text.data(), prompt.text.size()};
    QStringList choices;

    prompt_revision_ = editor.prompt_revision;
    for (const auto& choice : prompt.choices) {
      choices.append(shown(choice.of(text)));
    }

    prompt_ = {
        {QStringLiteral("id"), static_cast<qulonglong>(prompt.id)},
        {QStringLiteral("kind"), promptKind(prompt.kind)},
        {QStringLiteral("title"), shown(prompt.title.view())},
        {QStringLiteral("initial"), shown(prompt.initial.view())},
        {QStringLiteral("choices"), choices},
    };

    emit promptChanged();
  }

  void NvimItem::refresh(qulonglong pane_id) {
    if (pane_id != pane_id_) {
      return;
    }

    const auto* editor = editorState();
    if (editor == nullptr) {
      grids_.reconcile({});
      return;
    }

    if (layout_revision_ != editor->layout_revision || grids_.rowCount() == 0) {
      layout_revision_ = editor->layout_revision;
      synchronizeGrids(*editor);
      synchronizeSeparators(*editor);
    }

    synchronizeCursor(*editor);
    synchronizeSurfaces(*editor);
    confirmPrediction(*editor);
    if (!ready_ && editor->frame != 0) {
      ready_ = true;
      emit readyChanged();
    }

    emit frameShown();
  }

  void NvimItem::keyPressEvent(QKeyEvent* event) {
    const auto key = nvimKey(*event);
    if (!key || controller_ == nullptr) {
      // A modifier alone types nothing; the event is still the editor's.
      event->accept();
      return;
    }

    controller_->type(pane_id_, nvim::notation(*key).view());
    predict(*event);
    event->accept();
  }

  void NvimItem::predict(const QKeyEvent& event) {
    const auto* editor = editorState();
    if (editor == nullptr) {
      return;
    }

    if (!echo_clock_.isValid()) {
      echo_clock_.start();
    }

    constexpr double nanoseconds_per_ms = 1e6;
    const auto typed = event.text().toUcs4();
    // What a key types as itself: no chord, and nothing the editor shows of its own over the text.
    const bool plain = typed.size() == 1 && (event.modifiers() & ~(Qt::ShiftModifier | Qt::KeypadModifier)) == Qt::NoModifier;
    const bool typing = editor->mode.view() == "insert" && !editor->menu.visible && !editor->cmdline.visible && !editor->picker.open;

    echo_.sent(static_cast<double>(echo_clock_.nsecsElapsed()) / nanoseconds_per_ms);
    if (plain && echo_.predict(typed.front(), {.grid = editor->cursor.grid, .row = editor->cursor.row, .column = editor->cursor.column}, typing)) {
      publishPrediction();
    } else if (!plain || !typing) {
      // A key that is not a letter moves the editor on: what was ahead no longer is.
      echo_.clear();
      publishPrediction();
    }
  }

  void NvimItem::confirmPrediction(const nvim::Editor& editor) {
    if (!echo_clock_.isValid()) {
      return;
    }

    constexpr double nanoseconds_per_ms = 1e6;
    const auto origin = echo_.origin();
    const auto* grid = echo_.pending().empty() ? nullptr : editor.grid(origin.grid);
    QList<char32_t> cells;

    // The row the letters wait on, a code point for each cell.
    if (grid != nullptr && origin.row < grid->screen.rows()) {
      for (const auto& cell : grid->screen.row(origin.row)) {
        const auto text = QString::fromUtf8(cell.utf8().data(), static_cast<qsizetype>(cell.utf8().size())).toUcs4();

        cells.append(text.isEmpty() ? U' ' : text.front());
      }
    }

    echo_.confirm(static_cast<double>(echo_clock_.nsecsElapsed()) / nanoseconds_per_ms, {.grid = editor.cursor.grid, .row = editor.cursor.row, .column = editor.cursor.column}, std::span<const char32_t>{std::as_const(cells)});
    if (editor.mode.view() != "insert") {
      echo_.clear();
    }

    publishPrediction();
  }

  void NvimItem::publishPrediction() {
    const auto pending = echo_.pending();
    const auto text = QString::fromUcs4(pending.data(), static_cast<qsizetype>(pending.size()));
    const auto* editor = editorState();
    const auto* grid = editor == nullptr || pending.empty() ? nullptr : editor->grid(echo_.origin().grid);
    const auto origin = grid == nullptr ? QPointF{} : gridBounds(*grid).topLeft() + QPointF{echo_.origin().column * font_.cell.width(), echo_.origin().row * font_.cell.height()};

    if (text != prediction_ || origin != prediction_origin_) {
      prediction_ = text;
      prediction_origin_ = origin;
      emit predictionChanged();
    }
  }

  void NvimItem::keyReleaseEvent(QKeyEvent* event) {
    event->accept();
  }

  void NvimItem::inputMethodEvent(QInputMethodEvent* event) {
    if (const auto committed = event->commitString(); !committed.isEmpty() && controller_ != nullptr) {
      QByteArray keys;

      // Each character goes as a key, so the one that opens a key name goes by its own.
      for (const auto scalar : committed.toUcs4()) {
        const auto key = nvim::notation({.codepoint = static_cast<std::uint32_t>(scalar)});

        keys.append(key.view().data(), static_cast<qsizetype>(key.view().size()));
      }

      controller_->type(pane_id_, {keys.constData(), static_cast<std::size_t>(keys.size())});
    }

    event->accept();
  }

  QVariant NvimItem::inputMethodQuery(Qt::InputMethodQuery query) const {
    if (query == Qt::ImEnabled) {
      return true;
    }

    if (query == Qt::ImCursorRectangle) {
      return cursor_rect_;
    }

    return QQuickItem::inputMethodQuery(query);
  }

  void NvimItem::focusInEvent(QFocusEvent* event) {
    QQuickItem::focusInEvent(event);
    if (controller_ != nullptr) {
      controller_->focus(pane_id_, true);
    }

    if (const auto* editor = editorState()) {
      restartBlink(*editor);
    }

    emit frameShown();
  }

  void NvimItem::focusOutEvent(QFocusEvent* event) {
    QQuickItem::focusOutEvent(event);
    if (controller_ != nullptr) {
      controller_->focus(pane_id_, false);
    }

    blink_.stop();
    cursor_on_ = true;
    held_.reset();
    emit frameShown();
  }

  // The topmost grid under a point, and the cell of it there.
  ds::Option<NvimItem::Hit> NvimItem::hit(QPointF position) const {
    const auto* editor = editorState();
    if (editor == nullptr || font_.cell.width() <= 0 || font_.cell.height() <= 0) {
      return ds::none;
    }

    const nvim::Grid* found = nullptr;
    int layer = -1;

    for (const auto& grid : editor->grids) {
      const bool base = grid->id == 1;
      if (!base && (grid->placement == nvim::NvimPlacement::hidden || grid->placement == nvim::NvimPlacement::external)) {
        continue;
      }

      const auto order = base ? 0 : layerOf(*grid);
      if (order > layer && gridBounds(*grid).contains(position)) {
        found = &grid.get();
        layer = order;
      }
    }

    if (found == nullptr) {
      return ds::none;
    }

    const auto local = position - gridBounds(*found).topLeft();
    const auto row = std::clamp<qreal>(std::floor(local.y() / font_.cell.height()), 0, std::max(0, found->screen.rows() - 1));
    const auto column = std::clamp<qreal>(std::floor(local.x() / font_.cell.width()), 0, std::max(0, found->screen.columns() - 1));

    return Hit{.grid = found->id, .row = static_cast<std::uint16_t>(row), .column = static_cast<std::uint16_t>(column)};
  }

  void NvimItem::point(const QMouseEvent& event, nvim::NvimMouseAction action) {
    const auto button = action == nvim::NvimMouseAction::press ? buttonOf(event.button()) : held_;
    const auto where = hit(event.position());
    if (!button || !where || controller_ == nullptr) {
      return;
    }

    // A drag within one cell tells Neovim nothing new.
    if (action == nvim::NvimMouseAction::drag && held_at_ && held_at_->grid == where->grid && held_at_->row == where->row && held_at_->column == where->column) {
      return;
    }

    held_at_ = where;
    controller_->point({.pane_id = pane_id_, .grid = where->grid, .row = where->row, .column = where->column, .button = *button, .action = action, .modifiers = mouseModifiers(event.modifiers())});
  }

  void NvimItem::mousePressEvent(QMouseEvent* event) {
    emit pressed();
    forceActiveFocus(Qt::MouseFocusReason);
    point(*event, nvim::NvimMouseAction::press);
    held_ = buttonOf(event->button());
    event->accept();
  }

  void NvimItem::mouseMoveEvent(QMouseEvent* event) {
    if (held_) {
      point(*event, nvim::NvimMouseAction::drag);
    }

    event->accept();
  }

  void NvimItem::mouseReleaseEvent(QMouseEvent* event) {
    if (held_) {
      point(*event, nvim::NvimMouseAction::release);
    }

    held_.reset();
    held_at_.reset();
    event->accept();
  }

  void NvimItem::wheelEvent(QWheelEvent* event) {
    const auto where = hit(event->position());
    if (!where || controller_ == nullptr || font_.cell.height() <= 0) {
      event->ignore();
      return;
    }

    // A trackpad says how far in pixels; a wheel in notches.
    const bool precise = !event->pixelDelta().isNull();

    wheel_rows_ += precise ? event->pixelDelta().y() / font_.cell.height() : event->angleDelta().y() / notch_angle * notch_rows;
    wheel_columns_ += precise ? event->pixelDelta().x() / font_.cell.width() : event->angleDelta().x() / notch_angle * notch_rows;

    const auto send = [&](qreal& travel, nvim::NvimMouseAction forward, nvim::NvimMouseAction backward) {
      auto steps = static_cast<int>(std::trunc(travel));

      travel -= steps;
      for (steps = std::clamp(steps, -maximum_wheel_steps, maximum_wheel_steps); steps != 0; steps += steps > 0 ? -1 : 1) {
        controller_->point({.pane_id = pane_id_, .grid = where->grid, .row = where->row, .column = where->column, .button = nvim::NvimMouseButton::wheel, .action = steps > 0 ? forward : backward, .modifiers = mouseModifiers(event->modifiers())});
      }
    };

    send(wheel_rows_, nvim::NvimMouseAction::up, nvim::NvimMouseAction::down);
    send(wheel_columns_, nvim::NvimMouseAction::left, nvim::NvimMouseAction::right);
    event->accept();
  }

}
