const std = @import("std");
const http = std.http;

pub const UserInfo = struct {
    Id: u32,
    userName: []const u8,
    Name: []const u8,
};

const NbError = error{ NoContent, CredsFileNotFound, ViewStateNotFound };
pub const NaturClient = struct {
    allocator: std.mem.Allocator,
    http_client: http.Client,
    headers: http.Headers,
    userInfo: *UserInfo,

    const url_base = "http://naturbasen.dk/";
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*NaturClient {
        var c = try allocator.create(NaturClient);
        c.allocator = allocator;
        c.http_client = http.Client{ .allocator = allocator };
        c.headers = http.Headers.init(allocator);
        c.userInfo = try allocator.create(UserInfo);

        try c.headers.append("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:123.0) Gecko/20100101 Firefox/123.0");

        return c;
    }

    fn request(self: *Self, url: []const u8, data: ?[]const u8) !std.http.Client.Request {
        const req_method = if (data == null) std.http.Method.GET else std.http.Method.POST;

        const full_url = try std.mem.concat(self.allocator, u8, &[_][]const u8{ url_base, url });
        defer self.allocator.free(full_url);

        var req = try self.http_client.request(req_method, try std.Uri.parse(full_url), self.headers, .{ .handle_redirects = false });

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

        return req;
    }

    fn get_content(self: *Self, req: *std.http.Client.Request) ![]u8 {
        const resp_buffer = try self.allocator.alloc(u8, (req.response.content_length orelse 0) * 5); // response is gzipped size. Multiply for large enough buffer.
        defer self.allocator.free(resp_buffer);

        const resp_size = try req.readAll(resp_buffer);
        const resp_body = try self.allocator.dupe(u8, resp_buffer[0..resp_size]);

        return resp_body;
    }

    fn get_field_value(self: *Self, body: []const u8, fieldId: []const u8) !?[]u8 {
        const searchString = try std.fmt.allocPrint(self.allocator, "id=\"{s}\"", .{fieldId});
        defer self.allocator.free(searchString);

        var lines = std.mem.tokenizeScalar(u8, body, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, searchString)) |idx| {
                if (std.mem.indexOf(u8, line[idx..], "value=\"")) |vidx| {
                    const start_idx = idx + vidx + 7; // idx + vidx + Length(value=")
                    const m_end_idx: ?usize = std.mem.indexOf(u8, line[start_idx..], "\"") orelse null;
                    if (m_end_idx) |end_idx| {
                        const fieldValue = try self.allocator.dupe(u8, line[start_idx .. start_idx + end_idx]);
                        return fieldValue;
                    }
                }
            }
        }
        return null;
    }

    fn getViewstate(self: *Self) ![2][]const u8 {
        var req = try self.request("login", null);
        defer req.deinit();

        const resp_body = try self.get_content(&req);
        defer self.allocator.free(resp_body);

        const m_viewState = try self.get_field_value(resp_body, "__VIEWSTATE");
        const m_viewStateGenerator = try self.get_field_value(resp_body, "__VIEWSTATEGENERATOR");

        if (m_viewState) |viewState| {
            if (m_viewStateGenerator) |viewStateGenerator| {
                return [_][]const u8{ viewState, viewStateGenerator };
            }
        }

        return NbError.ViewStateNotFound;
    }

    pub fn auth(self: *Self, username: []const u8, password: []const u8) !bool {

        // Get viewstate to be able to POST
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

        { // Send POST request to authenticate
            try self.headers.append("Content-Type", "application/x-www-form-urlencoded");
            defer _ = self.headers.delete("Content-Type");

            var req = try self.request("login", post_body);
            defer req.deinit();
            const login_body = try self.get_content(&req);
            defer self.allocator.free(login_body);

            // Extract authentication cookie
            const cookieValue = req.response.headers.getFirstValue("Set-Cookie");
            if (cookieValue) |cookie| {
                try self.headers.append("Cookie", cookie);
            } else {
                return false;
            }
        }

        { // Collect userInfo
            var req = try self.request("bruger/", null);
            defer req.deinit();
            const user_body = try self.get_content(&req);
            defer self.allocator.free(user_body);

            // Find user id
            const ruid = try self.get_field_value(user_body, "fogNBrugerID");
            if (ruid) |uid| {
                defer self.allocator.free(uid);
                self.userInfo.Id = try std.fmt.parseInt(u32, uid, 10);
            } else {
                return false;
            }

            // Find real name
            const rname = try self.get_field_value(user_body, "memberName");
            if (rname) |name| {
                defer self.allocator.free(name);
                self.userInfo.Name = try self.allocator.dupe(u8, name);
            } else {
                return false;
            }

            // Duplicate username
            self.userInfo.userName = try self.allocator.dupe(u8, username);
        }
        return true;
    }

    pub fn getUnreadCount(self: *Self, userID: u32) !u16 {
        try self.headers.append("Accept", "text/plain, */*");
        defer _ = self.headers.delete("Accept");

        const url = try std.fmt.allocPrint(self.allocator, "umbraco/api/notification/GetAntalUlaesteNotifikationer?brugerID={d}", .{userID});
        defer self.allocator.free(url);
        var req = try self.request(url, null);
        defer req.deinit();

        const content = try self.get_content(&req);
        defer self.allocator.free(content);

        const unread = try std.fmt.parseUnsigned(u16, content, 10);
        return unread;
    }

    pub fn deinit(self: *Self) !void {
        self.headers.deinit();
        self.allocator.free(self.userInfo.Name);
        self.allocator.free(self.userInfo.userName);

        self.allocator.destroy(self.userInfo);
        self.allocator.destroy(self);
    }
};

pub const UserLogin = struct {
    username: []u8,
    password: []u8,

    pub fn Load(alloc: std.mem.Allocator, filepath: []const u8) !UserLogin {
        const fp = std.fs.cwd().openFile(filepath, .{}) catch |err| {
            std.log.err("Kunne ikke finde {s}. Fejl: {s}\n", .{ filepath, @errorName(err) });
            return NbError.CredsFileNotFound;
        };
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
};
