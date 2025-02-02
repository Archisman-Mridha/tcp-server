const std = @import("std");
const net = std.net;
const posix = std.posix;
const Client = @import("./client.zig").Client;

pub const MultiThreadedServer = struct {
    pub fn run() !void {
        var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = general_purpose_allocator.allocator();

        // NOTE : Zig's built-in thread pool can be memory-intensive. This is because it's generic
        // : each invocation can be given a different function to run and parameters to use. This
        // requires creating a closure around the arguments.
        // It was designed for long-running jobs, where the initial overhead was a relatively small
        // cost compared to the overall work being done.
        var thread_pool: std.Thread.Pool = undefined;
        try std.Thread.Pool.init(&thread_pool, .{ .allocator = allocator, .n_jobs = 64 });

        const address = try net.Address.parseIp("127.0.0.1", 4000);

        const connections =
            try posix.socket(address.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
        defer posix.close(connections);

        // After we close a socket, the OS puts the socket in a TIME_WAIT state to deal with any
        // additional packets that might still be on their way. The length of time is configurable,
        // but as a general rule, you want to leave it as-is.
        //
        // The consequence of that is that, despite our program exiting, the address-port pair
        // 127.0.0.1:4000 remains in-use and thus cannot be re-used for a short time. So, if you take
        // this line out and stop and immediately start the program, you should get error.AddressInUse.
        //
        // With the REUSEADDR option set, as long as there isn't an active socket bound and listening
        // to the address, your bind should succeed.
        try posix.setsockopt(connections, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        // Bind the socket to the address.
        try posix.bind(connections, &address.any, address.getOsSockLen());

        try posix.listen(
            connections,

            // Number of connections we want the OS to queue, while it waits for us to accept
            // connections.
            // This is called backlog.
            128,
        );

        while (true) {
            var client_address: net.Address = undefined;
            var client_address_len: u32 = @sizeOf(net.Address);

            // accept( ) will block until there is an incoming connection.
            const connection = posix.accept(connections, &client_address.any, &client_address_len, 0) catch |err| {
                std.debug.print("Failed accepting connection : {}\n", .{err});
                continue;
            };

            std.debug.print("Accepted connection request from {}\n", .{client_address});

            const client = Client{
                .connection = connection,
                .address = client_address,
            };

            try thread_pool.spawn(Client.handle, .{client});
        }
    }
};
