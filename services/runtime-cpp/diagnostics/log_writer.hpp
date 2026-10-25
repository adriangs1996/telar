#pragma once

#include "../platform/observation_worker.hpp"
#include "line.hpp"
#include "log_sink.hpp"

namespace telar::runtime::diagnostics {

class LogWriter {
public:
  using Request = std::string_view;
  using Result = bool;

  explicit LogWriter(std::string_view endpoint) noexcept
      : sink_(endpoint) {}

  Result observe(const Request &line) noexcept {
    return sink_.write(line);
  }

  void stop() noexcept {}

  bool available() const noexcept {
    return sink_.available();
  }

private:
  LogSink sink_;
};

class LogSession {
public:
  explicit LogSession(std::string_view endpoint) noexcept
      : writer_(prepare(endpoint)) {
    if (writer_.available()) {
      try {
        worker_.emplace(writer_);
      } catch (...) {
      }
    }
  }

  ~LogSession() {
    if (worker_) {
      worker_->wait([](bool) {});
    }
  }

  template <typename Format>
  void sample(Format &&format) noexcept {
    if (!worker_) {
      return;
    }

    worker_->collect([this](bool written) {
      pending_ = false;
      failed_ = !written;
    });
    if (pending_ || failed_) {
      return;
    }

    try {
      line_.reset();
      format(line_);
      pending_ = worker_->submit(line_.finish());
    } catch (...) {
    }
  }

private:
  static std::string_view prepare(std::string_view endpoint) noexcept {
    LogSink::removeOrphans(endpoint);
    return endpoint;
  }

  LogWriter writer_;
  Line line_;
  std::optional<ObservationWorker<LogWriter>> worker_;
  bool pending_ = false;
  bool failed_ = false;
};

}
