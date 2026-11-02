#include "clipboard_images.hpp"
#include "application/dependencies.hpp"
#include "attachment_preview.hpp"
#include "memory/allocator.hpp"
#include "platform/clipboard_image_source.hpp"
#include <QFuture>
#include <QObject>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qnamespace.h>
#include <QString>
#include <QtConcurrentRun>
#include <QtCore/qlogging.h>
#include <exception>
#include <optional>
#include <utility>

namespace telar::gui::qt {

static_assert(runtime::ConcurrentAllocator<ApplicationAllocator>);

ClipboardImages::ClipboardImages(ApplicationAllocator &memory, QObject *parent)
    : QObject(parent),
      memory_(memory),
      clipboard_(memory) {
  constexpr int maximum_workers = 1;
  worker_pool_.setMaxThreadCount(maximum_workers);
  connect(this, &ClipboardImages::queued, this, &ClipboardImages::startQueued, Qt::QueuedConnection);
  connect(&task_, &QFutureWatcher<ClipboardImageResult>::finished, this, &ClipboardImages::complete);
}

ClipboardImages::~ClipboardImages() {
  task_.disconnect(this);
  clipboard_.cancel();
  auto future = task_.future();
  if (!future.isValid()) {
    return;
  }

  try {
    future.waitForFinished();
    if (future.resultCount() != 0) {
      static_cast<void>(future.takeResult());
    }
  } catch (const std::exception &error) {
    qWarning("Clipboard image worker failed during shutdown: %s", error.what());
  }
}

bool ClipboardImages::busy() const noexcept {
  return busy_;
}

void ClipboardImages::capture(ClipboardImageJob job) {
  if (busy_) {
    queued_ = job;

    return;
  }

  start(job);
}

std::optional<ClipboardImageResult> ClipboardImages::takeResult() {
  return std::exchange(result_, std::nullopt);
}

ClipboardImageResult ClipboardImages::prepare(ApplicationAllocator &memory, ClipboardImageJob job, platform::ClipboardImageSource source) {
  ClipboardImageResult result{.job = job};
  try {
    result.capture = source.read(memory, job.request);
    result.preview = AttachmentPreview::decode(memory, *result.capture);
  } catch (const platform::ClipboardImageFailure &error) {
    result.failure = error.code();
    result.error = QString::fromUtf8(error.what());
  } catch (const std::exception &error) {
    result.error = QString::fromUtf8(error.what());
  }

  return result;
}

void ClipboardImages::start(ClipboardImageJob job) {
  busy_ = true;
  running_ = job;
  try {
    auto source = clipboard_.snapshot();
    task_.setFuture(QtConcurrent::run(&worker_pool_, [memory = &memory_, job, source = std::move(source)] mutable {
      return prepare(*memory, job, std::move(source));
    }));
  } catch (const platform::ClipboardImageFailure &error) {
    result_ = ClipboardImageResult{.job = job, .failure = error.code(), .error = QString::fromUtf8(error.what())};
    emit ready();
    drain();
  } catch (const std::exception &error) {
    result_ = ClipboardImageResult{.job = job, .error = QString::fromUtf8(error.what())};
    emit ready();
    drain();
  }
}

void ClipboardImages::complete() {
  if (!running_) {
    return;
  }

  try {
    auto future = task_.future();
    result_ = future.takeResult();
  } catch (const std::exception &error) {
    result_ = ClipboardImageResult{.job = *running_, .error = QString::fromUtf8(error.what())};
  }

  emit ready();
  drain();
}

void ClipboardImages::drain() {
  running_.reset();
  if (queued_) {
    emit queued();
  } else {
    busy_ = false;
  }
}

void ClipboardImages::startQueued() {
  const auto pending = std::exchange(queued_, std::nullopt);
  if (pending) {
    start(*pending);
  } else {
    busy_ = false;
  }
}

}
