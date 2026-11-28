export module telar.gui.ui.app.chrome.activity:agent_projection;

import std;
import telar.gui.qt;
import telar.gui.foundation.model;
import telar.gui.ui.kit.models;
import telar.gui.foundation.core;
import telar.gui.foundation.agents;
import telar.gui.application;
import telar.config.core;
import telar.wire.vocabulary;

export namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  struct AgentRecordContext {
    std::string_view machine;
    // The branch of the workspace the card's pane is in, and whether it has changes.
    std::string_view branch;
    bool dirty = false;
    bool selected = false;
    bool connected = true;
    bool coordinator = false;
  };

  template <Allocator Memory>
  [[tbc::generic]] QVariantMap agentRecord(const Agent<Memory>& agent, const AgentRecordContext& context) {
    using Status = AgentStatusPresentation;
    const auto state = context.connected ? agent.status : AgentStatus::unknown;
    const auto word = context.connected ? Status::word(state, agent.blocked_reason) : "offline";
    const auto label = Status::text(state, agent.blocked_reason, agent.status_age_s, context.connected);
    AgentCardLabels::Project project;
    const auto project_label = AgentCardLabels::project(agent.workspace_label, context.machine, context.coordinator, project);
    const auto glyph = AgentCardLabels::providerGlyph(agent.provider_kind, agent.icon);
    const auto tile = application::activity::ApplicationMark::forApplication(runtime::describeProvider(agent.provider_kind).display_name);
    const auto provider_label = agent.display_name.empty() ? std::string_view{agent.provider_name} : std::string_view{agent.display_name};
    const auto activity = application::activity::TaskCardLabels::activity(agent);
    const auto color = QString::fromLatin1(palette_names[static_cast<std::size_t>(Status::color(state))]);
    const auto waiting = state == AgentStatus::blocked || state == AgentStatus::failed;
    const auto resting = state == AgentStatus::ready || state == AgentStatus::unknown;

    return {
        {u"key"_s, QString::number(agent.pane_id)},
        {u"title"_s, toQString(AgentCardLabels::title(agent.title, agent.display_name))},
        {u"provider"_s, toQString(provider_label)},
        {u"project"_s, toQString(project_label)},
        {u"detail"_s, toQString(agent.status == AgentStatus::working ? std::string_view{agent.detail} : context.branch)},
        // Where the agent works: its tab, its pane's directory and its workspace's repository.
        {u"tab"_s, toQString(agent.tab_label)},
        {u"cwd"_s, toQString(agent.cwd_label)},
        {u"branch"_s, toQString(context.branch)},
        {u"dirty"_s, context.dirty && !context.branch.empty()},
        {u"status"_s, toQString(label.view())},
        {u"statusWord"_s, toQString(word)},
        {u"statusColor"_s, color},
        // The badge on the provider's tile, its state's glyph in its color; an agent at rest has none.
        {u"badge"_s, resting ? QString{} : color},
        {u"badgeGlyph"_s, resting ? QString{} : toQString(Status::glyph(state, agent.blocked_reason))},
        // Tints the card while the agent waits on the person.
        {u"attention"_s, waiting ? color : QString{}},
        {u"dim"_s, state == AgentStatus::ready},
        {u"working"_s, state == AgentStatus::working},
        {u"signal"_s, toQString(activity.text)},
        {u"signalColor"_s, QString::fromLatin1(palette_names[static_cast<std::size_t>(context.connected ? activity.color : PaletteRole::overlay1)])},
        {u"showPlan"_s, context.connected && activity.plan},
        {u"contextShare"_s, application::activity::TaskCardLabels::contextShare(state, !activity.text.empty())},
        {u"statusCode"_s, static_cast<int>(state)},
        {u"blockedReason"_s, static_cast<int>(agent.blocked_reason)},
        {u"statusClock"_s, agent.status_clock.observed() ? statusAgeValue(agent.status_clock.interval()) : QVariant{}},
        {u"providerMark"_s, static_cast<int>(agent.provider_kind)},
        {u"glyph"_s, toQString(glyph)},
        {u"tile"_s, toQString(tile.tile)},
        {u"ink"_s, toQString(tile.ink)},
        {u"selected"_s, context.connected && context.selected},
        {u"enabled"_s, context.connected},
        {u"planStep"_s, toQString(agent.plan_step)},
        {u"planDone"_s, agent.plan_done},
        {u"planTotal"_s, agent.plan_total},
        {u"age"_s, agent.status_age_s},
    };
  }

}
