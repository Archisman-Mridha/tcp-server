const server = @import("./server.zig");

pub fn main() !void {
    try server.MultiThreadedServer.run();
}
