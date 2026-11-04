static void send_key(void);

static BOOL schedule_switch_start(void) {
    double origins[TabPhaseProducers];
    for (unsigned tab = 0; tab < TabPhaseProducers; ++tab) {
        NSString *path = [display_directory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"switching/%u.events", tab]];
        NSData *events = [NSData dataWithContentsOfFile:path];
        if (!events || !tab_phase_origin(events.bytes, events.length, &origins[tab])) {
            return NO;
        }
    }
    if (!tab_phase_plan(origins, CACurrentMediaTime(), &switch_phase)) {
        return NO;
    }
    switch_phase_started = YES;
    switch_phase_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT,
        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    if (!switch_phase_timer) {
        return NO;
    }
    dispatch_source_set_timer(switch_phase_timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)((switch_phase.deadline - CACurrentMediaTime()) * NSEC_PER_SEC)),
        DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(switch_phase_timer, ^{
        dispatch_source_cancel(switch_phase_timer);
        dispatch_async(dispatch_get_main_queue(), ^{
            switch_phase_timer = nil;
            send_key();
        });
    });
    dispatch_resume(switch_phase_timer);
    return YES;
}
