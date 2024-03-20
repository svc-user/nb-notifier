const std = @import("std");
const http = std.http;

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

    pub fn auth(self: *Self, user: []const u8, password: []const u8) !bool {
        // const conn_node = try self.http_client.connect("naturbasen.dk", 80, .plain);

        var req = try self.http_client.request(.POST, try std.Uri.parse("http://naturbasen.dk/login"), self.headers, .{});
        defer req.deinit();

        const post_body = try std.fmt.allocPrint(self.allocator, "{{\"user\": \"{s}\", \"password\": \"{s}\"}}", .{ user, password });

        req.transfer_encoding = http.Client.RequestTransfer post_body.len;

        try req.writeAll(post_body);
        try req.start();
        try req.wait();

        const cont_len = req.response.content_length orelse 0;
        if (cont_len == 0) {
            return false;
        }

        const resp_buffer = try self.allocator.alloc(u8, cont_len);
        defer self.allocator.free(resp_buffer);
        _ = try req.readAll(resp_buffer);

        std.debug.print("{s}\n", .{resp_buffer});

        return true;
    }

    pub fn deinit(self: *Self) !void {
        self.allocator.destroy(self);
    }
};
