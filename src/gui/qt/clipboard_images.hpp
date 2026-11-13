#pragma once

#include "tbc/view.hpp"
#include "application/dependencies.hpp"
#include "attachment_preview.hpp"
#include "attachments/catalog.hpp"
#include "attachments/types.hpp"
#include "machine_client_key.hpp"
#include "platform/clipboard_image_source.hpp"
#include "platform/clipboard_image_monitor.hpp"
#include <QFutureWatcher>
#include <QObject>
#include <QString>
#include <QThreadPool>
#include <cstdint>
#include <optional>

namespace telar::gui::qt {

struct ClipboardImageJob {
  MachineClientKey source;
  std::uint64_t runtime_generation = 0;
  std::uint64_t attachment_generation = 0;
  ClipboardCaptureRequest request;
};

struct ClipboardImageResult {
  ClipboardImageJob job;
  std::optional<AttachmentCapture<ApplicationAllocator>> capture = std::nullopt;
  std::optional<AttachmentPreview> preview = std::nullopt;
  std::optional<platform::ClipboardImageError> failure = std::nullopt;
  QString error = {};
};

class ClipboardImages final : public QObject {
  Q_OBJECT

public:
  // The captures allocate from memory, region `a`.
  explicit ClipboardImages(tbc::view<ApplicationAllocator &, tbc::lt::a> memory, QObject *parent = nullptr);
  ~ClipboardImages() override;
  ClipboardImages(const ClipboardImages &) = delete;
  ClipboardImages &operator=(const ClipboardImages &) = delete;
  ClipboardImages(ClipboardImages &&) = delete;
  ClipboardImages &operator=(ClipboardImages &&) = delete;

  void capture(ClipboardImageJob job);
  [[nodiscard]] tbc::view<std::optional<ClipboardImageResult>, tbc::lt::a> takeResult();
  [[nodiscard]] bool busy() const noexcept;

signals:
  void ready();
  void queued();

private:
  // The prepared images are allocated from memory.
  [[nodiscard]] static tbc::view<ClipboardImageResult, tbc::lt::a> prepare(tbc::view<ApplicationAllocator &, tbc::lt::a> memory, ClipboardImageJob job, platform::ClipboardImageSource source);
  void start(ClipboardImageJob job);
  void complete();
  void drain();
  void startQueued();

  tbc::view<ApplicationAllocator &, tbc::lt::a> memory_;
  tbc::view<platform::ClipboardImageMonitor, tbc::lt::a> clipboard_;
  QThreadPool worker_pool_;
  QFutureWatcher<ClipboardImageResult> task_;
  std::optional<ClipboardImageJob> running_;
  std::optional<ClipboardImageJob> queued_;
  tbc::view<std::optional<ClipboardImageResult>, tbc::lt::a> result_;
  bool busy_ = false;
};

}
