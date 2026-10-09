const dvui = @import("dvui");
const Hud = @import("../Hud.zig");
const style = @import("style.zig");
const Request = Hud.Request;

pub fn update(hud: *Hud) Request {
    const button_size: dvui.Size = .{ .w = 260, .h = 44 };
    style.fillScreen(style.scrim);
    var panel = style.centeredPanel(@src(), 340, 270);
    defer panel.deinit();
    style.title(@src(), "Paused");
    if (style.button(@src(), "Resume", 0, button_size, false, true)) hud.overlay = .none;
    if (style.button(@src(), "Options", 0, button_size, false, true)) hud.overlay = .{ .options = .{ .return_to_pause = true } };
    if (style.button(@src(), "Main Menu", 0, button_size, false, true)) return .main_menu;
    return .none;
}
