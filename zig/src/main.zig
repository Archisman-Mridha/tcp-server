const std = @import("std");
const net = std.net;
const posix = std.posix;

// The message header contains the byte length of the message data.
const MESSAGE_HEADER_LEN = 4;

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

    const connection_read_timeout = posix.timeval{ .tv_sec = 2, .tv_usec = 500_000 };

    var incoming_data: [128]u8 = undefined;
    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: u32 = @sizeOf(net.Address);

        // accept( ) will block until there is an incoming connection.
        const connection = posix.accept(connections, &client_address.any, &client_address_len, 0) catch |err| {
            std.debug.print("Failed accepting connection : {}\n", .{err});
            continue;
        };
        defer posix.close(connection);

        std.debug.print("Accepted connection request from {}\n", .{client_address});

        // posix.read( ) will block until the client sends something. Even if the client
        // disconnects, read will probably not return/error immediately like you might expect.
        // This is why, we set a read timeout.
        std.posix.setsockopt(connection, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(connection_read_timeout));

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
        std.posix.setsockopt(connection, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(connection_read_timeout));

        const bytes_read = read_message(connection, &incoming_data) catch |err| {
            std.debug.print("Failed reading incoming data : {}\n", .{err});
            continue;
        };
        if (bytes_read == 0) {
            continue;
        }

        write_message(connection, &incoming_data) catch |err| {
            std.debug.print("Failed writing to connection file : {}\n", .{err});
        };
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

fn read_message(connection: posix.socket_t, data: []const u8) !u32 {
    var message_header: [4]u8 = undefined;
    try read(connection, &message_header);

    const data_size = std.mem.readInt(u32, &message_header, .little);
    if (data_size > data.len) {
        return error.BufferTooSmall;
    }

    try read(connection, &data[0..data_size]);

    return data_size;
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
            if (i > data_vector.len) return;
        }
        data_vector[i].base += x;
        data_vector[i].len -= x;
    }
}

fn read(connection: posix.socket_t, data: []const u8) !void {
    var total_bytes_read: u32 = 0;
    while (total_bytes_read < data.len) {
        const bytes_read = try posix.read(connection, &data[total_bytes_read..]);

        if (bytes_read == 0) {
            return error.Closed;
        }

        total_bytes_read += bytes_read;
    }
}
