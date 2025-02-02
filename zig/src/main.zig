const std = @import("std");
const net = std.net;
const posix = std.posix;

const Client = @import("./client.zig").Client;

// The message header contains the byte length of the message data.
pub const MESSAGE_HEADER_LEN = 4;

pub fn main() !void {
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

        const thread_handler =
            try std.Thread.spawn(.{}, Client.handle, .{client});
        //
        // Release the obligation of the caller to call join( ) and have the thread clean up its
        // own resources on completion.
        thread_handler.detach();
    }
}

fn write_message(connection: posix.socket_t, data: []const u8) !void {
    var message_header: [MESSAGE_HEADER_LEN]u8 = undefined;
    std.mem.writeInt(u32, &message_header, @intCast(data.len), .little);

    var vector = [2]posix.iovec_const{
        .{ .len = MESSAGE_HEADER_LEN, .base = &message_header },
        .{ .len = data.len, .base = &data },
    };

    try write_vector(connection, &vector);
}

fn write_vector(connection: posix.socket_t, data_vector: []posix.iovec_const) !void {
    var i: usize = 0;
    while (true) {
        // Writes to the connection file descriptor. Retries when interrupted by a signal.
        // Returns the number of bytes written.
        //
        // Since syscalls have overhead, and this is a critical path, we use writev (port of the
        // vectored I/O) instead of write, trying to do the job using the least possible number of
        // syscalls.
        //
        // NOTE : a successful write() may transfer fewer than count bytes.  Such partial  writes
        // can occur  for  various reasons. For example :
        //
        //      (1) there was insufficient space on the disk device to write all of the requested
        //          bytes
        //
        //      (2) a blocked write() to a socket, pipe, or similar was interrupted by a signal
        //          handler after it had transferred some, but before it had transferred all of the
        //          requested bytes.
        //
        // In the event of a partial write, the caller can  make another  write() call to transfer
        // the remaining bytes.  The subsequent call will either transfer further bytes or may
        // result in an error (e.g., if the disk is now full).
        //
        // Also, Linux has a limit on how many bytes may be transferred in one write() call, which
        // is 0x7ffff000 on both 64-bit and 32-bit systems. This is due to using a signed C int as
        // the return value, as well as stuffing the errno codes into the last 4096 values.
        const bytes_written = try posix.writev(connection, data_vector[i..]);

        var x = bytes_written;
        while (x >= data_vector[i].len) {
            x -= data_vector[i].len;

            i += 1;
            if (i > data_vector.len)
                return;
        }
        data_vector[i].base += x;
        data_vector[i].len -= x;
    }
}
