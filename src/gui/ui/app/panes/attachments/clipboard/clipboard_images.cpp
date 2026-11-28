module telar.gui.ui.app.panes.attachments.clipboard;

import std;
import telar.gui.qt;
import telar.gui.foundation.core;
import telar.gui.platform;
import telar.base.ds;
import telar.base.memory.allocators;

namespace telar::gui::qt {

  static_assert(ConcurrentAllocator<ApplicationAllocator>);

  ClipboardImages::ClipboardImages(tbc::mut_a<ApplicationAllocator> memory, QObject* parent)
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
    } catch (const std::exception& error) {
      telar::qt::warning() << "Clipboard image worker failed during shutdown:" << error.what();
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

  tbc::val_a<ds::Option<ClipboardImageResult>> ClipboardImages::takeResult() {
    return std::exchange(result_, ds::none);
  }

  ClipboardImageResult ClipboardImages::prepare(ApplicationAllocator& memory, ClipboardImageJob job, platform::ClipboardImageSource source) {
    ClipboardImageResult result{.job = job};

    try {
      result.capture = source.read(memory, job.request);
      result.preview = AttachmentPreview::decode(memory, *result.capture);
    } catch (const platform::ClipboardImageFailure& error) {
      result.failure = error.code();
      result.error = QString::fromUtf8(error.what());
    } catch (const std::exception& error) {
      result.error = QString::fromUtf8(error.what());
    }

    return result;
  }

  void ClipboardImages::start(ClipboardImageJob job) {
    busy_ = true;
    running_ = job;
    try {
      auto source = clipboard_.snapshot();

      task_.setFuture(QtConcurrent::run(&worker_pool_, [memory = &memory_, job, snapshot = std::move(source)] mutable {
        return prepare(*memory, job, std::move(snapshot));
      }));
    } catch (const platform::ClipboardImageFailure& error) {
      result_ = ClipboardImageResult{.job = job, .failure = error.code(), .error = QString::fromUtf8(error.what())};
      ready();
      drain();
    } catch (const std::exception& error) {
      result_ = ClipboardImageResult{.job = job, .error = QString::fromUtf8(error.what())};
      ready();
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
    } catch (const std::exception& error) {
      result_ = ClipboardImageResult{.job = *running_, .error = QString::fromUtf8(error.what())};
    }

    ready();
    drain();
  }

  void ClipboardImages::drain() {
    running_.reset();
    if (queued_) {
      queued();
    } else {
      busy_ = false;
    }
  }

  void ClipboardImages::startQueued() {
    const auto pending = std::exchange(queued_, ds::none);
    if (pending) {
      start(*pending);
    } else {
      busy_ = false;
    }
  }

}
