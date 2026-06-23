const std = @import("std");
const nz = @import("shared").numz;
const system = @import("../system.zig");
const shared = @import("shared");
const tracy = @import("ztracy");
const Info = system.Info;
const yes = @import("yes");
const Ui = @import("../Renderer/Vulkan/Ui.zig");
const NetworkManager = @import("NetworkManager.zig");

fov_rad: f32 = 1.5,
aspect: f32 = 0,
near: f32 = 0.1,
far: f32 = 1000,
speed: f32 = 5,
sensitivity: f32 = 1,
was_rotating: bool = false,
mouse_pos: [2]f64 = .{ 0, 0 },
mouse_prev_pos: [2]f64 = .{ 0, 0 },

health: f32 = 100,

input_map: shared.net.Input = .{},

transform: nz.Transform3D(f32) = .{},

pub fn update(self: *@This(), info: *const Info, network_manager: *NetworkManager, ui: *Ui) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    self.input_map.mouse_delta[0] = self.mouse_pos[0] - self.mouse_prev_pos[0];
    self.input_map.mouse_delta[1] = self.mouse_pos[1] - self.mouse_prev_pos[1];
    self.mouse_prev_pos[0] = self.mouse_pos[0];
    self.mouse_prev_pos[1] = self.mouse_pos[1];

    const position: [2]f32 = .{ @floatCast(self.mouse_pos[0]), @floatCast(self.mouse_pos[1]) };
    // var buf: [32]u8 = undefined;
    ui.start(.{
        .position = .{ .left = position[0], .top = position[1] },
        .left_click = self.input_map.keys.mouse_button_left,
        .right_click = self.input_map.keys.mouse_button_right,
    });
    if (network_manager.steam_client.server_conn == 0) {
        ui.add(null, .{
            .name = "root",
            .size = .{ .fixed = .{
                .heigth = 500,
                .width = 400,
            } },
            .position = .center,
            .color = .new(0.5, 0.5, 0.5, 0.8),
            .axis_align = .verical,
            .children = &.{
                .{
                    .name = "servers",
                    .position = .{ .fixed = .{ .left = 0, .top = 0 } },
                    .axis_align = .verical,
                    .size = .{
                        .percent = .{
                            .heigth = 0.8,
                            .width = 1.0,
                        },
                    },
                },
                .{ .name = "buttons", .position = .{
                    .fixed = .{ .left = 0, .top = 0 },
                }, .axis_align = .horizontal, .size = .{
                    .percent = .{
                        .heigth = 0.2,
                        .width = 1.0,
                    },
                }, .color = .new(0.1, 0.1, 0.1, 1), .children = &.{
                    .{ .position = .center, .size = .{
                        .fixed = .{
                            .heigth = 40,
                            .width = 100,
                        },
                    }, .color = if (ui.isHot("refresh")) .new(0.2, 0.2, 0.2, 1) else .grey, .name = "refresh", .text = "Refresh" },
                } },
            },
        });
        for (0..network_manager.server_list.count) |i| {
            const server = &network_manager.server_list.servers[i];
            ui.add("servers", .{
                .name = &server.id_str,
                .text = &server.id_str,
                .position = .{ .fixed = .{ .left = 0, .top = 0 } },
                .size = .{ .percent = .{
                    .heigth = 0.2,
                    .width = 1.0,
                } },
                .color = if (ui.isHot(&server.id_str)) .new(0.2, 0.2, 0.2, 1) else .grey,
            });
            if (ui.isActive(&server.id_str)) {
                try network_manager.steam_client.connectToServer(server.steam_id);
                std.log.debug("connect to {d}", .{server.steam_id});
            }
        }
        if (ui.isActive("refresh") and network_manager.server_list.refresh == false) {
            network_manager.server_list.refresh = true;
        }
    } else {
        const healthbar_width: f32 = 200 * self.health / 100;
        const healthbar_heigth: f32 = 30;

        ui.add(null, .{
            .position = .{
                .fixed = .{
                    .top = ui.screen_heigth - healthbar_heigth - 10,
                    .left = 10,
                },
            },
            .size = .{ .fixed = .{ .heigth = healthbar_heigth, .width = healthbar_width } },
            .color = .new(1, 0, 0, 1),
        });

        if (info.world.portal_active == false) {
            if (info.world.getPtr(info.world.teleportal_id)) |teleporter| {
                if (info.world.getPtr(info.world.player_id)) |player| {
                    if (nz.vec.length(player.transform.position - teleporter.transform.position) < shared.portal_reach_distance) {
                        // const s = try std.fmt.bufPrint(&buf, "{d:.2}", .{nz.vec.length(player.transform.position - teleporter.transform.position)});
                        ui.add(
                            null,
                            .{
                                .name = "active_teleport",
                                .size = .{ .fixed = .{ .heigth = 0, .width = 0 } },
                                .text = "E",
                                .position = .center,
                            },
                        );
                    }
                }
            }
        } else {
            ui.add(null, .{
                .position = .{
                    .fixed = .{
                        .top = 10,
                        .left = ui.screen_width / 2 - healthbar_width / 2,
                    },
                },
                .size = .{ .fixed = .{ .heigth = healthbar_heigth, .width = healthbar_width } },
                .color = .new(1, 0, 0, 1),
            });
        }

        // ui.add(
        //     null,
        //     .{ .name = "display", .size = .{ .fixed = .{ .heigth = 0, .width = 0 } }, .text = s, .position = .center },
        // );
        // ui.add("display", .{ .position = .{ .fixed = .{ .top = 0, .left = 0 } }, .size = .{ .fixed = .{ .heigth = 100, .width = 100 } }, .name = "d-button" });
        // if (ui.isActive("d-button")) {
        //     self.input_map.forward = true;
        // }
    }

    ui.end();
}

pub fn eventUpdate(self: *@This(), info: *const Info, event: *const yes.Window.Event) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    _ = info;

    switch (event.*) {
        .key => |key| {
            // std.log.debug("pressed", .{});

            const pressed = key.state == .pressed;
            switch (key.sym) {
                .w => self.input_map.keys.w = pressed,
                .s => self.input_map.keys.s = pressed,
                .d => self.input_map.keys.d = pressed,
                .a => self.input_map.keys.a = pressed,
                .left_shift => self.input_map.keys.l_shift = pressed,
                .space => self.input_map.keys.space = pressed,
                .r => self.input_map.keys.r = pressed,
                .k => self.input_map.keys.k = pressed,
                .e => self.input_map.keys.e = pressed,
                else => {},
            }
        },
        .mouse_scroll => switch (event.mouse_scroll) {
            .vertical => |scroll| {
                self.input_map.mouse_wheel = scroll;
            },
            .horizontal => {},
        },
        .focus => |focused| {
            if (!focused) self.input_map = .{};
        },
        .mouse_motion => |motion| {
            self.mouse_pos[0] = motion.x;
            self.mouse_pos[1] = motion.y;
        },
        .mouse_button => |button| {
            if (button.state == .pressed and button.button == .left)
                self.input_map.keys.mouse_button_left = true
            else if (button.state == .released and button.button == .left) {
                self.input_map.keys.mouse_button_left = false;
            }
            if (button.state == .pressed and button.button == .right)
                self.input_map.keys.mouse_button_right = true
            else if (button.state == .released and button.button == .right) {
                self.input_map.keys.mouse_button_right = false;
            }
        },

        else => {},
    }
}
