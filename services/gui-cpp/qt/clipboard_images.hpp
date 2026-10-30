#pragma once

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
  explicit ClipboardImages(ApplicationAllocator &memory, QObject *parent = nullptr);
  ~ClipboardImages() override;
  ClipboardImages(const ClipboardImages &) = delete;
  ClipboardImages &operator=(const ClipboardImages &) = delete;
  ClipboardImages(ClipboardImages &&) = delete;
  ClipboardImages &operator=(ClipboardImages &&) = delete;

  void capture(ClipboardImageJob job);
  [[nodiscard]] std::optional<ClipboardImageResult> takeResult();
  [[nodiscard]] bool busy() const noexcept;

signals:
  void ready();
  void queued();

private:
  [[nodiscard]] static ClipboardImageResult prepare(ApplicationAllocator &memory, ClipboardImageJob job, platform::ClipboardImageSource source);
  void start(ClipboardImageJob job);
  void complete();
  void drain();
  void startQueued();

  ApplicationAllocator &memory_;
  platform::ClipboardImageMonitor clipboard_;
  QFutureWatcher<ClipboardImageResult> task_;
  std::optional<ClipboardImageJob> running_;
  std::optional<ClipboardImageJob> queued_;
  std::optional<ClipboardImageResult> result_;
  bool busy_ = false;
};

}
