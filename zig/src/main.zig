const std = @import("std");
const server = @import("./server.zig");

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = general_purpose_allocator.allocator();

    const address = try std.net.Address.parseIp("127.0.0.1", 4000);

    try server.MultiThreadedServer.run(allocator, address);
}
