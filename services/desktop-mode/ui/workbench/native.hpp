#pragma once

#include <QRectF>
#include <QVariantList>
#include <cstdint>
#include <memory>

class QWindow;

namespace workbench::native {
  struct Display {
    QRectF available;
    double scale = 1;
  };

  Display display(std::uint32_t identifier);
  void place(QWindow &window, std::uint64_t space);
  QVariantList windows();

  // An explicit adoption retains the AX identity, never merely a reusable window ID.
  class ExternalWindow final {
  public:
    explicit ExternalWindow(std::uint32_t identifier);
    ~ExternalWindow();
    bool alive() const;
    QRectF frame() const;
    QRectF place(const QRectF &requested);
    void show(bool visible);
    void focus();
    QString title() const;
    void setSpace(std::uint64_t space);
    bool geometryChanged() const;
    bool focused() const;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
  };
} // namespace workbench::native
