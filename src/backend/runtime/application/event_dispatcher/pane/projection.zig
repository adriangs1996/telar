//! Runtime-event adapters for pane observation and media projections.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../../../attachment/root.zig");
const client_store = @import("../../../client/root.zig").store;
const pane_events = @import("../../../entrypoints/events/pane/root.zig");
const history = @import("../../../../history/root.zig");
const media_mod = @import("../../../../media/root.zig");
const pane_mod = @import("../../../../pane/root.zig");
const agent_process = @import("../../../../process/root.zig");

const schema = core.schema;
const diagnostics = core.diagnostics;

const AttachmentStore = attachment_mod.AttachmentStore;
const Pane = pane_mod.Pane;
const enforceGraphicsQuotas = attachment_mod.enforceGraphicsQuotas;
const max_clients = client_store.max_clients;
const media_projection = pane_events.media_projection;
const pane_media_coordinator = pane_events.media;
const pane_observation_coordinator = pane_events.observation;
const PaneMediaEvent = pane_media_coordinator.Completion;
const PaneObservationEvent = pane_observation_coordinator.Completion;

/// Declares the follow-up operations required by pane projections.
///
/// ```zig
/// const dependencies: Dependencies(Application) = .{ ... };
/// ```
pub fn Dependencies(comptime Application: type) type {
    return struct {
        schedule_description: *const fn (*Application) void,
        schedule_response: *const fn (*Application, *Pane) anyerror!void,
    };
}

/// Binds pane observation and media completions to one Application type.
///
/// ```zig
/// const PaneProjectionEvents = Dispatcher(Application, dependencies);
/// ```
pub fn Dispatcher(comptime Application: type, comptime dependencies: Dependencies(Application)) type {
    return struct {
        /// Applies one process/output observation to the pane and agent
        /// aggregates, then schedules any resulting description work.
        ///
        /// ```zig
        /// try PaneProjectionEvents.handleObserved(&application, event);
        /// ```
        pub fn handleObserved(application: *Application, event: PaneObservationEvent) !void {
            var coordinator = paneObservationCoordinator(application);
            try coordinator.handle(event);
        }

        /// Applies one decoded media projection, synchronizes client
        /// attachments and schedules any generated terminal response.
        ///
        /// ```zig
        /// try PaneProjectionEvents.handleMedia(&application, event);
        /// ```
        pub fn handleMedia(application: *Application, event: PaneMediaEvent) !void {
            var coordinator = paneMediaCoordinator(application);
            try coordinator.handle(event);
        }

        /// Starts a pane observation when its single-flight state permits it.
        ///
        /// ```zig
        /// try PaneProjectionEvents.scheduleObservation(&application, pane);
        /// ```
        pub fn scheduleObservation(application: *Application, pane: *Pane) !void {
            var coordinator = paneObservationCoordinator(application);
            return coordinator.schedule(pane);
        }

        /// Starts media processing when the pane has pending media work and no
        /// media operation is already in flight.
        ///
        /// ```zig
        /// try PaneProjectionEvents.scheduleMedia(&application, pane);
        /// ```
        pub fn scheduleMedia(application: *Application, pane: *Pane) !void {
            var coordinator = paneMediaCoordinator(application);
            return coordinator.schedule(pane);
        }

        const pane_observation_runtime_port: pane_observation_coordinator.RuntimePort(Application) = .{
            .start = startPaneObservation,
            .publish_sound = publishObservedAgentSound,
            .schedule_description = dependencies.schedule_description,
            .collect = collectPaneLifecycle,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimePaneObservationCoordinator = pane_observation_coordinator.Coordinator(Application, pane_observation_runtime_port);

        fn paneObservationCoordinator(application: *Application) RuntimePaneObservationCoordinator {
            return RuntimePaneObservationCoordinator.init(application, .{
                .io = application.io,
                .panes = &application.model.panes,
                .agents = &application.model.agents,
                .metrics = &application.metrics,
            });
        }

        fn startPaneObservation(application: *Application, work: pane_observation_coordinator.Work) !void {
            try application.select.concurrent(.pane_observed, observePane, .{work});
        }

        fn observePane(work: pane_observation_coordinator.Work) PaneObservationEvent {
            const path = diagnostics.enter(.observation);
            defer path.restore();

            var stats: history.observer.Stats = .{};
            const process_probe = agent_process.probe(
                work.pane.session.foregroundProcessGroup(),
                work.pane.session.pid,
                work.process_cache,
            );
            work.pane.processHistoryObservation(work.current_size, &stats);
            return .{ .pane = work.pane.key(), .stats = stats, .process_probe = process_probe };
        }

        fn publishObservedAgentSound(application: *Application, notification: schema.AgentSoundNotification) void {
            application.publishAgentSound(notification);
        }

        const pane_media_runtime_port: pane_media_coordinator.RuntimePort(Application) = .{
            .start = startPaneMedia,
            .enforce_quotas = enforcePaneGraphicsQuotas,
            .synchronize_clients = synchronizeMediaClients,
            .schedule_response = dependencies.schedule_response,
            .pump_clients = pumpRuntimeClients,
            .collect = collectPaneLifecycle,
        };

        const RuntimePaneMediaCoordinator = pane_media_coordinator.Coordinator(Application, pane_media_runtime_port);

        fn paneMediaCoordinator(application: *Application) RuntimePaneMediaCoordinator {
            return RuntimePaneMediaCoordinator.init(application, .{
                .panes = &application.model.panes,
                .metrics = &application.metrics,
            });
        }

        fn startPaneMedia(application: *Application, work: pane_media_coordinator.Work) !void {
            try application.select.concurrent(.pane_media, processPaneMedia, .{work});
        }

        fn processPaneMedia(work: pane_media_coordinator.Work) PaneMediaEvent {
            const path = diagnostics.enter(.media);
            defer path.restore();

            var stats: media_mod.Stats = .{};
            work.pane.processMedia(work.current_size, &stats);
            return .{ .pane = work.pane.key(), .stats = stats };
        }

        fn enforcePaneGraphicsQuotas(application: *Application, pane: *Pane) void {
            enforceGraphicsQuotas(application.io, pane);
        }

        fn synchronizeMediaClients(application: *Application, pane: *Pane, reset: bool) media_projection.Stats {
            var stores: [max_clients]*AttachmentStore = undefined;
            var count: usize = 0;

            for (&application.clients.items) |*slot| {
                const client = slot.* orelse continue;
                stores[count] = &client.attachments;
                count += 1;
            }

            return media_projection.synchronize(pane, stores[0..count], reset);
        }

        fn collectPaneLifecycle(application: *Application) void {
            application.collect();
        }

        fn pumpRuntimeClients(application: *Application) void {
            application.pumpAll();
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
