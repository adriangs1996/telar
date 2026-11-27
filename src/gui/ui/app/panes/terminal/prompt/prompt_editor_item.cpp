#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "prompt_editor_item.hpp"
#include "ui/design/controls/native_cell_text.hpp"
#include "ui/kit/scene/qt_buffers.hpp"
#include "ui/kit/scene/scene_nodes.hpp"
#include <QEasingCurve>
#include <QQuickWindow>
#include <QSGFlatColorMaterial>
#include <QSGGeometryNode>
#include <QSGNode>
#include <QSGRectangleNode>
#include <algorithm>
#include <exception>
#include <memory>

import telar.gui.application;
import telar.gui.foundation.core;
import telar.shell.syntax;
import telar.base.ds;

namespace telar::gui::qt {

  // How long a completed character takes to sweep in; a completion sweeps one character after
  // another, this far apart.
  static constexpr qint64 sweep_ms = 200;
  static constexpr qint64 sweep_step_ms = 16;
  static constexpr qint64 ghost_ms = 300;
  static constexpr std::size_t maximum_fresh = 200;
  // The ticker only paces frames, so its period is arbitrary: it loops until nothing moves.
  static constexpr int ticker_period_ms = 1000;

  namespace {

    // Whether `byte` continues a UTF-8 sequence instead of starting a character.
    [[nodiscard]] constexpr bool continuationByte(char byte) noexcept {
      constexpr unsigned prefix_mask = ~Utf8Scalar::continuation_mask;

      return (static_cast<unsigned char>(byte) & prefix_mask) == Utf8Scalar::continuation_prefix;
    }

    QColor blend(const QColor& from, const QColor& target, qreal amount) {
      return QColor::fromRgbF(static_cast<float>(static_cast<qreal>(from.redF()) + ((static_cast<qreal>(target.redF() - from.redF())) * amount)), static_cast<float>(static_cast<qreal>(from.greenF()) + ((static_cast<qreal>(target.greenF() - from.greenF())) * amount)), static_cast<float>(static_cast<qreal>(from.blueF()) + ((static_cast<qreal>(target.blueF() - from.blueF())) * amount)), static_cast<float>(static_cast<qreal>(from.alphaF()) + ((static_cast<qreal>(target.alphaF() - from.alphaF())) * amount)));
    }

    constexpr int menu_page = 8;

    // The columns a suggestion leaves at its row's end for the keys that take it.
    constexpr std::size_t hint_columns = 22;

    // The column the typed text ends on, in a row `columns` wide.
    std::size_t endColumn(std::string_view typed, std::size_t columns) noexcept { // NOLINT(bugprone-exception-escape): substr is given an offset within the text, which cannot throw
      const auto line_start = typed.rfind('\n');
      const auto line = line_start == std::string_view::npos ? typed : typed.substr(line_start + 1);

      return static_cast<std::size_t>(std::ranges::count_if(line, [](char byte) {
        return !continuationByte(byte);
      })) % columns;
    }

    // What of `ghost` fits on the row the typed text ends on, at column `used` of `columns`, a
    // column kept for the caret and room for the keys that take it: past it, the suggestion would
    // add rows and move the terminal as it comes and goes.
    std::string_view onCaretRow(std::string_view ghost, std::size_t used, std::size_t columns) noexcept { // NOLINT(bugprone-exception-escape,bugprone-easily-swappable-parameters): substr starts at 0, which cannot throw; the column, then the row's width
      const auto end_column = columns > hint_columns * 2 ? columns - hint_columns : columns;
      const auto room = used + 1 < end_column ? end_column - used - 1 : 0;

      ghost = ghost.substr(0, ghost.find('\n'));
      std::size_t end = 0;

      for (std::size_t characters = 0; end < ghost.size() && characters < room; ++characters) {
        ++end;
        while (end < ghost.size() && continuationByte(ghost[end])) {
          ++end;
        }
      }

      return ghost.substr(0, end);
    }

    // The page of the menu that holds the selected choice.
    std::pair<std::size_t, std::size_t> menuPage(const application::prompt::Menu& menu) {
      const auto first = menu.selected / menu_page * menu_page;

      return {first, std::min(menu.choices.size(), first + menu_page)};
    }

  }

  PromptEditorItem::PromptEditorItem(QQuickItem* parent)
      : QQuickItem(parent),
        ancestors_(*this) {
    setFlag(ItemHasContents);
    clock_.start();
    ticker_.setStartValue(0.0);
    ticker_.setEndValue(1.0);
    ticker_.setDuration(ticker_period_ms);
    ticker_.setLoopCount(-1);
    connect(&ticker_, &QVariantAnimation::valueChanged, this, &PromptEditorItem::tick);
    cacheColors();
  }

  PromptEditorItem::~PromptEditorItem() {
    if (controller_ != nullptr) {
      controller_->detach(*this);
    }
  }

  PromptController* PromptEditorItem::controller() const noexcept {
    return controller_;
  }

  void PromptEditorItem::setController(PromptController* controller) {
    if (controller_ == controller) {
      return;
    }

    if (controller_ != nullptr) {
      controller_->detach(*this);
    }

    controller_ = controller;
    if (controller_ != nullptr) {
      controller_->attach(*this);
    }

    refresh();
    emit controllerChanged();
  }

  // A pane's output reaches here as often as it paints: the layout is kept when nothing it draws
  // changed.
  void PromptEditorItem::refreshPane(std::uint64_t pane_id) {
    if (pane_id == pane_id_) {
      reuse_layout_ = true;
      refresh();
    }
  }

  QString PromptEditorItem::paneId() const {
    return QString::number(pane_id_);
  }

  void PromptEditorItem::setPaneId(const QString& identity) {
    const auto next = identity.toULongLong();
    if (pane_id_ != next) {
      pane_id_ = next;
      first_row_ = 0;
      refresh();
      emit paneIdChanged();
    }
  }

  QVariantMap PromptEditorItem::grid() const {
    return grid_;
  }

  void PromptEditorItem::setGrid(const QVariantMap& grid) {
    if (grid_ != grid) {
      grid_ = grid;
      refresh();
      emit gridChanged();
    }
  }

  QVariantMap PromptEditorItem::colors() const {
    return colors_;
  }

  void PromptEditorItem::setColors(const QVariantMap& colors) {
    if (colors_ != colors) {
      colors_ = colors;
      cacheColors();
      placeRuns();
      update();
      emit colorsChanged();
    }
  }

  int PromptEditorItem::maximumColumns() const noexcept {
    return maximum_columns_;
  }

  void PromptEditorItem::setMaximumColumns(int columns) {
    columns = std::max(columns, static_cast<int>(application::prompt::Layout::indent) + 4);
    if (maximum_columns_ != columns) {
      maximum_columns_ = columns;
      refresh();
      emit maximumColumnsChanged();
    }
  }

  QString PromptEditorItem::preedit() const {
    return preedit_;
  }

  void PromptEditorItem::setPreedit(const QString& preedit) {
    if (preedit_ != preedit) {
      preedit_ = preedit;
      refresh();
      emit preeditChanged();
    }
  }

  QString PromptEditorItem::surface() const {
    switch (static_cast<application::prompt::Surface>(surface_)) {
    case application::prompt::Surface::editor:
      return QStringLiteral("editor");
    case application::prompt::Surface::running:
      return QStringLiteral("running");
    case application::prompt::Surface::secret:
      return QStringLiteral("secret");
    case application::prompt::Surface::none:
      break;
    }

    return QStringLiteral("none");
  }

  QString PromptEditorItem::mode() const {
    const auto line = controller_ == nullptr ? ds::none : controller_->line(pane_id_);
    if (!line || line->keymap() == application::prompt::Keymap::emacs) {
      return QStringLiteral("emacs");
    }

    switch (line->mode()) {
    case application::prompt::Mode::insert:
      return QStringLiteral("insert");
    case application::prompt::Mode::normal:
      return QStringLiteral("normal");
    case application::prompt::Mode::visual:
      return QStringLiteral("visual");
    case application::prompt::Mode::visual_line:
      return QStringLiteral("visual-line");
    }

    return QStringLiteral("insert");
  }

  bool PromptEditorItem::suggesting() const noexcept {
    return !ghost_.empty();
  }

  int PromptEditorItem::block() const noexcept {
    const auto selected = controller_ == nullptr ? ds::none : controller_->selectedBlock(pane_id_);

    return selected ? static_cast<int>(*selected) + 1 : 0;
  }

  bool PromptEditorItem::blockTyping() const noexcept {
    return controller_ != nullptr && controller_->typingLeavesBlock(pane_id_);
  }

  int PromptEditorItem::blocks() const noexcept {
    const auto* pane = controller_ == nullptr ? nullptr : controller_->pane(pane_id_);

    return pane == nullptr ? 0 : static_cast<int>(pane->blocks.size());
  }

  QString PromptEditorItem::copying() const {
    const auto* copy = controller_ == nullptr ? nullptr : &controller_->copy();
    if (copy == nullptr || !*copy || (*copy)->pointer || (*copy)->pane_id != pane_id_) {
      return {};
    }

    if (!(*copy)->anchor) {
      return QStringLiteral("copy");
    }

    return (*copy)->linewise ? QStringLiteral("visual-line") : QStringLiteral("visual");
  }

  bool PromptEditorItem::queued() const noexcept {
    const auto line = controller_ == nullptr ? ds::none : controller_->line(pane_id_);

    return line.hasValue() && line->queued();
  }

  bool PromptEditorItem::cursorHidden() const noexcept {
    return cursor_hidden_;
  }

  bool PromptEditorItem::answering() const noexcept {
    const auto line = controller_ == nullptr ? ds::none : controller_->line(pane_id_);

    return line.hasValue() && line->answering();
  }

  int PromptEditorItem::secretKeys() const noexcept {
    constexpr std::uint32_t maximum_secret_keys = 64;
    const auto line = controller_ == nullptr ? ds::none : controller_->line(pane_id_);

    return !line ? 0 : static_cast<int>(std::min<std::uint32_t>(line->secretKeys(), maximum_secret_keys));
  }

  bool PromptEditorItem::failed() const noexcept {
    return failed_;
  }

  bool PromptEditorItem::empty() const noexcept {
    return display_.empty();
  }

  // QML reads the choices on every state change, which a pane's output sends with each frame: the
  // list is rebuilt only when the line's menu or text moved on.
  QVariantList PromptEditorItem::choices() const {
    const auto line = controller_ == nullptr ? ds::none : controller_->line(pane_id_);
    if (!line || !line->menu()) {
      choices_.line = nullptr;
      return {};
    }

    if (choices_.line == line->identity() && choices_.revision == line->revision()) {
      return choices_.choices;
    }

    choices_.line = line->identity();
    choices_.revision = line->revision();
    QVariantList result;
    const auto& menu = *line->menu();
    const auto [first, last] = menuPage(menu);
    // The letters of each choice that what was typed matches, in order, for the menu to mark.
    const auto text = line->text();
    const auto typed = menu.begin < menu.end && menu.end <= text.size() ? text.substr(menu.begin, menu.end - menu.begin) : std::string_view{};
    const auto fold = [](char byte) {
      return byte >= 'A' && byte <= 'Z' ? static_cast<char>(byte + ('a' - 'A')) : byte;
    };

    for (auto index = first; index < last; ++index) {
      const auto& choice = menu.choices[index];
      QVariantList segments;
      std::size_t matched = 0;
      std::size_t start = 0;
      bool marked = false;

      for (std::size_t offset = 0; offset <= choice.text.size(); ++offset) {
        const bool hit = offset < choice.text.size() && matched < typed.size() && fold(choice.text[offset]) == fold(typed[matched]);
        const bool boundary = offset == choice.text.size() || (hit != marked && !continuationByte(choice.text[offset]));
        if (boundary && offset > start) {
          segments.push_back(QVariantMap{{QStringLiteral("text"), QString::fromUtf8(choice.text.view().substr(start, offset - start).data(), static_cast<qsizetype>(offset - start))}, {QStringLiteral("marked"), marked}});
          start = offset;
        }

        if (boundary) {
          marked = hit;
        }

        matched += static_cast<std::size_t>(hit);
      }

      result.push_back(QVariantMap{
          {QStringLiteral("text"), QString::fromUtf8(choice.text.data(), static_cast<qsizetype>(choice.text.size()))},
          {QStringLiteral("segments"), segments},
          {QStringLiteral("description"), QString::fromUtf8(choice.description.data(), static_cast<qsizetype>(choice.description.size()))},
          {QStringLiteral("selected"), index == menu.selected},
      });
    }

    if (!menu.requests.empty() && result.isEmpty()) {
      result.push_back(QVariantMap{{QStringLiteral("text"), QStringLiteral("…")}, {QStringLiteral("description"), QString{}}, {QStringLiteral("selected"), false}});
    }

    choices_.choices = result;
    return result;
  }

  int PromptEditorItem::choice() const noexcept {
    const auto line = controller_ == nullptr ? ds::none : controller_->line(pane_id_);
    if (!line || !line->menu()) {
      return -1;
    }

    return static_cast<int>(line->menu()->selected - menuPage(*line->menu()).first);
  }

  QString PromptEditorItem::menuLabel() const {
    const auto line = controller_ == nullptr ? ds::none : controller_->line(pane_id_);
    if (!line || !line->menu()) {
      return {};
    }

    const auto& menu = *line->menu();
    auto label = QString::fromUtf8(menu.label.data(), static_cast<qsizetype>(menu.label.size()));

    // More choices than a page shows: which one is selected, and of how many.
    if (std::cmp_greater(menu.choices.size(), menu_page)) {
      const auto place = QStringLiteral("%1/%2").arg(menu.selected + 1).arg(menu.choices.size());

      label = label.isEmpty() ? place : label + QStringLiteral(" · ") + place;
    }

    return label;
  }

  bool PromptEditorItem::remote() const noexcept {
    const auto* pane = controller_ == nullptr ? nullptr : controller_->pane(pane_id_);

    return pane != nullptr && pane->shell.remote;
  }

  QString PromptEditorItem::host() const {
    const auto* pane = controller_ == nullptr ? nullptr : controller_->pane(pane_id_);
    if (pane == nullptr || !pane->shell.remote) {
      return {};
    }

    return QString::fromUtf8(pane->shell.host.data(), static_cast<qsizetype>(pane->shell.host.size()));
  }

  int PromptEditorItem::link() const noexcept {
    const auto* pane = controller_ == nullptr ? nullptr : controller_->pane(pane_id_);

    return pane == nullptr ? 0 : static_cast<int>(pane->shell.link_ms);
  }

  QString PromptEditorItem::interruptKey() const {
    // Caret notation: a control character reads as ⌃ and the character this far above it.
    constexpr Byte delete_key = 0x7f;
    constexpr Byte first_printable = 0x20;
    constexpr Byte caret_notation_offset = 0x40;
    const auto* pane = controller_ == nullptr ? nullptr : controller_->pane(pane_id_);
    const auto key = pane == nullptr ? Byte{0} : pane->shell.interrupt;
    if (key == 0) {
      return {};
    }

    if (key == delete_key) {
      return QStringLiteral("\u2303?");
    }

    if (key < first_printable) {
      return QStringLiteral("\u2303") + QChar(static_cast<char16_t>(key + caret_notation_offset));
    }

    return {QChar(static_cast<char16_t>(key))};
  }

  QString PromptEditorItem::program() const {
    const auto* pane = controller_ == nullptr ? nullptr : controller_->pane(pane_id_);

    return pane == nullptr ? QString{} : QString::fromUtf8(pane->foreground.data(), static_cast<qsizetype>(pane->foreground.size()));
  }

  QString PromptEditorItem::directory() const {
    const auto* pane = controller_ == nullptr ? nullptr : controller_->pane(pane_id_);
    if (pane == nullptr) {
      return {};
    }

    // A remote shell works on its host: this one's directory, ssh's, would mislead.
    const auto cwd = pane->shell.remote ? pane->shell.directory : std::string_view{pane->cwd};

    return QString::fromUtf8(cwd.data(), static_cast<qsizetype>(cwd.size()));
  }

  QString PromptEditorItem::branch() const {
    const auto* pane = controller_ == nullptr ? nullptr : controller_->pane(pane_id_);
    if (pane == nullptr || !pane->git.repository) {
      return {};
    }

    return QString::fromUtf8(pane->git.branch.data(), static_cast<qsizetype>(pane->git.branch.size()));
  }

  int PromptEditorItem::progress() const noexcept {
    constexpr int complete = 100;
    const auto* pane = controller_ == nullptr ? nullptr : controller_->pane(pane_id_);
    if (pane == nullptr || pane->progress_state == PaneProgressState::remove) {
      return -1;
    }

    if (pane->progress_state == PaneProgressState::indeterminate || !pane->progress_percent) {
      return -2;
    }

    return std::min<int>(complete, *pane->progress_percent);
  }

  int PromptEditorItem::commands() const noexcept {
    const auto* pane = controller_ == nullptr ? nullptr : controller_->pane(pane_id_);

    return pane == nullptr ? 0 : static_cast<int>(pane->shell.commands);
  }

  int PromptEditorItem::status() const noexcept {
    const auto* pane = controller_ == nullptr ? nullptr : controller_->pane(pane_id_);

    return pane == nullptr ? 0 : pane->shell.status;
  }

  QString PromptEditorItem::motion() const {
    if (controller_ == nullptr) {
      return QStringLiteral("spring");
    }

    switch (controller_->configuration().prompt.motion) {
    case PromptMotion::ease:
      return QStringLiteral("ease");
    case PromptMotion::none:
      return QStringLiteral("none");
    case PromptMotion::spring:
      break;
    }

    return QStringLiteral("spring");
  }

  int PromptEditorItem::rows() const noexcept {
    return static_cast<int>(layout_.rows);
  }

  int PromptEditorItem::visibleRows() const noexcept {
    return std::min(static_cast<int>(layout_.rows), maximum_rows_);
  }

  void PromptEditorItem::placeCaret(QPointF point) {
    const auto line = controller_ == nullptr ? ds::none : controller_->line(pane_id_);
    if (!line || cellWidth() <= 0 || cellHeight() <= 0) {
      return;
    }

    const auto row = static_cast<std::uint32_t>(std::max(0, first_row_ + static_cast<int>(std::floor(point.y() / cellHeight()))));
    const auto column = static_cast<std::uint32_t>(std::max(0.0, std::floor(point.x() / cellWidth())));
    const auto typed = line->text().size();
    ds::Option<std::size_t> offset;

    // The run under the column, a character a cell; past the row's last, the row's end.
    for (const auto& run : layout_.runs) {
      if (run.row != row || run.start >= typed) {
        continue;
      }

      if (column < run.column) {
        offset = offset.valueOr(run.start);
        break;
      }

      auto byte = run.start;

      for (auto cell = run.column; byte < run.end && cell < column; ++cell) {
        ++byte;
        while (byte < run.end && continuationByte(display_.view()[byte])) {
          ++byte;
        }
      }

      offset = std::min(byte, typed);
      if (column < run.column + run.columns) {
        break;
      }
    }

    if (offset) {
      controller_->placeCursor(pane_id_, *offset);
    }
  }

  int PromptEditorItem::columns() const noexcept {
    return static_cast<int>(layout_.width);
  }

  QVariantList PromptEditorItem::glows() const {
    return glows_;
  }

  qreal PromptEditorItem::cellWidth() const noexcept {
    return resolved_.metrics.width / scale_;
  }

  qreal PromptEditorItem::cellHeight() const noexcept {
    return resolved_.metrics.height / scale_;
  }

  QRectF PromptEditorItem::caret() const noexcept {
    const auto width = cellWidth();
    const auto height = cellHeight();

    return {layout_.caret_column * width, (static_cast<int>(layout_.caret_row) - first_row_) * height, layout_.caret_columns * width, height};
  }

  void PromptEditorItem::geometryChange(const QRectF& current, const QRectF& previous) {
    QQuickItem::geometryChange(current, previous);
    update();
  }

  void PromptEditorItem::itemChange(ItemChange change, const ItemChangeData& data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemParentHasChanged) {
      ancestors_.observe();
    }

    if (change == ItemSceneChange || change == ItemDevicePixelRatioHasChanged) {
      refresh();
    }
  }

  // Rebuilds the layout from the session's editor: the command with any composition at the caret,
  // coloured, wrapped at the line's width, scrolled so the caret stays in view.
  void PromptEditorItem::refresh() {
    const bool reuse_layout = std::exchange(reuse_layout_, false);
    const auto previous_surface = surface_;
    const auto previous_failed = failed_;
    const auto previous_cursor_hidden = cursor_hidden_;

    if (controller_ == nullptr || window() == nullptr || pane_id_ == 0) {
      surface_ = 0;
      cursor_hidden_ = false;
      if (previous_surface != surface_ || previous_cursor_hidden) {
        emit stateChanged();
      }

      return;
    }

    const bool cell_changed = resolveGrid();

    surface_ = static_cast<std::uint8_t>(controller_->surface(pane_id_));
    cursor_hidden_ = controller_->hidesTerminalCursor(pane_id_);
    const auto* pane = controller_->pane(pane_id_);

    failed_ = pane != nullptr && pane->shell.commands != 0 && pane->shell.status != 0;
    maximum_rows_ = std::max<int>(1, controller_->configuration().prompt.max_lines);

    const auto line = controller_->line(pane_id_);
    const auto text = !line ? std::string_view{} : line->text();
    const auto cursor = !line ? 0 : line->cursor();
    const auto anchor = !line ? 0 : line->anchor();
    const auto composing = preedit_.toUtf8();
    const auto composed = compose(text, cursor, std::string_view{composing.constData(), static_cast<std::size_t>(composing.size())});

    styleDisplay(composed, pane);
    groupFresh(composed);

    const auto shifted = [&](std::size_t offset) {
      return offset >= cursor ? offset + composed.composing : offset;
    };

    const auto caret = shifted(cursor);
    const auto mark = shifted(anchor);
    // vim's visual modes highlight what their commands take, more than the selection.
    const auto visual = !line ? ds::none : line->highlight();
    const auto range = visual ? ds::Option{std::pair{shifted(visual->first), shifted(visual->second)}} : ds::none;
    const auto state_changed = [&] {
      return previous_surface != surface_ || previous_failed != failed_ || previous_cursor_hidden != cursor_hidden_ || line.hasValue();
    };

    const bool unchanged = reuse_layout && !cell_changed && !animating(clock_.elapsed()) && display_.view() == laid_.display.view() && std::ranges::equal(styles_.view(), laid_.styles.view()) && std::ranges::equal(groups_.view(), laid_.groups.view()) && caret == laid_.caret && mark == laid_.anchor && range == laid_.range && maximum_columns_ == laid_.columns && maximum_rows_ == laid_.rows;
    if (unchanged) {
      if (state_changed()) {
        emit stateChanged();
      }

      return;
    }

    lay(caret, mark, range);
    placeRuns();
    if (animating(clock_.elapsed()) && ticker_.state() != QAbstractAnimation::Running) {
      ticker_.start();
    }

    ++revision_;
    emit layoutChanged();
    if (state_changed()) {
      emit stateChanged();
    }

    update();
  }

  // Reads the cell grid at the window's scale, announcing a change of the cell's size; true when
  // it changed.
  bool PromptEditorItem::resolveGrid() {
    const auto previous_cell = QSizeF{cellWidth(), cellHeight()};

    try {
      scale_ = window()->effectiveDevicePixelRatio();
      resolved_ = CellTextGrid::resolve(grid_, scale_);
    } catch (const std::exception&) {
      resolved_ = {};
    }

    const bool cell_changed = previous_cell != QSizeF{cellWidth(), cellHeight()};
    if (cell_changed) {
      emit metricsChanged();
    }

    return cell_changed;
  }

  // Fills display_ with the command, the composition at the cursor and the suggestion after them.
  PromptEditorItem::Composed PromptEditorItem::compose(std::string_view text, std::size_t cursor, std::string_view composing) {
    const bool moving = controller_->configuration().prompt.motion != PromptMotion::none;

    track(text, moving && composing.empty() && static_cast<application::prompt::Surface>(surface_) == application::prompt::Surface::editor);
    display_.assign(text.substr(0, cursor));
    display_.append(composing);
    display_.append(text.substr(cursor));
    const auto typed = display_.size();
    const auto ghost = composing.empty() && controller_->configuration().prompt.ghost ? controller_->suggestion(pane_id_) : std::string_view{};
    // A new suggestion fades in; one that still fits what was typed stays as it was.
    if (ghost != ghost_.view()) {
      const bool continues = !ghost.empty() && ghost_.view().ends_with(ghost);
      if (!continues) {
        ghost_started_ms_ = moving && !ghost.empty() ? clock_.elapsed() : -1;
      }

      ghost_.assign(ghost);
    }

    if (const auto columns = static_cast<std::size_t>(std::max(0, maximumColumns())); columns != 0) {
      display_.append(onCaretRow(ghost, endColumn(display_.view(), columns), columns));
    }

    return {.cursor = cursor, .composing = composing.size(), .typed = typed};
  }

  void PromptEditorItem::styleDisplay(const Composed& composed, const application::Pane<Memory>* pane) {
    styles_.clear();
    styles_.resize(display_.size(), application::prompt::Style::plain);
    const auto typed = composed.typed;
    const auto styles = styles_.viewMut();
    const auto dialect = pane != nullptr && pane->shell.shell == IntegratedShell::fish ? shell::Dialect::fish : shell::Dialect::posix;

    // What was typed alone: the word at its end is still being typed, whatever the suggestion
    // after it would make of it.
    application::prompt::classify(display_.view().substr(0, typed), styles.first(typed), tokens_, shell::Syntax{.dialect = dialect});
    std::ranges::fill(styles.subspan(composed.cursor, composed.composing), application::prompt::Style::pending);
    std::ranges::fill(styles.subspan(typed), application::prompt::Style::ghost);
    markCommands(typed);
  }

  // A command the shell does not run is marked; one the runtime is still looking for waits.
  void PromptEditorItem::markCommands(std::size_t typed) {
    const auto styles = styles_.viewMut();

    for (std::size_t start = 0; start < typed;) {
      if (styles_[start] != application::prompt::Style::command) {
        ++start;
        continue;
      }

      auto end = start;

      while (end < typed && styles_[end] == application::prompt::Style::command) {
        ++end;
      }

      const auto presence = controller_->commandPresence(pane_id_, display_.view().substr(start, end - start));
      if (presence == application::prompt::CommandPresence::missing || presence == application::prompt::CommandPresence::pending) {
        std::ranges::fill(styles.subspan(start, end - start), presence == application::prompt::CommandPresence::missing ? application::prompt::Style::missing : application::prompt::Style::pending);
      }

      start = end;
    }
  }

  // Marks the typed text of each fresh edit with its group, from 1, for the layout to keep its
  // runs apart; nothing animates while a composition is under way.
  void PromptEditorItem::groupFresh(const Composed& composed) {
    groups_.clear();
    groups_.resize(display_.size(), 0);
    if (composed.composing != 0) {
      return;
    }

    const auto typed = composed.typed;
    const auto groups = groups_.viewMut();

    for (std::size_t index = 0; index < fresh_.size(); ++index) {
      const auto& fresh = fresh_[index];
      const auto begin = std::min(fresh.start, typed);
      const auto end = std::min(fresh.end, typed);

      std::ranges::fill(groups.subspan(begin, end - begin), static_cast<std::uint8_t>(index + 1));
    }
  }

  // Lays the display out, remembers what from, and scrolls so the caret's row shows.
  void PromptEditorItem::lay(std::size_t caret, std::size_t mark, ds::Option<std::pair<std::size_t, std::size_t>> range) {
    application::prompt::layout(layout_, {.text = display_.view(), .styles = styles_.view(), .groups = groups_.view()}, {.cursor = caret, .anchor = mark, .range = range}, static_cast<std::uint32_t>(maximum_columns_));
    laid_.range = range;
    laid_.display.assign(display_.view());
    laid_.styles.clear();
    laid_.styles.extend(styles_.view());
    laid_.groups.clear();
    laid_.groups.extend(groups_.view());
    laid_.caret = caret;
    laid_.anchor = mark;
    laid_.columns = maximum_columns_;
    laid_.rows = maximum_rows_;

    const auto caret_row = static_cast<int>(layout_.caret_row);
    if (caret_row < first_row_) {
      first_row_ = caret_row;
    } else if (caret_row >= first_row_ + maximum_rows_) {
      first_row_ = caret_row - maximum_rows_ + 1;
    }

    first_row_ = std::clamp(first_row_, 0, std::max(0, static_cast<int>(layout_.rows) - maximum_rows_));
  }

  // Each run is a cell text item, reused across edits: an item reshapes only when its own text
  // changes, so typing at the end of a long command reshapes one run.
  void PromptEditorItem::placeRuns() {
    const QSizeF cell{cellWidth(), cellHeight()};
    std::size_t used = 0;
    const auto now = clock_.elapsed();
    QVariantList glows;

    // By index and a copy of each run: placing one reaches the item, which holds the layout.
    for (std::size_t index = 0; index < layout_.runs.size(); ++index) { // NOLINT(modernize-loop-convert): tbc rejects an iterator held across placeRun.
      if (const auto run = layout_.runs[index]; rowVisible(run.row)) {
        placeRun(used++, run, look(run, cell, now, glows), cell);
      }
    }

    for (auto index = used; index < runs_.size(); ++index) {
      runs_[index]->setVisible(false);
    }

    if (!glows.isEmpty() || !glows_.isEmpty()) {
      glows_ = std::move(glows);
      emit glowsChanged();
    }
  }

  // Shows `run` with the run item at `index`, the next after those placed; one more is made when
  // they run out.
  void PromptEditorItem::placeRun(std::size_t index, const application::prompt::Run& run, const RunLook& look, QSizeF cell) {
    if (index == runs_.size()) {
      runs_.push(std::make_unique<NativeCellText>(this).release());
    }

    auto* item = runs_[index];

    item->setGrid(grid_);
    const auto bytes = display_.view().substr(run.start, run.end - run.start);

    // A hidden character shows as the mark that names it, never as itself.
    if (run.style == application::prompt::Style::hidden) {
      ds::String<Memory> marks{adapter_};

      application::prompt::hiddenMarks(bytes, marks);
      item->setText(QString::fromUtf8(marks.view().data(), static_cast<qsizetype>(marks.size())));
    } else {
      item->setText(QString::fromUtf8(bytes.data(), static_cast<qsizetype>(bytes.size())));
    }

    item->setColor(look.color);
    item->setPosition({run.column * cell.width(), (static_cast<int>(run.row) - first_row_) * cell.height()});
    item->setOpacity(look.opacity);
    item->setVisible(true);
  }

  // Fresh text sweeps in from the accent, adding where it glows; a new suggestion fades in.
  PromptEditorItem::RunLook PromptEditorItem::look(const application::prompt::Run& run, QSizeF cell, qint64 now, QVariantList& glows) const {
    [[clang::no_destroy]] static const QEasingCurve sweep_curve{QEasingCurve::OutQuad};
    RunLook result{.color = styleColor(run.style)};

    if (run.group == 0 || run.group > fresh_.size()) {
      if (run.style == application::prompt::Style::ghost && ghost_started_ms_ >= 0) {
        result.opacity = std::clamp(static_cast<qreal>(now - ghost_started_ms_) / ghost_ms, 0.0, 1.0);
      }

      return result;
    }

    const auto& fresh = fresh_[run.group - 1];
    const auto elapsed = static_cast<qreal>(now - fresh.started_ms);
    const auto width = cell.width();
    const auto height = cell.height();
    const auto progress = sweep_curve.valueForProgress(std::clamp(elapsed / sweep_ms, 0.0, 1.0));

    result.color = blend(accent_, result.color, progress);
    if (progress < 1) {
      glows.push_back(QVariantMap{{QStringLiteral("x"), run.column * width}, {QStringLiteral("y"), (static_cast<int>(run.row) - first_row_) * height}, {QStringLiteral("width"), run.columns * width}, {QStringLiteral("height"), height}, {QStringLiteral("strength"), 1 - progress}});
    }

    return result;
  }

  bool PromptEditorItem::rowVisible(std::uint32_t row) const noexcept {
    return std::cmp_greater_equal(row, first_row_) && std::cmp_less(row, first_row_ + maximum_rows_);
  }

  QColor PromptEditorItem::styleColor(application::prompt::Style style) const {
    return style_colors_[static_cast<std::size_t>(style)];
  }

  void PromptEditorItem::cacheColors() {
    for (std::size_t index = 0; index < style_colors_.size(); ++index) {
      style_colors_.atMut(index) = roleColor(static_cast<application::prompt::Style>(index));
    }

    accent_ = colors_.value(QStringLiteral("accent")).value<QColor>();
    underline_ = colors_.value(QStringLiteral("overlay1")).value<QColor>();
  }

  QColor PromptEditorItem::roleColor(application::prompt::Style style) const {
    const auto role = [&](const char* name, const char* fallback) {
      const auto value = colors_.value(QString::fromLatin1(name));

      return value.isValid() ? value.value<QColor>() : colors_.value(QString::fromLatin1(fallback)).value<QColor>();
    };

    // Shell syntax takes the theme's syntax roles, so the prompt reads like the shell in the
    // editor; pending, error, missing and ghost text are editor states in chrome colors.
    switch (style) {
    case application::prompt::Style::command:
      return role("syntax_func", "foreground");
    case application::prompt::Style::option:
    case application::prompt::Style::variable:
      return role("syntax_parameter", "foreground");
    case application::prompt::Style::string:
      return role("syntax_string", "foreground");
    case application::prompt::Style::shell_operator:
      return role("syntax_operator", "muted");
    case application::prompt::Style::keyword:
      return role("syntax_keyword", "accent");
    case application::prompt::Style::comment:
      return role("syntax_comment", "muted");
    case application::prompt::Style::pending:
      return role("subtext0", "muted");
    case application::prompt::Style::error:
    case application::prompt::Style::missing:
    case application::prompt::Style::hidden:
      return role("red", "failure");
    case application::prompt::Style::ghost: {
      constexpr float ghost_alpha = 0.7F;
      auto color = role("overlay1", "muted");

      color.setAlphaF(color.alphaF() * ghost_alpha);
      return color;
    }
    case application::prompt::Style::path:
    case application::prompt::Style::plain:
      break;
    }

    return role("text", "foreground");
  }

  // Follows what the editor holds: text inserted at one place animates in, text removed
  // cancels what animated there, and the rest moves with the edit.
  void PromptEditorItem::track(std::string_view text, bool animate) {
    const auto previous = typed_.view();
    const auto now = clock_.elapsed();

    static_cast<void>(fresh_.retain([&](const Fresh& fresh) {
      return now - fresh.started_ms < sweep_ms;
    }));

    if (text == previous) {
      return;
    }

    const auto shortest = std::min(previous.size(), text.size());
    std::size_t prefix = 0;

    while (prefix < shortest && previous[prefix] == text[prefix]) {
      ++prefix;
    }

    std::size_t suffix = 0;

    while (suffix < shortest - prefix && previous[previous.size() - 1 - suffix] == text[text.size() - 1 - suffix]) {
      ++suffix;
    }

    // Whole characters: the edit starts and ends on their boundaries.
    while (prefix > 0 && prefix < text.size() && continuationByte(text[prefix])) {
      --prefix;
    }

    while (suffix > 0 && continuationByte(text[text.size() - suffix])) {
      --suffix;
    }

    const auto removed = previous.size() - prefix - suffix;
    const auto inserted = text.size() - prefix - suffix;

    typed_.assign(text);

    static_cast<void>(fresh_.retain([&](const Fresh& fresh) {
      return fresh.end <= prefix || fresh.start >= prefix + std::max<std::size_t>(removed, 1);
    }));

    for (auto& fresh : fresh_.viewMut()) {
      if (fresh.start >= prefix + removed) {
        fresh.start = fresh.start + inserted - removed;
        fresh.end = fresh.end + inserted - removed;
      }
    }

    if (!animate || removed != 0 || inserted == 0 || fresh_.size() > maximum_fresh) {
      if (!animate || fresh_.size() > maximum_fresh) {
        fresh_.clear();
      }

      return;
    }

    animateInsertion(prefix, text.substr(prefix, inserted), now);
  }

  // A character typed shows in its place at once, as a terminal echoes it: what is typed is
  // never late. A completion or a suggestion taken sweeps in, each character after the one before.
  void PromptEditorItem::animateInsertion(std::size_t prefix, std::string_view added, qint64 now) {
    std::size_t characters = 0;

    for (const auto byte : added) {
      characters += static_cast<std::size_t>(!continuationByte(byte));
    }

    if (characters == 1) {
      return;
    }

    std::size_t start = prefix;
    qint64 delay = 0;

    for (std::size_t offset = 1; offset <= added.size() && fresh_.size() < maximum_fresh; ++offset) {
      if (offset < added.size() && continuationByte(added[offset])) {
        continue;
      }

      fresh_.push({.start = start, .end = prefix + offset, .started_ms = now + delay});
      start = prefix + offset;
      delay += sweep_step_ms;
    }
  }

  bool PromptEditorItem::animating(qint64 now) const noexcept {
    if (ghost_started_ms_ >= 0 && now - ghost_started_ms_ < ghost_ms) {
      return true;
    }

    return std::ranges::any_of(fresh_, [&](const Fresh& fresh) {
      return now - fresh.started_ms < sweep_ms;
    });
  }

  // A frame of the animation: runs take their place for now, and the layout merges them back
  // once nothing moves.
  void PromptEditorItem::tick() {
    if (animating(clock_.elapsed())) {
      placeRuns();
      return;
    }

    ticker_.stop();
    ghost_started_ms_ = -1;
    fresh_.clear();
    refresh();
  }

  namespace {

    // How strongly the selection and the underlines show over the text.
    constexpr float selection_alpha = 0.28F;
    constexpr float missing_underline_alpha = 0.8F;
    constexpr float path_underline_alpha = 0.7F;

    // Hands out the children of `parent` in order, creating one when it runs out, and deletes those
    // left over once dropped: a paint node keeps its nodes from one update to the next.
    class ChildNodes {
    public:
      explicit ChildNodes(QSGNode& parent) noexcept
          : parent_(parent),
            next_(parent.firstChild()) {}

      ~ChildNodes() {
        while (next_ != nullptr) {
          std::unique_ptr<QSGNode> child{next_};

          next_ = child->nextSibling();
          parent_.removeChildNode(child.get());
        }
      }

      ChildNodes(const ChildNodes&) = delete;
      ChildNodes& operator=(const ChildNodes&) = delete;
      ChildNodes(ChildNodes&&) = delete;
      ChildNodes& operator=(ChildNodes&&) = delete;

      template <typename Node, typename Create>
      Node& take(Create&& create) {
        if (next_ != nullptr) {
          auto* child = static_cast<Node*>(next_);

          next_ = next_->nextSibling();
          return *child;
        }

        auto* child = std::forward<Create>(create)();

        parent_.appendChildNode(child);
        return *child;
      }

    private:
      QSGNode& parent_;
      QSGNode* next_;
    };

    // An underline: a line strip or a run of dashes in one colour, its geometry and material
    // held in the node.
    class UnderlineNode final : public QSGGeometryNode {
    public:
      UnderlineNode()
          : geometry_(QSGGeometry::defaultAttributes_Point2D(), 0) {
        geometry_.setLineWidth(1);
        setGeometry(&geometry_);
        setMaterial(&material_);
      }

      ~UnderlineNode() override = default;
      UnderlineNode(const UnderlineNode&) = delete;
      UnderlineNode& operator=(const UnderlineNode&) = delete;
      UnderlineNode(UnderlineNode&&) = delete;
      UnderlineNode& operator=(UnderlineNode&&) = delete;

      void setColor(const QColor& color) {
        material_.setColor(color);
      }

    private:
      QSGGeometry geometry_;
      QSGFlatColorMaterial material_;
    };

  }

  // The root holds two groups, the selection's rectangles and the underlines' lines, so each
  // group's nodes are of one type and are reused in place.
  QSGNode* PromptEditorItem::updatePaintNode(QSGNode* previous, [[maybe_unused]] UpdatePaintNodeData* data) {
    auto* root = previous != nullptr ? previous : new QSGNode;
    if (root->childCount() != 2) {
      clearSceneChildren(*root);
      appendSceneNode<QSGNode>(*root);
      appendSceneNode<QSGNode>(*root);
    }

    if (window() == nullptr || resolved_.metrics.width <= 0) {
      clearSceneChildren(*root->firstChild());
      clearSceneChildren(*root->lastChild());
      return root;
    }

    paintSelection(*root->firstChild());
    paintUnderlines(*root->lastChild());
    return root;
  }

  void PromptEditorItem::paintSelection(QSGNode& group) const {
    ChildNodes selections{group};
    const auto width = cellWidth();
    const auto height = cellHeight();
    auto selection = accent_;

    selection.setAlphaF(selection_alpha);
    for (const auto& range : layout_.selection) {
      if (!rowVisible(range.row)) {
        continue;
      }

      auto& rectangle = selections.take<QSGRectangleNode>([&] {
        return window()->createRectangleNode();
      });

      rectangle.setRect(range.column * width, (static_cast<int>(range.row) - first_row_) * height, range.columns * width, height);
      rectangle.setColor(selection);
    }
  }

  // A command the shell does not run gets a wavy underline; a path, a dotted one.
  void PromptEditorItem::paintUnderlines(QSGNode& group) const {
    ChildNodes underlines{group};
    const auto width = cellWidth();
    const auto height = cellHeight();
    const auto pixel = 1.0 / scale_;

    for (const auto& run : layout_.runs) {
      if ((run.style != application::prompt::Style::missing && run.style != application::prompt::Style::path) || !rowVisible(run.row)) {
        continue;
      }

      const bool wavy = run.style == application::prompt::Style::missing;
      const auto left = run.column * width;
      const auto right = (run.column + run.columns) * width;
      const auto baseline = ((static_cast<int>(run.row) - first_row_ + 1) * height) - (2 * pixel);
      const auto step = wavy ? width / 4 : 3 * pixel;
      const auto points = static_cast<int>(std::ceil((right - left) / step)) + 1;
      auto& node = underlines.take<UnderlineNode>([] {
        return std::make_unique<UnderlineNode>().release();
      });

      auto* geometry = node.geometry();

      geometry->allocate(wavy ? points : (points / 2) * 2);
      geometry->setDrawingMode(wavy ? QSGGeometry::DrawLineStrip : QSGGeometry::DrawLines);
      auto vertices = geometryVertices<QSGGeometry::Point2D>(*geometry, static_cast<std::size_t>(geometry->vertexCount()));

      for (int index = 0; index < geometry->vertexCount(); ++index) {
        const auto x = std::min(right, left + (index * step));
        const auto y = wavy ? baseline + (index % 2 == 0 ? -pixel : pixel) : baseline;

        vertices[static_cast<std::size_t>(index)].set(static_cast<float>(x), static_cast<float>(y));
      }

      auto color = wavy ? styleColor(run.style) : underline_;

      color.setAlphaF(wavy ? missing_underline_alpha : path_underline_alpha);
      node.setColor(color);
      node.markDirty(QSGNode::DirtyGeometry | QSGNode::DirtyMaterial);
    }
  }

}
