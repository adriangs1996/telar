#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "attachment_preview.hpp"
#include "platform/clipboard_image_monitor.hpp"
#include <QFutureWatcher>
#include <QObject>
#include <QString>
#include <QThreadPool>
#include <cstdint>
#include <optional>

#pragma once

import telar.gui.application;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.gui.platform;
import telar.tbc;

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
    explicit ClipboardImages(tbc::mut_a<ApplicationAllocator> memory, QObject* parent = nullptr);
    ~ClipboardImages() override;
    ClipboardImages(const ClipboardImages&) = delete;
    ClipboardImages& operator=(const ClipboardImages&) = delete;
    ClipboardImages(ClipboardImages&&) = delete;
    ClipboardImages& operator=(ClipboardImages&&) = delete;

    void capture(ClipboardImageJob job);
    [[nodiscard]] tbc::val_a<ds::Option<ClipboardImageResult>> takeResult();
    [[nodiscard]] bool busy() const noexcept;

  signals:
    void ready();
    void queued();

  private:
    // The prepared images are allocated from memory.
    [[nodiscard]] static tbc::val_a<ClipboardImageResult> prepare(tbc::mut_a<ApplicationAllocator> memory, ClipboardImageJob job, platform::ClipboardImageSource source);
    void start(ClipboardImageJob job);
    void complete();
    void drain();
    void startQueued();

    tbc::mut_a<ApplicationAllocator> memory_;
    tbc::val_a<platform::ClipboardImageMonitor> clipboard_;
    QThreadPool worker_pool_;
    QFutureWatcher<ClipboardImageResult> task_;
    ds::Option<ClipboardImageJob> running_;
    ds::Option<ClipboardImageJob> queued_;
    tbc::val_a<ds::Option<ClipboardImageResult>> result_;
    bool busy_ = false;
  };

}
