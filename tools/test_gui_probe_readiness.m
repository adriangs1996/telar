#include "gui_tui_latency.m"


static void require_condition(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "%s\n", message);
        exit(EXIT_FAILURE);
    }
}

static ProbeFrame *ready_frame(void) {
    observe_presentation = YES;
    setup_complete = NO;
    initial_presentation = (ProbeInitialPresentation){0};
    geometry_changed_at = 10;
    atomic_store(&geometry_epoch, 7);
    atomic_store(&located, true);
    pixel_width = 1600;
    pixel_height = 1000;
    marker_x = 235;
    marker_y = 191;

    ProbeFrame *frame = [ProbeFrame new];
    frame->geometry = 7;
    frame->gpu = 11;
    frame->presented = 12;
    frame->verified = YES;
    frame->drawable_id = 0;
    return frame;
}

int main(void) {
    @autoreleasepool {
        ProbeFrame *frame = ready_frame();
        frame->presented = 0;
        accept_frame(frame);
        require_condition(!initial_presentation.presented, "GPU completion alone admitted setup");
        frame->presented = 12;
        accept_frame(frame);
        require_condition(initial_presentation.presented == 12, "Presentation after GPU was lost");
        require_condition(initial_presentation.drawable_id == 0 && initial_presentation.width == 1600 &&
            initial_presentation.height == 1000 && initial_presentation.marker_x == 235 &&
            initial_presentation.marker_y == 191 && initial_presentation.geometry == 7,
            "Initial presentation did not preserve its drawable and geometry");

        frame = ready_frame();
        frame->gpu = 0;
        frame->verified = NO;
        accept_frame(frame);
        require_condition(!initial_presentation.presented, "Presentation alone admitted setup");
        frame->gpu = 11;
        frame->verified = YES;
        accept_frame(frame);
        require_condition(initial_presentation.presented == 12, "GPU after presentation was lost");

        frame = ready_frame();
        frame->geometry = 6;
        accept_frame(frame);
        require_condition(!initial_presentation.presented, "Obsolete geometry admitted setup");
        frame = ready_frame();
        frame->sequence = 1;
        accept_frame(frame);
        require_condition(!initial_presentation.presented, "Measured response became setup evidence");
        frame = ready_frame();
        frame->verified = NO;
        accept_frame(frame);
        require_condition(!initial_presentation.presented, "Unverified pixels admitted setup");
        frame = ready_frame();
        atomic_store(&located, false);
        accept_frame(frame);
        require_condition(!initial_presentation.presented, "Missing marker admitted setup");
        frame = ready_frame();
        frame->presented = 9;
        accept_frame(frame);
        require_condition(!initial_presentation.presented, "Pre-resize presentation admitted setup");
        frame = ready_frame();
        frame->presented = NAN;
        accept_frame(frame);
        require_condition(!initial_presentation.presented, "Nonfinite presentation admitted setup");
        frame = ready_frame();
        setup_complete = YES;
        accept_frame(frame);
        require_condition(!initial_presentation.presented, "Completed setup was overwritten");
        frame = ready_frame();
        observe_presentation = NO;
        accept_frame(frame);
        require_condition(!initial_presentation.presented, "GPU endpoint recorded native readiness");
        frame = ready_frame();
        accept_frame(frame);
        reset_locator();
        require_condition(!initial_presentation.presented && !atomic_load(&located) &&
            atomic_load(&geometry_epoch) == 8, "Locator reset retained presentation evidence");
        require_condition(!pending && !count, "Setup consumed a timing response");
        puts("Native readiness join passed");
    }
    return EXIT_SUCCESS;
}
