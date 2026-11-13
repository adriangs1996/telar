#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "prompt_editor_item.hpp"
#include "application.hpp"
#include "native_cell_text.hpp"
#include <algorithm>
#include <exception>
#include <QEasingCurve>
#include <QQuickWindow>
#include <QSGFlatColorMaterial>
#include <QSGGeometryNode>
#include <QSGNode>
#include <QSGRectangleNode>


namespace telar::gui::qt {

// How long a typed character takes to rise into place, and a completed one to sweep in; a
// completion sweeps one character after another, this far apart.
static constexpr qint64 rise_ms = 70;
static constexpr qint64 sweep_ms = 200;
static constexpr qint64 sweep_step_ms = 16;
static constexpr qint64 ghost_ms = 300;
static constexpr std::size_t maximum_fresh = 200;

PromptEditorItem::PromptEditorItem(QQuickItem *parent)
    : QQuickItem(parent),
      ancestors_(*this) {
  setFlag(ItemHasContents);
  clock_.start();
  ticker_.setStartValue(0.0);
  ticker_.setEndValue(1.0);
  ticker_.setDuration(1000);
  ticker_.setLoopCount(-1);
  connect(&ticker_, &QVariantAnimation::valueChanged, this, &PromptEditorItem::tick);
  cacheColors();
}

PromptEditorItem::~PromptEditorItem() = default;

QObject *PromptEditorItem::application() const noexcept {
  return application_;
}

void PromptEditorItem::setApplication(QObject *application) {
  auto *next = qobject_cast<Application *>(application);
  if (application_ == next) {
    return;
  }
  if (application_ != nullptr) {
    disconnect(application_, nullptr, this, nullptr);
  }
  application_ = next;
  if (application_ != nullptr) {
    // A pane's output reaches here as often as it paints: the layout is kept when nothing it
    // draws changed.
    const auto pane = [this](qulonglong pane_id) {
      if (pane_id == pane_id_) {
        reuse_layout_ = true;
        refresh();
      }
    };
    connect(application_, &Application::promptChanged, this, pane);
    connect(application_, &Application::terminalChanged, this, pane);
    connect(application_, &Application::configurationChanged, this, &PromptEditorItem::refresh);
  }
  refresh();
  emit applicationChanged();
}

QString PromptEditorItem::paneId() const {
  return QString::number(pane_id_);
}

void PromptEditorItem::setPaneId(const QString &identity) {
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

void PromptEditorItem::setGrid(const QVariantMap &grid) {
  if (grid_ != grid) {
    grid_ = grid;
    refresh();
    emit gridChanged();
  }
}

QVariantMap PromptEditorItem::colors() const {
  return colors_;
}

void PromptEditorItem::setColors(const QVariantMap &colors) {
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
  columns = std::max(columns, static_cast<int>(prompt::Layout::indent) + 4);
  if (maximum_columns_ != columns) {
    maximum_columns_ = columns;
    refresh();
    emit maximumColumnsChanged();
  }
}

QString PromptEditorItem::preedit() const {
  return preedit_;
}

void PromptEditorItem::setPreedit(const QString &preedit) {
  if (preedit_ != preedit) {
    preedit_ = preedit;
    refresh();
    emit preeditChanged();
  }
}

QString PromptEditorItem::surface() const {
  switch (static_cast<prompt::Surface>(surface_)) {
  case prompt::Surface::editor:
    return QStringLiteral("editor");
  case prompt::Surface::running:
    return QStringLiteral("running");
  case prompt::Surface::secret:
    return QStringLiteral("secret");
  case prompt::Surface::none:
    break;
  }
  return QStringLiteral("none");
}

QString PromptEditorItem::mode() const {
  const auto *line = application_ == nullptr ? nullptr : application_->promptLine(pane_id_);
  if (line == nullptr || line->editor().keymap() == prompt::Keymap::emacs) {
    return QStringLiteral("emacs");
  }
  switch (line->editor().mode()) {
  case prompt::Mode::insert:
    return QStringLiteral("insert");
  case prompt::Mode::normal:
    return QStringLiteral("normal");
  case prompt::Mode::visual:
    return QStringLiteral("visual");
  case prompt::Mode::visual_line:
    return QStringLiteral("visual-line");
  }
  return QStringLiteral("insert");
}

bool PromptEditorItem::suggesting() const noexcept {
  return !ghost_.empty();
}

int PromptEditorItem::block() const noexcept {
  const auto selected = application_ == nullptr ? std::nullopt : application_->selectedBlock(pane_id_);
  return selected ? static_cast<int>(*selected) + 1 : 0;
}

int PromptEditorItem::blocks() const noexcept {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  return pane == nullptr ? 0 : static_cast<int>(pane->blocks.size());
}

QString PromptEditorItem::copying() const {
  const auto *copy = application_ == nullptr ? nullptr : &application_->copyState();
  if (copy == nullptr || !*copy || (*copy)->pointer || (*copy)->pane_id != pane_id_) {
    return {};
  }
  if (!(*copy)->anchor) {
    return QStringLiteral("copy");
  }
  return (*copy)->linewise ? QStringLiteral("visual-line") : QStringLiteral("visual");
}

bool PromptEditorItem::queued() const noexcept {
  const auto *line = application_ == nullptr ? nullptr : application_->promptLine(pane_id_);
  return line != nullptr && line->queued();
}

bool PromptEditorItem::cursorHidden() const noexcept {
  return cursor_hidden_;
}

bool PromptEditorItem::answering() const noexcept {
  const auto *line = application_ == nullptr ? nullptr : application_->promptLine(pane_id_);
  return line != nullptr && line->answering();
}

int PromptEditorItem::secretKeys() const noexcept {
  const auto *line = application_ == nullptr ? nullptr : application_->promptLine(pane_id_);
  return line == nullptr ? 0 : static_cast<int>(std::min<std::uint32_t>(line->secretKeys(), 64));
}

bool PromptEditorItem::failed() const noexcept {
  return failed_;
}

bool PromptEditorItem::empty() const noexcept {
  return display_.empty();
}

static constexpr int menu_page = 8;

// The page of the menu that holds the selected choice.
static std::pair<std::size_t, std::size_t> menuPage(const prompt::Menu &menu) {
  const auto first = menu.selected / menu_page * menu_page;
  return {first, std::min(menu.choices.size(), first + menu_page)};
}

// QML reads the choices on every state change, which a pane's output sends with each frame: the
// list is rebuilt only when the line's menu or text moved on.
QVariantList PromptEditorItem::choices() const {
  const auto *line = application_ == nullptr ? nullptr : application_->promptLine(pane_id_);
  if (line == nullptr || !line->menu()) {
    choices_line_ = nullptr;
    return {};
  }
  if (choices_line_ == line && choices_revision_ == line->revision()) {
    return choices_;
  }
  choices_line_ = line;
  choices_revision_ = line->revision();
  QVariantList result;
  const auto &menu = *line->menu();
  const auto [first, last] = menuPage(menu);
  // The letters of each choice that what was typed matches, in order, for the menu to mark.
  const auto text = line->editor().text().view();
  const auto typed = menu.begin < menu.end && menu.end <= text.size() ? text.substr(menu.begin, menu.end - menu.begin) : std::string_view{};
  const auto fold = [](char byte) { return byte >= 'A' && byte <= 'Z' ? static_cast<char>(byte + ('a' - 'A')) : byte; };
  for (auto index = first; index < last; ++index) {
    const auto &choice = menu.choices[index];
    QVariantList segments;
    std::size_t matched = 0;
    std::size_t start = 0;
    bool marked = false;
    for (std::size_t offset = 0; offset <= choice.text.size(); ++offset) {
      const bool hit = offset < choice.text.size() && matched < typed.size() && fold(choice.text[offset]) == fold(typed[matched]);
      const bool boundary = offset == choice.text.size() || (hit != marked && (static_cast<unsigned char>(choice.text[offset]) & 0xc0) != 0x80);
      if (boundary && offset > start) {
        segments.push_back(QVariantMap{{QStringLiteral("text"), QString::fromUtf8(choice.text.data() + start, static_cast<qsizetype>(offset - start))}, {QStringLiteral("marked"), marked}});
        start = offset;
      }
      if (boundary) {
        marked = hit;
      }
      matched += hit;
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
  choices_ = result;
  return result;
}

int PromptEditorItem::choice() const noexcept {
  const auto *line = application_ == nullptr ? nullptr : application_->promptLine(pane_id_);
  if (line == nullptr || !line->menu()) {
    return -1;
  }
  return static_cast<int>(line->menu()->selected - menuPage(*line->menu()).first);
}

QString PromptEditorItem::menuLabel() const {
  const auto *line = application_ == nullptr ? nullptr : application_->promptLine(pane_id_);
  if (line == nullptr || !line->menu()) {
    return {};
  }
  const auto &label = line->menu()->label;
  return QString::fromUtf8(label.data(), static_cast<qsizetype>(label.size()));
}

bool PromptEditorItem::remote() const noexcept {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  return pane != nullptr && pane->shell.remote;
}

QString PromptEditorItem::host() const {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  if (pane == nullptr || !pane->shell.remote) {
    return {};
  }
  return QString::fromUtf8(pane->shell.host.data(), static_cast<qsizetype>(pane->shell.host.size()));
}

int PromptEditorItem::link() const noexcept {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  return pane == nullptr ? 0 : static_cast<int>(pane->shell.link_ms);
}

QString PromptEditorItem::interruptKey() const {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  const auto key = pane == nullptr ? Byte{0} : pane->shell.interrupt;
  if (key == 0) {
    return {};
  }
  if (key == 0x7f) {
    return QStringLiteral("\u2303?");
  }
  if (key < 0x20) {
    return QStringLiteral("\u2303") + QChar(static_cast<char16_t>(key + 0x40));
  }
  return QString(QChar(static_cast<char16_t>(key)));
}

QString PromptEditorItem::program() const {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  return pane == nullptr ? QString{} : QString::fromUtf8(pane->foreground.data(), static_cast<qsizetype>(pane->foreground.size()));
}

QString PromptEditorItem::directory() const {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  if (pane == nullptr) {
    return {};
  }
  // A remote shell works on its host: this one's directory, ssh's, would mislead.
  const auto cwd = pane->shell.remote ? pane->shell.directory : std::string_view{pane->cwd};
  return QString::fromUtf8(cwd.data(), static_cast<qsizetype>(cwd.size()));
}

QString PromptEditorItem::branch() const {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  if (pane == nullptr || !pane->git.repository) {
    return {};
  }
  return QString::fromUtf8(pane->git.branch.data(), static_cast<qsizetype>(pane->git.branch.size()));
}

int PromptEditorItem::progress() const noexcept {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  if (pane == nullptr || pane->progress_state == PaneProgressState::remove) {
    return -1;
  }
  if (pane->progress_state == PaneProgressState::indeterminate || !pane->progress_percent) {
    return -2;
  }
  return std::min<int>(100, *pane->progress_percent);
}

int PromptEditorItem::commands() const noexcept {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  return pane == nullptr ? 0 : static_cast<int>(pane->shell.commands);
}

int PromptEditorItem::status() const noexcept {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  return pane == nullptr ? 0 : pane->shell.status;
}

QString PromptEditorItem::motion() const {
  if (application_ == nullptr) {
    return QStringLiteral("spring");
  }
  switch (application_->configuration().prompt.motion) {
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

void PromptEditorItem::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  update();
}

void PromptEditorItem::itemChange(ItemChange change, const ItemChangeData &data) {
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
  if (application_ == nullptr || window() == nullptr || pane_id_ == 0) {
    surface_ = 0;
    cursor_hidden_ = false;
    if (previous_surface != surface_ || previous_cursor_hidden) {
      emit stateChanged();
    }
    return;
  }

  const auto previous_cell = QSizeF{cellWidth(), cellHeight()};
  try {
    scale_ = window()->effectiveDevicePixelRatio();
    resolved_ = CellTextGrid::resolve(grid_, scale_);
  } catch (const std::exception &) {
    resolved_ = {};
  }
  const bool cell_changed = previous_cell != QSizeF{cellWidth(), cellHeight()};
  if (cell_changed) {
    emit metricsChanged();
  }

  surface_ = static_cast<std::uint8_t>(application_->promptSurface(pane_id_));
  cursor_hidden_ = application_->hidesTerminalCursor(pane_id_);
  const auto *pane = application_->pane(pane_id_);
  failed_ = pane != nullptr && pane->shell.commands != 0 && pane->shell.status != 0;
  maximum_rows_ = std::max<int>(1, application_->configuration().prompt.max_lines);

  const auto *line = application_->promptLine(pane_id_);
  const auto text = line == nullptr ? std::string_view{} : line->editor().text().view();
  const auto cursor = line == nullptr ? 0 : line->editor().text().cursor();
  const auto anchor = line == nullptr ? 0 : line->editor().text().anchor();
  const auto composing = preedit_.toUtf8();
  const bool moving = application_->configuration().prompt.motion != PromptMotion::none;
  track(text, moving && composing.isEmpty() && static_cast<prompt::Surface>(surface_) == prompt::Surface::editor);
  display_.assign(text.substr(0, cursor));
  display_.append(composing.constData(), static_cast<std::size_t>(composing.size()));
  display_.append(text.substr(cursor));
  const auto typed = display_.size();
  const auto ghost = composing.isEmpty() && application_->configuration().prompt.ghost ? application_->promptSuggestion(pane_id_) : std::string_view{};
  // A new suggestion fades in; one that still fits what was typed stays as it was.
  if (ghost != std::string_view{ghost_}) {
    const bool continues = !ghost.empty() && std::string_view{ghost_}.ends_with(ghost);
    if (!continues) {
      ghost_started_ms_ = moving && !ghost.empty() ? clock_.elapsed() : -1;
    }
    ghost_.assign(ghost);
  }
  display_.append(ghost);
  styles_.assign(display_.size(), prompt::Style::plain);
  // What was typed alone: the word at its end is still being typed, whatever the suggestion
  // after it would make of it.
  prompt::classify(std::string_view{display_}.substr(0, typed), std::span{styles_}.first(typed), shell::Syntax{.dialect = pane != nullptr && pane->shell.shell == IntegratedShell::fish ? shell::Dialect::fish : shell::Dialect::posix});
  std::fill_n(styles_.begin() + static_cast<std::ptrdiff_t>(cursor), composing.size(), prompt::Style::pending);
  std::fill(styles_.begin() + static_cast<std::ptrdiff_t>(typed), styles_.end(), prompt::Style::ghost);
  // A command the shell does not run is marked; one the runtime is still looking for waits.
  for (std::size_t start = 0; start < typed;) {
    if (styles_[start] != prompt::Style::command) {
      ++start;
      continue;
    }
    auto end = start;
    while (end < typed && styles_[end] == prompt::Style::command) {
      ++end;
    }
    const auto presence = application_->commandPresence(pane_id_, std::string_view{display_}.substr(start, end - start));
    if (presence == CommandPresence::missing || presence == CommandPresence::pending) {
      std::fill(styles_.begin() + static_cast<std::ptrdiff_t>(start), styles_.begin() + static_cast<std::ptrdiff_t>(end), presence == CommandPresence::missing ? prompt::Style::missing : prompt::Style::pending);
    }
    start = end;
  }
  groups_.assign(display_.size(), 0);
  if (composing.isEmpty()) {
    for (std::size_t index = 0; index < fresh_.size(); ++index) {
      const auto &fresh = fresh_[index];
      std::fill(groups_.begin() + static_cast<std::ptrdiff_t>(std::min(fresh.start, typed)), groups_.begin() + static_cast<std::ptrdiff_t>(std::min(fresh.end, typed)), static_cast<std::uint8_t>(index + 1));
    }
  }
  const auto shifted = [&](std::size_t offset) { return offset >= cursor ? offset + static_cast<std::size_t>(composing.size()) : offset; };
  const auto caret = shifted(cursor);
  const auto mark = shifted(anchor);
  const bool unchanged = reuse_layout && !cell_changed && !animating(clock_.elapsed()) && display_ == laid_.display && styles_ == laid_.styles && groups_ == laid_.groups && caret == laid_.caret && mark == laid_.anchor && maximum_columns_ == laid_.columns && maximum_rows_ == laid_.rows;
  if (unchanged) {
    if (previous_surface != surface_ || previous_failed != failed_ || previous_cursor_hidden != cursor_hidden_ || line != nullptr) {
      emit stateChanged();
    }
    return;
  }
  layout_ = prompt::layout(display_, styles_, caret, mark, static_cast<std::uint32_t>(maximum_columns_), groups_);
  laid_.display.assign(display_);
  laid_.styles.assign(styles_.begin(), styles_.end());
  laid_.groups.assign(groups_.begin(), groups_.end());
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

  placeRuns();
  if (animating(clock_.elapsed()) && ticker_.state() != QAbstractAnimation::Running) {
    ticker_.start();
  }
  ++revision_;
  emit layoutChanged();
  if (previous_surface != surface_ || previous_failed != failed_ || previous_cursor_hidden != cursor_hidden_ || line != nullptr) {
    emit stateChanged();
  }
  update();
}

// Each run is a cell text item, reused across edits: an item reshapes only when its own text
// changes, so typing at the end of a long command reshapes one run.
void PromptEditorItem::placeRuns() {
  const auto width = cellWidth();
  const auto height = cellHeight();
  const auto last_row = first_row_ + maximum_rows_;
  std::size_t used = 0;
  const auto now = clock_.elapsed();
  const auto place = [&](QString text, std::uint32_t row, std::uint32_t column, const QColor &color, qreal lift = 0, qreal opacity = 1) {
    if (used == runs_.size()) {
      auto *item = new NativeCellText(this);
      runs_.push_back(item);
    }
    auto *item = runs_[used++];
    item->setGrid(grid_);
    item->setText(text);
    item->setColor(color);
    item->setPosition({column * width, (static_cast<int>(row) - first_row_) * height + lift});
    item->setOpacity(opacity);
    item->setVisible(true);
  };
  static const QEasingCurve rise_curve{QEasingCurve::OutCubic};
  static const QEasingCurve sweep_curve{QEasingCurve::OutQuad};
  const auto accent = accent_;
  const auto mix = [](const QColor &from, const QColor &to, qreal amount) {
    return QColor::fromRgbF(static_cast<float>(from.redF() + (to.redF() - from.redF()) * amount), static_cast<float>(from.greenF() + (to.greenF() - from.greenF()) * amount), static_cast<float>(from.blueF() + (to.blueF() - from.blueF()) * amount), static_cast<float>(from.alphaF() + (to.alphaF() - from.alphaF()) * amount));
  };

  QVariantList glows;
  for (const auto &run : layout_.runs) {
    if (static_cast<int>(run.row) >= first_row_ && static_cast<int>(run.row) < last_row) {
      const auto text = QString::fromUtf8(display_.data() + run.start, static_cast<qsizetype>(run.end - run.start));
      auto color = styleColor(run.style);
      qreal lift = 0;
      qreal opacity = 1;
      if (run.group != 0 && run.group <= fresh_.size()) {
        const auto &fresh = fresh_[run.group - 1];
        const auto elapsed = static_cast<qreal>(now - fresh.started_ms);
        if (fresh.motion == Motion::rise) {
          const auto progress = rise_curve.valueForProgress(std::clamp(elapsed / rise_ms, 0.0, 1.0));
          lift = (1 - progress) * height * 0.15;
          opacity = progress;
        } else {
          const auto progress = sweep_curve.valueForProgress(std::clamp(elapsed / sweep_ms, 0.0, 1.0));
          color = mix(accent, color, progress);
          if (progress < 1) {
            glows.push_back(QVariantMap{{QStringLiteral("x"), run.column * width}, {QStringLiteral("y"), (static_cast<int>(run.row) - first_row_) * height}, {QStringLiteral("width"), run.columns * width}, {QStringLiteral("height"), height}, {QStringLiteral("strength"), 1 - progress}});
          }
        }
      } else if (run.style == prompt::Style::ghost && ghost_started_ms_ >= 0) {
        opacity = std::clamp(static_cast<qreal>(now - ghost_started_ms_) / ghost_ms, 0.0, 1.0);
      }
      place(text, run.row, run.column, color, lift, opacity);
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

QColor PromptEditorItem::styleColor(prompt::Style style) const {
  return style_colors_[static_cast<std::size_t>(style)];
}

void PromptEditorItem::cacheColors() {
  for (std::size_t index = 0; index < style_colors_.size(); ++index) {
    style_colors_[index] = roleColor(static_cast<prompt::Style>(index));
  }
  accent_ = colors_.value(QStringLiteral("accent")).value<QColor>();
  underline_ = colors_.value(QStringLiteral("overlay1")).value<QColor>();
}

QColor PromptEditorItem::roleColor(prompt::Style style) const {
  const auto role = [&](const char *name, const char *fallback) {
    const auto value = colors_.value(QString::fromLatin1(name));
    return value.isValid() ? value.value<QColor>() : colors_.value(QString::fromLatin1(fallback)).value<QColor>();
  };
  // Shell syntax takes the theme's syntax roles, so the prompt reads like the shell in the
  // editor; pending, error, missing and ghost text are editor states in chrome colors.
  switch (style) {
  case prompt::Style::command:
    return role("syntax_func", "foreground");
  case prompt::Style::option:
  case prompt::Style::variable:
    return role("syntax_parameter", "foreground");
  case prompt::Style::string:
    return role("syntax_string", "foreground");
  case prompt::Style::operator_:
    return role("syntax_operator", "muted");
  case prompt::Style::keyword:
    return role("syntax_keyword", "accent");
  case prompt::Style::comment:
    return role("syntax_comment", "muted");
  case prompt::Style::pending:
    return role("subtext0", "muted");
  case prompt::Style::error:
  case prompt::Style::missing:
    return role("red", "failure");
  case prompt::Style::ghost: {
    auto color = role("overlay1", "muted");
    color.setAlphaF(color.alphaF() * 0.7F);
    return color;
  }
  case prompt::Style::path:
  case prompt::Style::plain:
    break;
  }
  return role("text", "foreground");
}

// Follows what the editor holds: text inserted at one place animates in, text removed
// cancels what animated there, and the rest moves with the edit.
void PromptEditorItem::track(std::string_view text, bool animate) {
  const std::string_view previous{typed_};
  const auto now = clock_.elapsed();
  std::erase_if(fresh_, [&](const Fresh &fresh) { return now - fresh.started_ms >= (fresh.motion == Motion::rise ? rise_ms : sweep_ms); });
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
  const auto continuation = [](char byte) { return (static_cast<unsigned char>(byte) & 0xc0) == 0x80; };
  while (prefix > 0 && prefix < text.size() && continuation(text[prefix])) {
    --prefix;
  }
  while (suffix > 0 && continuation(text[text.size() - suffix])) {
    --suffix;
  }
  const auto removed = previous.size() - prefix - suffix;
  const auto inserted = text.size() - prefix - suffix;
  typed_.assign(text);

  std::erase_if(fresh_, [&](const Fresh &fresh) { return fresh.end > prefix && fresh.start < prefix + std::max<std::size_t>(removed, 1); });
  for (auto &fresh : fresh_) {
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

  const auto added = text.substr(prefix, inserted);
  std::size_t characters = 0;
  for (const auto byte : added) {
    characters += !continuation(byte);
  }
  if (characters == 1) {
    fresh_.push_back({.start = prefix, .end = prefix + inserted, .motion = Motion::rise, .started_ms = now});
    return;
  }
  // A completion or a suggestion taken: each character sweeps in after the one before.
  std::size_t start = prefix;
  qint64 delay = 0;
  for (std::size_t offset = 1; offset <= added.size() && fresh_.size() < maximum_fresh; ++offset) {
    if (offset < added.size() && continuation(added[offset])) {
      continue;
    }
    fresh_.push_back({.start = start, .end = prefix + offset, .motion = Motion::sweep, .started_ms = now + delay});
    start = prefix + offset;
    delay += sweep_step_ms;
  }
}

bool PromptEditorItem::animating(qint64 now) const noexcept {
  if (ghost_started_ms_ >= 0 && now - ghost_started_ms_ < ghost_ms) {
    return true;
  }
  return std::ranges::any_of(fresh_, [&](const Fresh &fresh) { return now - fresh.started_ms < (fresh.motion == Motion::rise ? rise_ms : sweep_ms); });
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

// Hands out the children of `parent` in order, creating one when it runs out, and deletes those
// left over once dropped: a paint node keeps its nodes from one update to the next.
class ChildNodes {
public:
  explicit ChildNodes(QSGNode &parent) noexcept : parent_(parent), next_(parent.firstChild()) {}

  ~ChildNodes() {
    while (next_ != nullptr) {
      auto *child = next_;
      next_ = child->nextSibling();
      parent_.removeChildNode(child);
      delete child;
    }
  }

  ChildNodes(const ChildNodes &) = delete;
  ChildNodes &operator=(const ChildNodes &) = delete;

  template <typename Node, typename Create>
  Node &take(Create &&create) {
    if (next_ != nullptr) {
      auto *child = static_cast<Node *>(next_);
      next_ = next_->nextSibling();
      return *child;
    }
    auto *child = create();
    parent_.appendChildNode(child);
    return *child;
  }

private:
  QSGNode &parent_;
  QSGNode *next_;
};

}

// The root holds two groups, the selection's rectangles and the underlines' lines, so each
// group's nodes are of one type and are reused in place.
QSGNode *PromptEditorItem::updatePaintNode(QSGNode *previous, [[maybe_unused]] UpdatePaintNodeData *data) {
  auto *root = previous != nullptr ? previous : new QSGNode;
  if (root->childCount() != 2) {
    while (auto *child = root->firstChild()) {
      root->removeChildNode(child);
      delete child;
    }
    root->appendChildNode(new QSGNode);
    root->appendChildNode(new QSGNode);
  }
  ChildNodes selections{*root->firstChild()};
  ChildNodes underlines{*root->lastChild()};
  if (window() == nullptr || resolved_.metrics.width <= 0) {
    return root;
  }

  const auto width = cellWidth();
  const auto height = cellHeight();
  const auto last_row = first_row_ + maximum_rows_;
  const auto visible = [&](std::uint32_t row) { return static_cast<int>(row) >= first_row_ && static_cast<int>(row) < last_row; };

  auto selection = accent_;
  selection.setAlphaF(0.28F);
  for (const auto &range : layout_.selection) {
    if (!visible(range.row)) {
      continue;
    }
    auto &rectangle = selections.take<QSGRectangleNode>([&] { return window()->createRectangleNode(); });
    rectangle.setRect(range.column * width, (static_cast<int>(range.row) - first_row_) * height, range.columns * width, height);
    rectangle.setColor(selection);
  }

  // A command the shell does not run gets a wavy underline; a path, a dotted one.
  const auto pixel = 1.0 / scale_;
  for (const auto &run : layout_.runs) {
    if ((run.style != prompt::Style::missing && run.style != prompt::Style::path) || !visible(run.row)) {
      continue;
    }
    const bool wavy = run.style == prompt::Style::missing;
    const auto left = run.column * width;
    const auto right = (run.column + run.columns) * width;
    const auto baseline = (static_cast<int>(run.row) - first_row_ + 1) * height - 2 * pixel;
    const auto step = wavy ? width / 4 : 3 * pixel;
    const auto points = static_cast<int>(std::ceil((right - left) / step)) + 1;
    auto &node = underlines.take<QSGGeometryNode>([] {
      auto *created = new QSGGeometryNode;
      auto *geometry = new QSGGeometry(QSGGeometry::defaultAttributes_Point2D(), 0);
      geometry->setLineWidth(1);
      created->setGeometry(geometry);
      created->setMaterial(new QSGFlatColorMaterial);
      created->setFlags(QSGNode::OwnsGeometry | QSGNode::OwnsMaterial);
      return created;
    });
    auto *geometry = node.geometry();
    geometry->allocate(wavy ? points : (points / 2) * 2);
    geometry->setDrawingMode(wavy ? QSGGeometry::DrawLineStrip : QSGGeometry::DrawLines);
    auto *vertices = geometry->vertexDataAsPoint2D();
    for (int index = 0; index < geometry->vertexCount(); ++index) {
      const auto x = std::min(right, left + index * step);
      const auto y = wavy ? baseline + (index % 2 == 0 ? -pixel : pixel) : baseline;
      vertices[index].set(static_cast<float>(x), static_cast<float>(y));
    }
    auto color = wavy ? styleColor(run.style) : underline_;
    color.setAlphaF(wavy ? 0.8F : 0.7F);
    static_cast<QSGFlatColorMaterial *>(node.material())->setColor(color);
    node.markDirty(QSGNode::DirtyGeometry | QSGNode::DirtyMaterial);
  }

  return root;
}

}
