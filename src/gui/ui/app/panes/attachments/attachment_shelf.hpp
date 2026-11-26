#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "attachment_preview.hpp"
#include "clipboard_images.hpp"
#include "tbc/view.hpp"
#include <QImage>
#include <QObject>
#include <QPointF>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <optional>

#pragma once

import telar.gui.application;
import telar.gui.foundation.keys;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.gui.platform;

namespace telar::gui::qt {

  struct AttachmentSource {
    application::machines::MachineClientKey source;
    std::uint64_t runtime_generation = 0;

    bool operator==(const AttachmentSource&) const = default;
  };

  struct AttachmentPrompt {
    application::machines::MachineClientKey source;
    std::uint64_t runtime_generation = 0;
    AttachmentTarget target;
    std::uint64_t attachment_generation = 0;
    AttachmentMarkerPolicy policy = AttachmentMarkerPolicy::ordered;
  };

  class AttachmentShelf final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(AttachmentShelfController)
    QML_UNCREATABLE("Use the window's attachment shelf")
    Q_PROPERTY(QVariantList items READ items NOTIFY changed)
    Q_PROPERTY(QString paneId READ paneId NOTIFY changed)
    Q_PROPERTY(QVariantMap modal READ modal NOTIFY changed)
    Q_PROPERTY(bool hoverReady READ hoverReady NOTIFY hoverReadyChanged)
    Q_PROPERTY(bool hoverKnown READ hoverKnown NOTIFY hoverRecoveryChanged)
    Q_PROPERTY(QPointF hoverPosition READ hoverPosition NOTIFY hoverRecoveryChanged)

  public:
    explicit AttachmentShelf(ApplicationAllocator& memory, QObject* parent = nullptr);
    ~AttachmentShelf() override = default;
    AttachmentShelf(const AttachmentShelf&) = delete;
    AttachmentShelf& operator=(const AttachmentShelf&) = delete;
    AttachmentShelf(AttachmentShelf&&) = delete;
    AttachmentShelf& operator=(AttachmentShelf&&) = delete;

    [[nodiscard]] bool hoverReady() const noexcept;
    [[nodiscard]] bool hoverKnown() const noexcept;
    [[nodiscard]] QPointF hoverPosition() const noexcept;
    void observePointer(ds::Option<QPointF> position);
    void setSource(AttachmentSource source);
    void setPrompt(ds::Option<AttachmentPrompt> prompt, bool presented = true);
    void requestCapture();
    void clearPrompt(AttachmentTarget target);
    bool remove(std::uint64_t id);
    void observeKey(const TerminalKey& key, application::terminal::attachments::AttachmentMarkerScreen screen);
    void reconcile(application::terminal::attachments::AttachmentMarkerScreen screen);
    [[nodiscard]] application::terminal::attachments::AttachmentMarkerPlan removalPlan(std::uint64_t id, application::terminal::attachments::AttachmentMarkerScreen screen) const noexcept;
    [[nodiscard]] QVariantList items() const;
    [[nodiscard]] QString paneId() const;
    [[nodiscard]] QVariantMap modal() const;
    [[nodiscard]] const ds::Option<AttachmentPrompt>& prompt() const noexcept;
    [[nodiscard]] const ds::Option<AttachmentPrompt>& capturePrompt() const noexcept;
    [[nodiscard]] bool hasVisibleItems() const noexcept;
    Q_INVOKABLE QImage image(const QString& identity, bool full) const;
    Q_INVOKABLE void open(const QString& identity);
    Q_INVOKABLE void close();
    Q_INVOKABLE void dismiss(const QString& identity);

  signals:
    void changed();
    void hoverReadyChanged();
    void hoverRecoveryChanged();
    void failed(const QString& message);
    void quotaReached(platform::ClipboardImageError error);
    void evicted(application::terminal::attachments::AttachmentEviction reason, qulonglong requested);
    void dismissRequested(qulonglong identity);
    void adopted(qulonglong pane_id);

  private:
    struct Delivery {
      struct SlotState {
        AttachmentPreview preview;
      };

      [[nodiscard]] SlotState create();
      void retire(SlotState& slot) noexcept;
      [[nodiscard]] static bool canRelease(const SlotState& slot) noexcept;

      ds::Option<AttachmentPreview> landing;
    };

    void complete();
    void adopt(ClipboardImageResult& result);
    [[nodiscard]] bool current(const ClipboardImageJob& job) const noexcept;

    ds::Option<QPointF> hover_pointer_;
    ds::Option<QPointF> hover_recovery_;
    bool hover_ready_ = true;
    application::terminal::attachments::ClipboardCaptureState captures_;
    ds::Option<AttachmentPrompt> prompt_;
    ds::Option<AttachmentPrompt> capture_prompt_;
    ds::Option<AttachmentSource> source_;
    Delivery delivery_;
    // The catalog delivers through the delivery stored beside it.
    tbc::val_self<application::terminal::attachments::AttachmentCatalog<ApplicationAllocator, Delivery>> catalog_;
    ClipboardImages worker_;
  };

}
