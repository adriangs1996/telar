#pragma once

#include "application/records.hpp"
#include "application/workspace_replica.hpp"
#include "core/memory.hpp"
#include "presentation/agent_status.hpp"
#include "presentation/project_activity.hpp"
#include "projection.hpp"
#include <QString>
#include <QVariantMap>
#include <cstddef>
#include <span>

namespace telar::gui::qt {

template <Allocator Memory>
QVariantMap projectRecord(const Workspace<Memory> &workspace, const WorkspaceReplica<Memory> &workspaces, std::span<const Agent<Memory>> agents, bool selected) {
  auto record = workspaceRecord(workspace, selected);
  const auto activity = ProjectActivity::derive(workspaces, agents, workspace.location.id);
  ProjectActivity::Text summary;
  record.insert(QStringLiteral("detail"), toQString(activity.summary(summary).value_or(workspace.path)));
  record.insert(QStringLiteral("attention"), toQString(activity.attentionLabel().view()));
  const auto color = activity.urgent ? AgentStatusPresentation::color(agents[*activity.urgent].status) : PaletteRole::overlay1;
  record.insert(QStringLiteral("attentionColor"), QString::fromLatin1(palette_names[static_cast<std::size_t>(color)]));

  return record;
}

}
