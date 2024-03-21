const std = @import("std");
const http = std.http;

const HttpResponse = struct {};

pub const NaturClient = struct {
    allocator: std.mem.Allocator,
    http_client: http.Client,
    headers: http.Headers,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*NaturClient {
        var c = try allocator.create(NaturClient);
        c.allocator = allocator;
        c.http_client = http.Client{ .allocator = allocator };
        c.headers = http.Headers.init(allocator);

        return c;
    }

    const NbError = error{NoContent};
    fn request(self: *Self, url: []const u8, data: ?[]const u8) !std.http.Client.Request {
        const req_method = if (data == null) std.http.Method.GET else std.http.Method.POST;
        var req = try self.http_client.request(req_method, try std.Uri.parse(url), self.headers, .{ .handle_redirects = false });
        //defer req.deinit();

        if (data) |post_body|
            req.transfer_encoding = .{ .content_length = post_body.len };

        try req.start();

        if (data) |post_body|
            try req.writeAll(post_body);

        try req.finish();
        try req.wait();

        const cont_len = req.response.content_length orelse 0;
        if (cont_len == 0) {
            return NbError.NoContent;
        }

        // const resp_buffer = try self.allocator.alloc(u8, cont_len * 5); // response is gzipped size. Multiply for large enough buffer.
        // defer self.allocator.free(resp_buffer);

        // const resp_size = try req.readAll(resp_buffer);

        // const resp = try self.allocator.dupe(u8, resp_buffer[0..resp_size]);
        return req;
    }

    fn getViewstate(self: *Self) ![2][]const u8 {
        var req = try self.request("http://naturbasen.dk/login", null);
        defer req.deinit();

        const resp_buffer = try self.allocator.alloc(u8, (req.response.content_length orelse 0) * 5); // response is gzipped size. Multiply for large enough buffer.
        defer self.allocator.free(resp_buffer);

        const resp_size = try req.readAll(resp_buffer);
        const get_resp = resp_buffer[0..resp_size];

        // Find __VIEWSTATE
        const vs_start: usize = std.mem.indexOf(u8, get_resp, "id=\"__VIEWSTATE\" value=\"").? + 24; // is the length of the search string
        const vs_end = std.mem.indexOf(u8, get_resp[vs_start..], "\"").? + vs_start;

        const viewState = try self.allocator.dupe(u8, get_resp[vs_start..vs_end]);
        std.debug.print("got viewstate: __VIEWSTATE=\"{s}\"\n", .{viewState});

        // Find __VIEWSTATEGENERATOR
        const vsg_start: usize = std.mem.indexOf(u8, get_resp, "id=\"__VIEWSTATEGENERATOR\" value=\"").? + 33; // is the length of the search string
        const vsg_end = std.mem.indexOf(u8, get_resp[vsg_start..], "\"").? + vsg_start;

        const viewStateGenerator = try self.allocator.dupe(u8, get_resp[vsg_start..vsg_end]);
        std.debug.print("got viewStateGenerator: __VIEWSTATEGENERATOR=\"{s}\"\n", .{viewStateGenerator});

        return [_][]const u8{ viewState, viewStateGenerator };
    }

    pub fn auth(self: *Self, username: []const u8, password: []const u8) !bool {
        const viewstateInfo = try self.getViewstate();
        defer {
            self.allocator.free(viewstateInfo[0]);
            self.allocator.free(viewstateInfo[1]);
        }

        const escaped_viewstate = try std.Uri.escapeString(self.allocator, viewstateInfo[0]);
        defer self.allocator.free(escaped_viewstate);

        const post_body = try std.fmt.allocPrint(self.allocator, "ctl00$login_1$BrugernavnTextBox={s}" ++
            "&ctl00$login_1$PasswordTextBox={s}" ++
            "&ctl00$login_1$HuskMigCheckBox=on" ++
            "&__VIEWSTATE={s}" ++
            "&ctl00$login_1$Button1=Log på" ++
            "&__VIEWSTATEGENERATOR={s}", .{ username, password, escaped_viewstate, viewstateInfo[1] });
        defer self.allocator.free(post_body);

        try self.headers.append("Content-Type", "application/x-www-form-urlencoded");
        defer _ = self.headers.delete("Content-Type");

        var req = try self.request("http://naturbasen.dk/login", post_body);
        defer req.deinit();

        std.debug.print("{any}\n", .{req.response.headers});

        return true;
    }

    pub fn deinit(self: *Self) !void {
        self.headers.deinit();
        self.allocator.destroy(self);
    }
};

pub const UserLogin = struct {
    username: []u8,
    password: []u8,

    pub fn Load(alloc: std.mem.Allocator, filepath: []const u8) !UserLogin {
        const fp = try std.fs.cwd().openFile(filepath, .{});
        defer fp.close();

        var buff = try alloc.alloc(u8, 1024);
        defer alloc.free(buff);

        const fs = try fp.readAll(buff);
        var parsed = try std.json.parseFromSlice(UserLogin, alloc, buff[0..fs], .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        return UserLogin{
            .username = try alloc.dupe(u8, @field(parsed.value, "username")),
            .password = try alloc.dupe(u8, @field(parsed.value, "password")),
        };
    }

    // pub fn deinit(self: *UserLogin) void {
    //     self.allocator.free(self.username);
    //     self.allocator.free(self.password);
    //     self.allocator.destroy(self);
    // }
};
