#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "prompt_island.hpp"
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

PromptIsland::PromptIsland(QQuickItem *parent)
    : QQuickItem(parent),
      ancestors_(*this) {
  setFlag(ItemHasContents);
  clock_.start();
  ticker_.setStartValue(0.0);
  ticker_.setEndValue(1.0);
  ticker_.setDuration(1000);
  ticker_.setLoopCount(-1);
  connect(&ticker_, &QVariantAnimation::valueChanged, this, &PromptIsland::tick);
}

PromptIsland::~PromptIsland() = default;

QObject *PromptIsland::application() const noexcept {
  return application_;
}

void PromptIsland::setApplication(QObject *application) {
  auto *next = qobject_cast<Application *>(application);
  if (application_ == next) {
    return;
  }
  if (application_ != nullptr) {
    disconnect(application_, nullptr, this, nullptr);
  }
  application_ = next;
  if (application_ != nullptr) {
    const auto pane = [this](qulonglong pane_id) {
      if (pane_id == pane_id_) {
        refresh();
      }
    };
    connect(application_, &Application::promptChanged, this, pane);
    connect(application_, &Application::terminalChanged, this, pane);
    connect(application_, &Application::configurationChanged, this, &PromptIsland::refresh);
  }
  refresh();
  emit applicationChanged();
}

QString PromptIsland::paneId() const {
  return QString::number(pane_id_);
}

void PromptIsland::setPaneId(const QString &identity) {
  const auto next = identity.toULongLong();
  if (pane_id_ != next) {
    pane_id_ = next;
    first_row_ = 0;
    refresh();
    emit paneIdChanged();
  }
}

QVariantMap PromptIsland::grid() const {
  return grid_;
}

void PromptIsland::setGrid(const QVariantMap &grid) {
  if (grid_ != grid) {
    grid_ = grid;
    refresh();
    emit gridChanged();
  }
}

QVariantMap PromptIsland::colors() const {
  return colors_;
}

void PromptIsland::setColors(const QVariantMap &colors) {
  if (colors_ != colors) {
    colors_ = colors;
    placeRuns();
    update();
    emit colorsChanged();
  }
}

int PromptIsland::maximumColumns() const noexcept {
  return maximum_columns_;
}

void PromptIsland::setMaximumColumns(int columns) {
  columns = std::max(columns, static_cast<int>(prompt::Layout::indent) + 4);
  if (maximum_columns_ != columns) {
    maximum_columns_ = columns;
    refresh();
    emit maximumColumnsChanged();
  }
}

QString PromptIsland::preedit() const {
  return preedit_;
}

void PromptIsland::setPreedit(const QString &preedit) {
  if (preedit_ != preedit) {
    preedit_ = preedit;
    refresh();
    emit preeditChanged();
  }
}

QString PromptIsland::surface() const {
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

QString PromptIsland::mode() const {
  const auto *island = application_ == nullptr ? nullptr : application_->promptIsland(pane_id_);
  if (island == nullptr || island->editor().keymap() == prompt::Keymap::emacs) {
    return QStringLiteral("emacs");
  }
  switch (island->editor().mode()) {
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

bool PromptIsland::suggesting() const noexcept {
  return !ghost_.empty();
}

int PromptIsland::block() const noexcept {
  const auto selected = application_ == nullptr ? std::nullopt : application_->selectedBlock(pane_id_);
  return selected ? static_cast<int>(*selected) + 1 : 0;
}

int PromptIsland::blocks() const noexcept {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  return pane == nullptr ? 0 : static_cast<int>(pane->blocks.size());
}

QString PromptIsland::copying() const {
  const auto *copy = application_ == nullptr ? nullptr : &application_->copyState();
  if (copy == nullptr || !*copy || (*copy)->pointer || (*copy)->pane_id != pane_id_) {
    return {};
  }
  if (!(*copy)->anchor) {
    return QStringLiteral("copy");
  }
  return (*copy)->linewise ? QStringLiteral("visual-line") : QStringLiteral("visual");
}

bool PromptIsland::queued() const noexcept {
  const auto *island = application_ == nullptr ? nullptr : application_->promptIsland(pane_id_);
  return island != nullptr && island->queued();
}

bool PromptIsland::answering() const noexcept {
  const auto *island = application_ == nullptr ? nullptr : application_->promptIsland(pane_id_);
  return island != nullptr && island->answering();
}

int PromptIsland::secretKeys() const noexcept {
  const auto *island = application_ == nullptr ? nullptr : application_->promptIsland(pane_id_);
  return island == nullptr ? 0 : static_cast<int>(std::min<std::uint32_t>(island->secretKeys(), 64));
}

bool PromptIsland::failed() const noexcept {
  return failed_;
}

bool PromptIsland::empty() const noexcept {
  return display_.empty();
}

QString PromptIsland::lastCommand() const {
  const auto *island = application_ == nullptr ? nullptr : application_->promptIsland(pane_id_);
  if (island == nullptr || island->recent().empty()) {
    return {};
  }
  const auto &command = island->recent().back();
  const auto line = std::string_view{command}.substr(0, command.find('\n'));
  return QString::fromUtf8(line.data(), static_cast<qsizetype>(line.size()));
}

int PromptIsland::launches() const noexcept {
  const auto *island = application_ == nullptr ? nullptr : application_->promptIsland(pane_id_);
  return island == nullptr ? 0 : static_cast<int>(island->launches() & 0x7fffffff);
}

static constexpr int menu_page = 8;

// The page of the menu that holds the selected choice.
static std::pair<std::size_t, std::size_t> menuPage(const prompt::Menu &menu) {
  const auto first = menu.selected / menu_page * menu_page;
  return {first, std::min(menu.choices.size(), first + menu_page)};
}

QVariantList PromptIsland::choices() const {
  QVariantList result;
  const auto *island = application_ == nullptr ? nullptr : application_->promptIsland(pane_id_);
  if (island == nullptr || !island->menu()) {
    return result;
  }
  const auto &menu = *island->menu();
  const auto [first, last] = menuPage(menu);
  // The letters of each choice that what was typed matches, in order, for the menu to mark.
  const auto text = island->editor().text().view();
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
  return result;
}

int PromptIsland::choice() const noexcept {
  const auto *island = application_ == nullptr ? nullptr : application_->promptIsland(pane_id_);
  if (island == nullptr || !island->menu()) {
    return -1;
  }
  return static_cast<int>(island->menu()->selected - menuPage(*island->menu()).first);
}

QString PromptIsland::menuLabel() const {
  const auto *island = application_ == nullptr ? nullptr : application_->promptIsland(pane_id_);
  if (island == nullptr || !island->menu()) {
    return {};
  }
  const auto &label = island->menu()->label;
  return QString::fromUtf8(label.data(), static_cast<qsizetype>(label.size()));
}

bool PromptIsland::remote() const noexcept {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  return pane != nullptr && pane->shell.remote;
}

QString PromptIsland::host() const {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  if (pane == nullptr || !pane->shell.remote) {
    return {};
  }
  return QString::fromUtf8(pane->shell.host.data(), static_cast<qsizetype>(pane->shell.host.size()));
}

int PromptIsland::link() const noexcept {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  return pane == nullptr ? 0 : static_cast<int>(pane->shell.link_ms);
}

QString PromptIsland::interruptKey() const {
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

QString PromptIsland::program() const {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  return pane == nullptr ? QString{} : QString::fromUtf8(pane->foreground.data(), static_cast<qsizetype>(pane->foreground.size()));
}

QVariantMap PromptIsland::lastBlock() const {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  if (pane == nullptr || pane->blocks.empty() || pane->blocks.back().state == CommandBlockState::running || pane->blocks.back().state == CommandBlockState::session) {
    return {};
  }
  const auto &block = pane->blocks.back();
  return QVariantMap{
      {QStringLiteral("command"), QString::fromUtf8(block.command.data(), static_cast<qsizetype>(block.command.size()))},
      {QStringLiteral("status"), block.status},
      {QStringLiteral("duration"), static_cast<qulonglong>(block.duration_ms)},
      {QStringLiteral("failed"), block.state == CommandBlockState::failed},
      {QStringLiteral("count"), static_cast<int>(pane->blocks.size())},
  };
}

QString PromptIsland::outputLine() const {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  if (pane == nullptr) {
    return {};
  }
  const auto &screen = pane->screen;
  // The nearest row above the cursor with any text: the cursor's own row is usually empty.
  for (auto row = std::min<std::size_t>(screen.cursor().y + 1, screen.rows()); row-- > 0;) {
    std::string line;
    for (const auto &cell : screen.row(row)) {
      if (cell.width != CellWidth::continuation) {
        line.append(cell.utf8());
      }
    }
    const auto last = line.find_last_not_of(' ');
    if (last != std::string::npos) {
      const auto first = line.find_first_not_of(' ');
      return QString::fromUtf8(line.data() + first, static_cast<qsizetype>(last + 1 - first));
    }
  }
  return {};
}

void PromptIsland::viewFailure() {
  auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  if (pane == nullptr) {
    return;
  }
  const auto failed = std::ranges::find_if(pane->blocks.rbegin(), pane->blocks.rend(), [](const CommandBlock &block) { return block.state == CommandBlockState::failed; });
  if (failed != pane->blocks.rend()) {
    application_->selectBlock(pane_id_, static_cast<std::size_t>(std::distance(failed, pane->blocks.rend()) - 1));
  }
}

QString PromptIsland::directory() const {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  if (pane == nullptr) {
    return {};
  }
  // A remote shell works on its host: this one's directory, ssh's, would mislead.
  const auto cwd = pane->shell.remote ? pane->shell.directory : std::string_view{pane->cwd};
  return QString::fromUtf8(cwd.data(), static_cast<qsizetype>(cwd.size()));
}

QString PromptIsland::branch() const {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  if (pane == nullptr || !pane->git.repository) {
    return {};
  }
  return QString::fromUtf8(pane->git.branch.data(), static_cast<qsizetype>(pane->git.branch.size()));
}

int PromptIsland::progress() const noexcept {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  if (pane == nullptr || pane->progress_state == PaneProgressState::remove) {
    return -1;
  }
  if (pane->progress_state == PaneProgressState::indeterminate || !pane->progress_percent) {
    return -2;
  }
  return std::min<int>(100, *pane->progress_percent);
}

int PromptIsland::commands() const noexcept {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  return pane == nullptr ? 0 : static_cast<int>(pane->shell.commands);
}

int PromptIsland::status() const noexcept {
  const auto *pane = application_ == nullptr ? nullptr : application_->pane(pane_id_);
  return pane == nullptr ? 0 : pane->shell.status;
}

QString PromptIsland::motion() const {
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

int PromptIsland::rows() const noexcept {
  return static_cast<int>(layout_.rows);
}

int PromptIsland::visibleRows() const noexcept {
  return std::min(static_cast<int>(layout_.rows), maximum_rows_);
}

int PromptIsland::columns() const noexcept {
  return static_cast<int>(layout_.width);
}

QVariantList PromptIsland::glows() const {
  return glows_;
}

qreal PromptIsland::cellWidth() const noexcept {
  return resolved_.metrics.width / scale_;
}

qreal PromptIsland::cellHeight() const noexcept {
  return resolved_.metrics.height / scale_;
}

QRectF PromptIsland::caret() const noexcept {
  const auto width = cellWidth();
  const auto height = cellHeight();
  return {layout_.caret_column * width, (static_cast<int>(layout_.caret_row) - first_row_) * height, layout_.caret_columns * width, height};
}

void PromptIsland::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  update();
}

void PromptIsland::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemParentHasChanged) {
    ancestors_.observe();
  }
  if (change == ItemSceneChange || change == ItemDevicePixelRatioHasChanged) {
    refresh();
  }
}

// Rebuilds the layout from the session's editor: the command with any composition at the caret,
// coloured, wrapped at the island's width, scrolled so the caret stays in view.
void PromptIsland::refresh() {
  const auto previous_surface = surface_;
  const auto previous_failed = failed_;
  if (application_ == nullptr || window() == nullptr || pane_id_ == 0) {
    surface_ = 0;
    if (previous_surface != surface_) {
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
  if (previous_cell != QSizeF{cellWidth(), cellHeight()}) {
    emit metricsChanged();
  }

  surface_ = static_cast<std::uint8_t>(application_->promptSurface(pane_id_));
  const auto *pane = application_->pane(pane_id_);
  failed_ = pane != nullptr && pane->shell.commands != 0 && pane->shell.status != 0;
  maximum_rows_ = std::max<int>(1, application_->configuration().prompt.max_lines);

  const auto *island = application_->promptIsland(pane_id_);
  const auto text = island == nullptr ? std::string_view{} : island->editor().text().view();
  const auto cursor = island == nullptr ? 0 : island->editor().text().cursor();
  const auto anchor = island == nullptr ? 0 : island->editor().text().anchor();
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
  layout_ = prompt::layout(display_, styles_, shifted(cursor), shifted(anchor), static_cast<std::uint32_t>(maximum_columns_), groups_);

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
  if (previous_surface != surface_ || previous_failed != failed_ || island != nullptr) {
    emit stateChanged();
  }
  update();
}

// Each run is a cell text item, reused across edits: an item reshapes only when its own text
// changes, so typing at the end of a long command reshapes one run.
void PromptIsland::placeRuns() {
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
  const auto accent = colors_.value(QStringLiteral("accent")).value<QColor>();
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

QColor PromptIsland::styleColor(prompt::Style style) const {
  const auto role = [&](const char *name, const char *fallback) {
    const auto value = colors_.value(QString::fromLatin1(name));
    return value.isValid() ? value.value<QColor>() : colors_.value(QString::fromLatin1(fallback)).value<QColor>();
  };
  switch (style) {
  case prompt::Style::command:
    return role("green", "foreground");
  case prompt::Style::option:
    return role("blue", "foreground");
  case prompt::Style::string:
    return role("yellow", "foreground");
  case prompt::Style::variable:
    return role("mauve", "accent");
  case prompt::Style::operator_:
    return role("overlay1", "muted");
  case prompt::Style::keyword:
    return role("peach", "accent");
  case prompt::Style::comment:
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
void PromptIsland::track(std::string_view text, bool animate) {
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

bool PromptIsland::animating(qint64 now) const noexcept {
  if (ghost_started_ms_ >= 0 && now - ghost_started_ms_ < ghost_ms) {
    return true;
  }
  return std::ranges::any_of(fresh_, [&](const Fresh &fresh) { return now - fresh.started_ms < (fresh.motion == Motion::rise ? rise_ms : sweep_ms); });
}

// A frame of the animation: runs take their place for now, and the layout merges them back
// once nothing moves.
void PromptIsland::tick() {
  if (animating(clock_.elapsed())) {
    placeRuns();
    return;
  }
  ticker_.stop();
  ghost_started_ms_ = -1;
  fresh_.clear();
  refresh();
}

QSGNode *PromptIsland::updatePaintNode(QSGNode *previous, [[maybe_unused]] UpdatePaintNodeData *data) {
  auto *root = previous != nullptr ? previous : new QSGNode;
  while (auto *child = root->firstChild()) {
    root->removeChildNode(child);
    delete child;
  }
  if (window() == nullptr || resolved_.metrics.width <= 0) {
    return root;
  }

  const auto width = cellWidth();
  const auto height = cellHeight();
  const auto last_row = first_row_ + maximum_rows_;
  const auto visible = [&](std::uint32_t row) { return static_cast<int>(row) >= first_row_ && static_cast<int>(row) < last_row; };

  auto selection = colors_.value(QStringLiteral("accent")).value<QColor>();
  selection.setAlphaF(0.28F);
  for (const auto &range : layout_.selection) {
    if (!visible(range.row)) {
      continue;
    }
    auto *rectangle = window()->createRectangleNode();
    rectangle->setRect(range.column * width, (static_cast<int>(range.row) - first_row_) * height, range.columns * width, height);
    rectangle->setColor(selection);
    root->appendChildNode(rectangle);
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
    auto *geometry = new QSGGeometry(QSGGeometry::defaultAttributes_Point2D(), wavy ? points : (points / 2) * 2);
    geometry->setDrawingMode(wavy ? QSGGeometry::DrawLineStrip : QSGGeometry::DrawLines);
    geometry->setLineWidth(1);
    auto *vertices = geometry->vertexDataAsPoint2D();
    for (int index = 0; index < geometry->vertexCount(); ++index) {
      const auto x = std::min(right, left + index * step);
      const auto y = wavy ? baseline + (index % 2 == 0 ? -pixel : pixel) : baseline;
      vertices[index].set(static_cast<float>(x), static_cast<float>(y));
    }
    auto *material = new QSGFlatColorMaterial;
    auto color = wavy ? styleColor(run.style) : colors_.value(QStringLiteral("overlay1")).value<QColor>();
    color.setAlphaF(wavy ? 0.8F : 0.7F);
    material->setColor(color);
    auto *node = new QSGGeometryNode;
    node->setGeometry(geometry);
    node->setMaterial(material);
    node->setFlags(QSGNode::OwnsGeometry | QSGNode::OwnsMaterial);
    root->appendChildNode(node);
  }

  return root;
}

}
