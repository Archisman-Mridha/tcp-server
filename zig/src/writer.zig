const std = @import("std");
const posix = std.posix;
const defaults = @import("./defaults.zig");

const ConnectionWriter = struct {
    pub fn write_message(connection: posix.socket_t, data: []const u8) !void {
        var message_header: [defaults.MESSAGE_HEADER_LEN]u8 = undefined;
        std.mem.writeInt(u32, &message_header, @intCast(data.len), .little);

        var vector = [2]posix.iovec_const{
            .{ .len = defaults.MESSAGE_HEADER_LEN, .base = &message_header },
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
};
