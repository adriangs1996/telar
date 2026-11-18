#pragma once

#include "attachment_preview.hpp"
#include "features/terminal/attachments/capture.hpp"
#include "features/terminal/attachments/types.hpp"
#include "foundation/core/application_memory.hpp"
#include "platform/clipboard_image_monitor.hpp"
#include "platform/clipboard_image_source.hpp"
#include "tbc/view.hpp"
#include <QFutureWatcher>
#include <QObject>
#include <QString>
#include <QThreadPool>
#include <cstdint>
#include <optional>

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  struct ClipboardImageJob {
    application::machines::MachineClientKey source;
    std::uint64_t runtime_generation = 0;
    std::uint64_t attachment_generation = 0;
    ClipboardCaptureRequest request;
  };

  struct ClipboardImageResult {
    ClipboardImageJob job;
    ds::Option<AttachmentCapture<ApplicationAllocator>> capture = ds::none;
    ds::Option<AttachmentPreview> preview = ds::none;
    ds::Option<platform::ClipboardImageError> failure = ds::none;
    QString error = {};
  };

  class ClipboardImages final : public QObject {
    Q_OBJECT

  public:
    // The captures allocate from memory, region `a`.
    explicit ClipboardImages(tbc::view<ApplicationAllocator&, tbc::lt::a> memory, QObject* parent = nullptr);
    ~ClipboardImages() override;
    ClipboardImages(const ClipboardImages&) = delete;
    ClipboardImages& operator=(const ClipboardImages&) = delete;
    ClipboardImages(ClipboardImages&&) = delete;
    ClipboardImages& operator=(ClipboardImages&&) = delete;

    void capture(ClipboardImageJob job);
    [[nodiscard]] tbc::view<ds::Option<ClipboardImageResult>, tbc::lt::a> takeResult();
    [[nodiscard]] bool busy() const noexcept;

  signals:
    void ready();
    void queued();

  private:
    // The prepared images are allocated from memory.
    [[nodiscard]] static tbc::view<ClipboardImageResult, tbc::lt::a> prepare(tbc::view<ApplicationAllocator&, tbc::lt::a> memory, ClipboardImageJob job, platform::ClipboardImageSource source);
    void start(ClipboardImageJob job);
    void complete();
    void drain();
    void startQueued();

    tbc::view<ApplicationAllocator&, tbc::lt::a> memory_;
    tbc::view<platform::ClipboardImageMonitor, tbc::lt::a> clipboard_;
    QThreadPool worker_pool_;
    QFutureWatcher<ClipboardImageResult> task_;
    ds::Option<ClipboardImageJob> running_;
    ds::Option<ClipboardImageJob> queued_;
    tbc::view<ds::Option<ClipboardImageResult>, tbc::lt::a> result_;
    bool busy_ = false;
  };

}
