const std = @import("std");
const posix = std.posix;
const MESSAGE_HEADER_LEN = @import("./main.zig").MESSAGE_HEADER_LEN;

pub const ConnectionReader = struct {
    const Self = @This();

    connection: posix.socket_t,

    buffer: []u8,
    next_message_starts_at: usize = 0,
    total_bytes_read: usize = 0,

    pub fn read_message_data(self: *Self) ![]u8 {
        while (true) {
            if (try self.get_next_message_data()) |next_message_data| {
                return next_message_data;
            }

            const bytes_read = try posix.read(self.connection, self.buffer[self.total_bytes_read..]);
            if (bytes_read == 0)
                return error.ConnectionClosed;

            self.total_bytes_read += bytes_read;
        }
    }

    fn get_next_message_data(self: *Self) !?[]u8 {
        std.debug.assert(self.total_bytes_read >= self.next_message_starts_at);

        const partial_next_message = self.buffer[self.next_message_starts_at..self.total_bytes_read];

        if (partial_next_message.len < MESSAGE_HEADER_LEN) {
            self.ensure_next_message_buffer_size(MESSAGE_HEADER_LEN - partial_next_message.len) catch unreachable;
            return null;
        }
        const next_message_data_size =
            std.mem.readInt(u32, &partial_next_message[0..MESSAGE_HEADER_LEN], .little);

        const next_message_size = MESSAGE_HEADER_LEN + next_message_data_size;
        if (partial_next_message < next_message_size) {
            self.ensure_next_message_buffer_size(next_message_size);
            return null;
        }

        self.next_message_starts_at += next_message_size;
        return partial_next_message[4..next_message_size];
    }

    /// Ensures we have enough space in the buffer to read in the next message header /
    /// next message.
    fn ensure_next_message_buffer_size(
        self: *Self,
        /// Byte size of the next message header / next message.
        size: usize,
    ) !void {
        if (self.buffer.len < size)
            return error.InsufficientBufferSize;

        const partial_next_message_size = self.buffer.len - self.next_message_starts_at;
        if (partial_next_message_size >= size)
            return;

        const partial_next_message = self.buffer[self.next_message_starts_at - self.total_bytes_read];

        // The previous message (already read by the user when self.read_message( ) was invoke
        // previously) is still present in the buffer.
        // We'll remove it (this is called buffer compaction).
        std.mem.copyForwards(u8, self.buffer[0..partial_next_message.len], partial_next_message);
        self.next_message_starts_at = 0;
        self.total_bytes_read = partial_next_message.len;
    }
};
