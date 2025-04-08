const std = @import("std");
const net = std.net;
const posix = std.posix;
const Client = @import("./client.zig");

pub const MultiThreadedServer = struct {
    pub fn run(allocator: std.mem.Allocator, address: net.Address) !void {
        // NOTE : Zig's built-in thread pool can be memory-intensive. This is because it's generic
        // : each invocation can be given a different function to run and parameters to use. This
        // requires creating a closure around the arguments.
        // It was designed for long-running jobs, where the initial overhead was a relatively small
        // cost compared to the overall work being done.
        var thread_pool: std.Thread.Pool = undefined;
        try std.Thread.Pool.init(&thread_pool, .{ .allocator = allocator, .n_jobs = 64 });

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

            const client = Client.MultiThreadedServerClient{
                .connection = connection,
                .address = client_address,
            };

            try thread_pool.spawn(Client.MultiThreadedServer.handle, .{client});
        }
    }
};

pub const SingleThreadedServer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    clients: []Client.SingleThreadedServerClient,

    pollables: []posix.pollfd,
    pollable_existing_connections: []posix.pollfd,

    pub fn init(allocator: std.mem.Allocator, max_clients: usize) !Self {
        const pollables = try allocator.alloc(posix.pollfd, max_clients + 1);
        errdefer allocator.free(pollables);

        const clients = try allocator.alloc(Client.SingleThreadedServerClient, max_clients);
        errdefer allocator.free(clients);

        return Self{
            .allocator = allocator,

            .clients = clients,

            .pollables = pollables,
            .pollable_existing_connections = pollables[1..],
        };
    }

    pub fn deinit(self: *Self) !void {
        self.allocator.free(self.clients);
        self.allocator.free(self.pollables);
    }

    pub fn run(self: *Self, address: net.Address) !void {
        const connections =
            try posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, posix.IPPROTO.TCP);
        defer posix.close(connections);

        try posix.setsockopt(connections, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        try posix.bind(connections, &address.any, address.getOsSockLen());
        try posix.listen(connections, 128);

        // Using this, we can poll for new connections and accept them.
        self.pollables[0] = .{
            .fd = connections,
            .revents = 0,
            .events = posix.POLL.IN,
        };

        while (true) {
            _ = try posix.poll(self.pollables[0..(1 + self.clients)], -1);

            if (self.pollables[0].revents != 0) {}
        }
    }

    fn accept_client(self: *Self, connections: posix.socket_t) !void {
        while (true) {
            var client_address: net.Address = undefined;
            var client_address_len: posix.socklen_t = @sizeOf(net.Address);

            const connection = posix.accept(connections, &client_address.any, &client_address_len, posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
        }
    }

    fn remove_client(self: *Self, i: usize) !void {}
};
