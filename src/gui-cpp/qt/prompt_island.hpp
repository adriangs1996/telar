#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>
#include <QColor>
#include <QElapsedTimer>
#include <QPointer>
#include <QQuickItem>
#include <QRectF>
#include <QString>
#include <QVariantList>
#include <QVariantAnimation>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include "cell_text_grid.hpp"
#include "ancestor_geometry.hpp"

import telar.gui.prompt.layout;

namespace telar::gui::qt {

class Application;
class NativeCellText;

// telar's command editor as the island draws it: the command in the terminal's font, coloured
// by how the shell reads it and wrapped at the island's width. It holds no state of its own;
// the session owns the editor, and this item paints it and publishes what QML needs to shape
// the island around it.
class PromptIsland : public QQuickItem {
  Q_OBJECT
  QML_NAMED_ELEMENT(NativePromptEditor)
  Q_PROPERTY(QObject *application READ application WRITE setApplication NOTIFY applicationChanged)
  Q_PROPERTY(QString paneId READ paneId WRITE setPaneId NOTIFY paneIdChanged)
  Q_PROPERTY(QVariantMap grid READ grid WRITE setGrid NOTIFY gridChanged)
  Q_PROPERTY(QVariantMap colors READ colors WRITE setColors NOTIFY colorsChanged)
  Q_PROPERTY(int maximumColumns READ maximumColumns WRITE setMaximumColumns NOTIFY maximumColumnsChanged)
  Q_PROPERTY(QString preedit READ preedit WRITE setPreedit NOTIFY preeditChanged)
  Q_PROPERTY(QString surface READ surface NOTIFY stateChanged)
  // emacs, or vim's insert, normal, visual or visual-line.
  Q_PROPERTY(QString mode READ mode NOTIFY stateChanged)
  // A suggestion from the history shows after the caret, for a key to take it.
  Q_PROPERTY(bool suggesting READ suggesting NOTIFY stateChanged)
  // The command block selected from the editor (its position, from 1, or 0) and how many there
  // are; and copy mode on this pane: "" when off, else "copy", "visual" or "visual-line".
  Q_PROPERTY(int block READ block NOTIFY stateChanged)
  Q_PROPERTY(int blocks READ blocks NOTIFY stateChanged)
  Q_PROPERTY(QString copying READ copying NOTIFY stateChanged)
  Q_PROPERTY(bool queued READ queued NOTIFY stateChanged)
  Q_PROPERTY(bool answering READ answering NOTIFY stateChanged)
  Q_PROPERTY(int secretKeys READ secretKeys NOTIFY stateChanged)
  Q_PROPERTY(bool failed READ failed NOTIFY stateChanged)
  Q_PROPERTY(bool empty READ empty NOTIFY stateChanged)
  Q_PROPERTY(QString lastCommand READ lastCommand NOTIFY stateChanged)
  // Counts the commands the editor sent to run: each one flies to its separator.
  Q_PROPERTY(int launches READ launches NOTIFY stateChanged)
  // Where the next command runs, for the island to announce when it changes.
  Q_PROPERTY(QString directory READ directory NOTIFY stateChanged)
  Q_PROPERTY(QString branch READ branch NOTIFY stateChanged)
  // The running program's progress (OSC 9;4): 0 to 100, -1 without one, -2 when indeterminate.
  Q_PROPERTY(int progress READ progress NOTIFY stateChanged)
  // Commands the shell finished and the last one's exit status, for the island's outcome.
  Q_PROPERTY(int commands READ commands NOTIFY stateChanged)
  Q_PROPERTY(int status READ status NOTIFY stateChanged)
  // client.prompt.skin and client.prompt.motion.
  Q_PROPERTY(QString skin READ skin NOTIFY stateChanged)
  Q_PROPERTY(QString motion READ motion NOTIFY stateChanged)
  // The completion menu: at most a page of choices around the selected one.
  Q_PROPERTY(QVariantList choices READ choices NOTIFY stateChanged)
  Q_PROPERTY(int choice READ choice NOTIFY stateChanged)
  Q_PROPERTY(QString menuLabel READ menuLabel NOTIFY stateChanged)
  // A shell `ssh` reached: its host, and how long the last command took to reach it in ms.
  Q_PROPERTY(bool remote READ remote NOTIFY stateChanged)
  Q_PROPERTY(QString host READ host NOTIFY stateChanged)
  Q_PROPERTY(int link READ link NOTIFY stateChanged)
  // The key that interrupts the running program, as the terminal's line discipline sets it.
  Q_PROPERTY(QString interruptKey READ interruptKey NOTIFY stateChanged)
  // The program in the foreground, which a secret is typed for.
  Q_PROPERTY(QString program READ program NOTIFY stateChanged)
  // The last command that ended: its first line, status, duration in ms and how it ended.
  Q_PROPERTY(QVariantMap lastBlock READ lastBlock NOTIFY stateChanged)
  Q_PROPERTY(int rows READ rows NOTIFY layoutChanged)
  Q_PROPERTY(int visibleRows READ visibleRows NOTIFY layoutChanged)
  Q_PROPERTY(int columns READ columns NOTIFY layoutChanged)
  Q_PROPERTY(QRectF caret READ caret NOTIFY layoutChanged)
  // Where text sweeping in glows, in this item's coordinates, and how strongly: {x, y,
  // width, height, strength}. Empty unless a completion is sweeping in.
  Q_PROPERTY(QVariantList glows READ glows NOTIFY glowsChanged)
  Q_PROPERTY(qreal cellWidth READ cellWidth NOTIFY metricsChanged)
  Q_PROPERTY(qreal cellHeight READ cellHeight NOTIFY metricsChanged)

public:
  explicit PromptIsland(QQuickItem *parent = nullptr);
  ~PromptIsland() override;

  [[nodiscard]] QObject *application() const noexcept;
  void setApplication(QObject *application);
  [[nodiscard]] QString paneId() const;
  void setPaneId(const QString &identity);
  [[nodiscard]] QVariantMap grid() const;
  void setGrid(const QVariantMap &grid);
  [[nodiscard]] QVariantMap colors() const;
  void setColors(const QVariantMap &colors);
  [[nodiscard]] int maximumColumns() const noexcept;
  void setMaximumColumns(int columns);
  [[nodiscard]] QString preedit() const;
  void setPreedit(const QString &preedit);

  [[nodiscard]] QString surface() const;
  [[nodiscard]] QString mode() const;
  [[nodiscard]] bool suggesting() const noexcept;
  [[nodiscard]] int block() const noexcept;
  [[nodiscard]] int blocks() const noexcept;
  [[nodiscard]] QString copying() const;
  [[nodiscard]] bool queued() const noexcept;
  [[nodiscard]] bool answering() const noexcept;
  [[nodiscard]] int secretKeys() const noexcept;
  [[nodiscard]] bool failed() const noexcept;
  [[nodiscard]] bool empty() const noexcept;
  [[nodiscard]] QString lastCommand() const;
  [[nodiscard]] int launches() const noexcept;
  [[nodiscard]] QString directory() const;
  [[nodiscard]] QString branch() const;
  [[nodiscard]] int progress() const noexcept;
  [[nodiscard]] int commands() const noexcept;
  [[nodiscard]] int status() const noexcept;
  [[nodiscard]] QString skin() const;
  [[nodiscard]] QString motion() const;
  [[nodiscard]] QVariantList choices() const;
  [[nodiscard]] int choice() const noexcept;
  [[nodiscard]] QString menuLabel() const;
  [[nodiscard]] bool remote() const noexcept;
  [[nodiscard]] QString host() const;
  [[nodiscard]] int link() const noexcept;
  [[nodiscard]] QString interruptKey() const;
  [[nodiscard]] QString program() const;
  [[nodiscard]] QVariantMap lastBlock() const;
  // The last line the running program printed, from the rows on screen.
  Q_INVOKABLE QString outputLine() const;
  // Scrolls the pane to the last command that failed.
  Q_INVOKABLE void viewFailure();
  [[nodiscard]] int rows() const noexcept;
  [[nodiscard]] int visibleRows() const noexcept;
  [[nodiscard]] int columns() const noexcept;
  [[nodiscard]] QRectF caret() const noexcept;
  [[nodiscard]] QVariantList glows() const;
  [[nodiscard]] qreal cellWidth() const noexcept;
  [[nodiscard]] qreal cellHeight() const noexcept;

signals:
  void applicationChanged();
  void paneIdChanged();
  void gridChanged();
  void colorsChanged();
  void maximumColumnsChanged();
  void preeditChanged();
  void stateChanged();
  void layoutChanged();
  void metricsChanged();
  void glowsChanged();

protected:
  void itemChange(ItemChange change, const ItemChangeData &data) override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  QSGNode *updatePaintNode(QSGNode *previous, UpdatePaintNodeData *data) override;

private:
  // Text that just arrived: a typed character rises into place, a completion sweeps in from
  // the accent colour, one character after another.
  enum class Motion : std::uint8_t {
    rise,
    sweep,
  };

  struct Fresh {
    std::size_t start = 0;
    std::size_t end = 0;
    Motion motion = Motion::rise;
    qint64 started_ms = 0;
  };

  void refresh();
  void placeRuns();
  void track(std::string_view text, bool animate);
  void tick();
  [[nodiscard]] bool animating(qint64 now) const noexcept;
  [[nodiscard]] QColor styleColor(prompt::Style style) const;

  // Glyphs snap to the scene's pixels, so moving any ancestor repaints them.
  AncestorGeometry ancestors_;
  QPointer<Application> application_;
  CellTextGrid resolved_;
  std::vector<NativeCellText *> runs_;
  QVariantMap grid_;
  QVariantMap colors_;
  QString preedit_;
  std::string display_;
  std::string typed_;
  std::string ghost_;
  std::vector<prompt::Style> styles_;
  std::vector<std::uint8_t> groups_;
  std::vector<Fresh> fresh_;
  QVariantList glows_;
  qint64 ghost_started_ms_ = -1;
  QElapsedTimer clock_;
  // Drives frames while text animates, in step with the window's animations.
  QVariantAnimation ticker_;
  prompt::Layout layout_;
  std::uint64_t pane_id_ = 0;
  std::uint64_t revision_ = 0;
  qreal scale_ = 1;
  int maximum_columns_ = 80;
  int maximum_rows_ = 12;
  int first_row_ = 0;
  std::uint8_t surface_ = 0;
  bool failed_ = false;
};

}
