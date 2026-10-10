const std = @import("std");
const dvui = @import("dvui");
const Controller = @import("../Controller.zig");
const Options = @import("../../Options.zig");
const Hud = @import("../Hud.zig");
const style = @import("style.zig");
const OptionsTab = Hud.OptionsTab;

pub fn update(hud: *Hud, options: *Options, controller: *Controller) void {
    const area = style.screen();
    style.fillScreen(style.scrim);
    var panel = style.centeredPanel(
        @src(),
        @min(area.w - 8, @max(740, area.w * 0.6)),
        @min(area.h - 8, @max(460, area.h * 0.75)),
    );
    defer panel.deinit();
    style.title(@src(), "Options");

    {
        var tabs = dvui.box(
            @src(),
            .{ .dir = .horizontal, .equal_space = true },
            .{ .expand = .horizontal },
        );
        defer tabs.deinit();
        for (std.enums.values(OptionsTab), 0..) |tab, index| {
            if (style.button(
                @src(),
                tabLabel(tab),
                index,
                .{ .w = 100, .h = 36 },
                hud.options_tab == tab,
                true,
            )) hud.options_tab = tab;
        }
    }

    {
        var body = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .margin = .{ .y = 12 } });
        defer body.deinit();
        switch (hud.options_tab) {
            .gameplay => toggle(@src(), "Crosshair", &options.show_crosshair),
            .keyboard_mouse => {
                slider(
                    @src(),
                    "Mouse Sensitivity",
                    &options.mouse_sensitivity,
                    0.1,
                    10.0,
                    "{d:.2}",
                );
                toggle(@src(), "Invert Y", &options.invert_y);
                var index: usize = 0;
                for (std.enums.values(Controller.ActionKind)) |action| {
                    const label = Controller.bindable.get(action) orelse continue;
                    const value = if (controller.rebinding_action == action) "Listening" else Controller.bindingLabel(
                        controller.bindings.get(action),
                    );
                    if (row(@src(), index, label, value)) {
                        controller.rebinding_action = action;
                        controller.rebinding_fresh = true;
                    }
                    index += 1;
                }
            },
            .video => {
                toggle(@src(), "Fullscreen", &options.fullscreen);
                var fov_degrees = options.fov_rad * 180.0 / std.math.pi;
                slider(@src(), "Field of View", &fov_degrees, 65, 115, "{d:.0}");
                options.fov_rad = fov_degrees * std.math.pi / 180.0;
                slider(@src(), "Chunk View Distance", &options.chunk_view_distance, 1, 8, "{d:.0}");
                options.chunk_view_distance = @round(options.chunk_view_distance);
            },
            .graphics => {
                toggle(@src(), "Anti-aliasing (FXAA)", &options.anti_aliasing);
                slider(@src(), "Bloom", &options.bloom, 0, 1.5, "{d:.2}");
                toggle(@src(), "Debug Colliders", &controller.debug_draw_colliders);
            },
            .audio => slider(@src(), "Master Volume", &options.master_volume, 0, 1, "{d:.2}"),
        }
    }

    if (style.button(@src(), "Back", 0, .{ .w = 150, .h = 40 }, false, true)) {
        hud.overlay = if (hud.overlay.options.return_to_pause) .pause else .none;
    }
}

fn row(
    src: std.builtin.SourceLocation,
    id_extra: usize,
    label: []const u8,
    value: []const u8,
) bool {
    var line = dvui.box(src, .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .background = true,
        .color_fill = .fromColor(style.control.opacity(0.8)),
        .margin = .{ .y = 2, .h = 2 },
        .padding = .{ .x = 12, .w = 6 },
    });
    defer line.deinit();
    dvui.labelNoFmt(
        @src(),
        label,
        .{},
        .{
            .font = style.font(20),
            .color_text = .fromColor(style.text),
            .gravity_y = 0.5,
            .expand = .horizontal,
        },
    );
    var value_box = dvui.box(
        @src(),
        .{ .dir = .vertical },
        .{ .min_size_content = .{ .w = 180, .h = 0 }, .gravity_x = 1 },
    );
    defer value_box.deinit();
    return style.button(@src(), value, 0, .{ .w = 170, .h = 32 }, false, true);
}

fn toggle(src: std.builtin.SourceLocation, label: []const u8, value: *bool) void {
    if (row(src, 0, label, if (value.*) "On" else "Off")) value.* = !value.*;
}

fn slider(
    src: std.builtin.SourceLocation,
    label: []const u8,
    value: *f32,
    min: f32,
    max: f32,
    comptime value_format: []const u8,
) void {
    var line = dvui.box(src, .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .fromColor(style.control.opacity(0.8)),
        .margin = .{ .y = 2, .h = 2 },
        .padding = .{ .x = 12, .w = 12, .y = 6, .h = 6 },
    });
    defer line.deinit();
    dvui.labelNoFmt(
        @src(),
        label,
        .{},
        .{
            .font = style.font(20),
            .color_text = .fromColor(style.text),
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 230, .h = 0 },
        },
    );
    var fraction = std.math.clamp((value.* - min) / (max - min), 0, 1);
    if (dvui.slider(
        @src(),
        .{ .fraction = &fraction, .color_bar = style.accent },
        .{ .expand = .horizontal, .gravity_y = 0.5, .min_size_content = .{ .w = 160, .h = 24 } },
    )) {
        value.* = min + fraction * (max - min);
    }
    dvui.label(
        @src(),
        value_format,
        .{value.*},
        .{
            .font = style.font(20),
            .color_text = .fromColor(style.text),
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 80, .h = 0 },
        },
    );
}

fn tabLabel(tab: OptionsTab) []const u8 {
    return switch (tab) {
        .gameplay => "Gameplay",
        .keyboard_mouse => "Keyboard-Mouse",
        .video => "Video",
        .graphics => "Graphics",
        .audio => "Audio",
    };
}
