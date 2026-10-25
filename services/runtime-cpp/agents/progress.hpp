#pragma once

#include <algorithm>

#include "../memory/fixed_text.hpp"
#include "telar_client/serializers/telar_protocol.hpp"

namespace telar::runtime {

class AgentProgress {
public:
  bool apply(const ReportAgentProgress &report) {
    if (!report.final_message.empty()) {
      final_message.assign(report.final_message);
    }

    switch (report.plan_op) {
    case AgentPlanOp::none:
      break;
    case AgentPlanOp::add:
      if (count_ == task_capacity) {
        return false;
      }
      tasks_[count_].subject.assign(report.plan_text);
      tasks_[count_++].status = AgentPlanStatus::pending;
      uses_tasks_ = true;
      break;
    case AgentPlanOp::mark:
      if (report.plan_index < count_) {
        tasks_[report.plan_index].status = report.plan_status;
      }
      break;
    case AgentPlanOp::set:
      count_ = 0;
      uses_tasks_ = false;
      done_ = report.plan_done;
      total_ = report.plan_total;
      step_.assign(report.plan_text);
      break;
    }

    return true;
  }

  std::uint16_t done() const noexcept {
    if (!uses_tasks_) {
      return done_;
    }
    return static_cast<std::uint16_t>(std::count_if(tasks_.begin(), tasks_.begin() + count_, [](const Task &task) { return task.status == AgentPlanStatus::completed; }));
  }

  std::uint16_t total() const noexcept {
    if (!uses_tasks_) {
      return total_;
    }
    return static_cast<std::uint16_t>(std::count_if(tasks_.begin(), tasks_.begin() + count_, [](const Task &task) { return task.status != AgentPlanStatus::deleted; }));
  }

  std::string_view step() const noexcept {
    if (!uses_tasks_) {
      return step_.view();
    }
    std::string_view pending;
    for (const auto &task : std::span{tasks_}.first(count_)) {
      if (task.status == AgentPlanStatus::in_progress) {
        return task.subject.view();
      }
      if (task.status == AgentPlanStatus::pending && pending.empty()) {
        pending = task.subject.view();
      }
    }

    return pending;
  }

  FixedText<2048> final_message;
  static constexpr std::size_t task_capacity = 128;

private:
  struct Task {
    FixedText<96> subject;
    AgentPlanStatus status = AgentPlanStatus::pending;
  };

  std::array<Task, task_capacity> tasks_{};
  std::size_t count_ = 0;
  bool uses_tasks_ = false;
  std::uint16_t done_ = 0;
  std::uint16_t total_ = 0;
  FixedText<96> step_;
};

}
