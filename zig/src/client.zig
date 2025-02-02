const std = @import("std");
const posix = std.posix;
const net = std.net;
const ConnectionReader = @import("./reader.zig").ConnectionReader;

const CONNECTION_READ_TIMEOUT = posix.timeval{ .tv_sec = 2, .tv_usec = 500_000 };

pub const Client = struct {
    const Self = @This();

    connection: posix.socket_t,
    address: net.Address,

    pub fn handle(self: Self) !void {
        defer posix.close(self.connection);

        // posix.read( ) will block until the client sends something. Even if the client
        // disconnects, read will probably not return/error immediately like you might expect.
        // This is why, we set a read timeout.
        try std.posix.setsockopt(self.connection, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(CONNECTION_READ_TIMEOUT));

        // posix.write( ) is kinda non-blocking as well.
        //
        // A successful call to write should be interpreted as : the OS has made a copy of the
        // data and is aware that it needs to send it to the connection.
        // This incurs a significant cost if you're streaming gigabytes of data. And it isn't an
        // easy problem to solve. In non-trivial cases, we would expect the message to be
        // dynamically allocated or to be part of a re-usable buffer. If the OS didn't make a copy,
        // how would we know when it was safe to free the message or re-use the buffer? The recent
        // io_uring pattern has aimed to solve this.
        //
        // NOTE : Unlike flushing writes to a file, we cannot flush writes to a connection.
        //
        // Write timeout indicates the time limit within which the response data should be
        // completely written to the OS buffer.
        try std.posix.setsockopt(self.connection, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(CONNECTION_READ_TIMEOUT));

        var incoming_messages_buffer: [1024]u8 = undefined;

        var connection_reader = ConnectionReader{
            .connection = self.connection,
            .buffer = &incoming_messages_buffer,
        };

        while (true) {
            const message_data = try connection_reader.read_message_data();
            std.debug.print("Received message. Here is the message data : {any}\n", .{message_data});
        }
    }
};
