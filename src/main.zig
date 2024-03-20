const std = @import("std");
const builtin = @import("builtin");
const tray = @import("tray");
const nb = @import("nb.zig");

fn Millis(comptime ms: u32) u64 {
    return @as(u64, @intCast(ms)) * 1000 * 1000;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    if (builtin.os.tag == .windows) {
        std.debug.print("setting up tray icon\n", .{});
        try setUpTray();
    }
    std.debug.print("ready", .{});

    const user: []const u8 = "<username>";
    const password: []const u8 = "<password>";

    var client = try nb.NaturClient.init(allocator);
    _ = try client.auth(user, password);
}

pub fn onQuit(menu: *tray.Menu) void {
    menu.tray.exit();
}

pub fn onBubble(menu: *tray.Menu) void {
    std.time.sleep(Millis(5000));
    menu.tray.showNotification("Hello", "This is a notification", 5000);
}

fn setUpTray() !void {
    // zig fmt: off
    var tray_inst = tray.Tray{ 
        .allocator = std.heap.page_allocator, 
        .icon = try tray.createIconFromFile("icon.ico"), 
        .menu = &[_]tray.ConstMenu{
            .{
                .text = "nb-notifier",
                .submenu = &[_]tray.ConstMenu{
                    .{
                        .text = "Show notification",
                        .onClick = onBubble,
                    }
                }
            },
            .{
                .text = "Quit",
                .onClick = onQuit,
            },
        } };
    // zig fmt: on
    try tray_inst.init();
    defer tray_inst.deinit();

    tray_inst.run();
}
