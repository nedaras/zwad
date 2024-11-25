const std = @import("std");
const io = std.io;
const zstandart = @import("compress/zstandart/zstandart.zig");

pub const zstd = struct {
    pub fn Decompressor(comptime ReaderType: type) type {
        return struct {
            source: ReaderType,
            state: *zstandart.DecompressStream,

            const Self = @This();

            pub fn init(a: ReaderType) Self {
                return .{
                    .source = a,
                    .state = zstandart.initDecompressStream() catch unreachable, // need to free
                };
            }

            pub const ReadError = ReaderType.Error || zstandart.DecompressStreamError;

            pub const Reader = io.Reader(*Self, ReadError, read);

            pub fn read(self: *Self, buf: []u8) ReadError!usize {
                var block_buf: [16 * 1024]u8 = undefined;
                const block_buf_len = try self.source.read(&block_buf);

                var in_buf = zstandart.zstd_in_buf{
                    .src = &block_buf,
                    .size = block_buf_len,
                    .pos = 0,
                };

                var out_buf = zstandart.zstd_out_buf{
                    .dst = buf.ptr,
                    .size = buf.len,
                    .pos = 0,
                };

                return try zstandart.decompressStream(self.state, &in_buf, &out_buf);
            }

            pub fn reader(file: *Self) Reader {
                return .{ .context = file };
            }
        };
    }

    pub fn decompressor(reader: anytype) Decompressor(@TypeOf(reader)) {
        return Decompressor(@TypeOf(reader)).init(reader);
    }
};
