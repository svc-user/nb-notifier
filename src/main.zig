const std = @import("std");
const builtin = @import("builtin");
const zigwin32 = @import("zigwin32");
const tray = @import("tray");
const nb = @import("nb.zig");

const State = struct {
    tray: *tray.Tray,
    client: *nb.NaturClient,
    allocator: std.mem.Allocator,
};
var state: *State = undefined;

fn Millis(comptime ms: u32) u64 {
    return @as(u64, @intCast(ms)) * 1000 * 1000;
}

fn Seconds(comptime s: u32) u64 {
    return Millis(s * 1000);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var gpalloc = gpa.allocator();
    defer _ = gpa.deinit();

    state = try gpalloc.create(State);
    defer gpalloc.destroy(state);

    state.allocator = gpalloc;

    state.client = try nb.NaturClient.init(state.allocator);
    defer state.client.deinit() catch @panic("Fejl i afslutning af NaturClient");

    var creds = try nb.UserLogin.Load(state.allocator, "creds.json");
    defer {
        state.allocator.free(creds.password);
        state.allocator.free(creds.username);
    }

    if (!try state.client.auth(creds.username, creds.password)) {
        std.log.err("Kunne ikke logge ind som {s}", .{creds.username});
        std.os.exit(1);
    }

    const nto = std.os.windows.kernel32.CreateThread(null, 0, &unreadCheckLoop, null, 0, null);
    if (nto) |nt| {
        _ = nt;
        std.log.info("Tjekker efter notifikationer hvert 5. minut.", .{});
    }

    try setUpTray(); //blocking
}

var lastNotificationCount: u32 = 0;
fn unreadCheckLoop(_: std.os.windows.LPVOID) callconv(std.os.windows.WINAPI) std.os.windows.DWORD {
    while (true) {
        std.time.sleep(Seconds(10));

        const ur = state.client.getUnreadCount(state.client.userInfo.Id) catch 9999;

        const trayText = std.fmt.allocPrint(state.allocator, "nb-notifier ({d})", .{ur}) catch "nb-notifier";
        defer state.allocator.free(trayText);

        if (state.tray.mutable_menu) |mm| {
            mm[0].setText(trayText);
        }

        std.log.info("{d}: Bruger {s} har {d} ulæste notifikationer.", .{ std.time.timestamp(), state.client.userInfo.Name, ur });

        if (ur > lastNotificationCount) {
            const msg = std.fmt.allocPrint(state.allocator, "Hej {s}!\nDu har {d} {s} notifikationer!", .{ state.client.userInfo.Name, ur, if (ur == 1) "ulæst" else "ulæste" }) catch |err| @panic(@errorName(err));
            defer state.allocator.free(msg);

            const res = state.tray.showNotification("Ulæste notifikation på Naturbasen.dk", msg, 15000);
            if (res != 1) {
                const le = std.os.windows.kernel32.GetLastError();
                std.log.err("showNotification: {d}", .{le});
            }

            lastNotificationCount = if (ur == 9999) 0 else ur;
        }
    }
}

const registry = zigwin32.system.registry;
fn getBrowser() ![]const u8 {
    // Get user choise handler for HTTP
    var userChoiseKeyHndl: ?registry.HKEY = undefined;
    _ = registry.RegOpenKeyA(registry.HKEY_CURRENT_USER, "Software\\Microsoft\\Windows\\Shell\\Associations\\UrlAssociations\\http\\UserChoice", &userChoiseKeyHndl);

    var keyVal: []u8 = try state.allocator.alloc(u8, 1024);
    defer state.allocator.free(keyVal);

    var keyValLen: u32 = @truncate(keyVal.len);
    _ = registry.RegGetValueA(userChoiseKeyHndl, null, "ProgID", registry.RRF_RT_REG_SZ, null, keyVal.ptr, &keyValLen);

    // Get handler command
    const subKey = try std.fmt.allocPrintZ(state.allocator, "{s}\\shell\\open\\command", .{keyVal[0 .. keyValLen - 1]});
    defer state.allocator.free(subKey);

    userChoiseKeyHndl = undefined;
    _ = registry.RegOpenKeyA(registry.HKEY_CLASSES_ROOT, subKey, &userChoiseKeyHndl);

    keyValLen = @truncate(keyVal.len);
    _ = registry.RegGetValueA(userChoiseKeyHndl, null, null, registry.RRF_RT_REG_SZ, null, keyVal.ptr, &keyValLen);

    var fs = std.mem.indexOf(u8, keyVal[0 .. keyValLen - 1], ".exe") orelse keyValLen - 1;
    if (fs != keyValLen - 1) { // #dirtyhack
        fs += 4;
    }
    const cmd = try state.allocator.dupe(u8, keyVal[1..fs]);
    return cmd;
}

pub fn onQuitClicked(menu: *tray.Menu) void {
    menu.tray.exit();
}

pub fn onInfoClicked(_: *tray.Menu) void {
    const browser = getBrowser() catch |err| @panic(@errorName(err));
    defer state.allocator.free(browser);

    var childProc = std.ChildProcess.init(&[_][]const u8{ browser, "https://github.com/svc-user/nb-notifier" }, state.allocator);
    childProc.spawn() catch |err| {
        std.log.err("unable to spawn info page with error {s}\n", .{@errorName(err)});
    };
}

pub fn onMyNotificationsClicked(_: *tray.Menu) void {
    // https://www.naturbasen.dk/notifikationer
    const browser = getBrowser() catch |err| @panic(@errorName(err));
    defer state.allocator.free(browser);

    var childProc = std.ChildProcess.init(&[_][]const u8{ browser, "https://www.naturbasen.dk/notifikationer" }, state.allocator);
    childProc.spawn() catch |err| {
        std.log.err("unable to spawn notification page with error {s}\n", .{@errorName(err)});
    };
}

pub fn onPopupClicked(_: *tray.Tray) void {
    // https://www.naturbasen.dk/notifikationer
    const browser = getBrowser() catch |err| @panic(@errorName(err));
    defer state.allocator.free(browser);

    var childProc = std.ChildProcess.init(&[_][]const u8{ browser, "https://www.naturbasen.dk/notifikationer" }, state.allocator);
    childProc.spawn() catch |err| {
        std.log.err("unable to spawn notification page with error {s}\n", .{@errorName(err)});
    };
}

fn setUpTray() !void {
    // zig fmt: off
    var tray_inst = tray.Tray{ 
        .allocator = state.allocator, 
        .icon = try tray.createIconFromFile("icon.ico"), 
        .onPopupClick = onPopupClicked,
        .menu = &[_]tray.ConstMenu{
            .{
                .text = "nb-notifier",
                .disabled = true,
            },
            .{
                .text = "Info om programmet",
                .onClick = onInfoClicked,
            },
            .{
                .text = "Mine notifikationer",
                .onClick = onMyNotificationsClicked,
            },
            .{
                .text = "Luk",
                .onClick = onQuitClicked,
            },
        } };
    // zig fmt: on
    try tray_inst.init();
    defer tray_inst.deinit();
    state.tray = &tray_inst;
    tray_inst.run();
}
