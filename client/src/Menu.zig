const Menu = @This();

pub const Screen = enum {
    main,
    multiplayer,
};

pub const OptionsTab = enum {
    gameplay,
    keyboard_mouse,
    video,
    graphics,
};

pub const Mode = union(enum) {
    none,
    pause,
    options: struct { return_to_pause: bool },
};

screen: Screen = .main,
mode: Mode = .none,
options_tab: OptionsTab = .gameplay,

pub fn paused(menu: *const Menu) bool {
    return menu.mode != .none;
}
