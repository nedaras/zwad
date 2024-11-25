const std = @import("std");
const zstandart = @import("compress/zstandart/zstandart.zig");
const io = std.io;
const assert = std.debug.assert;

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
                _ = self;
                _ = buf;
                @panic("no");
            }

            // todo: add like decompressed size man or mb zstd can provide it inside header or sum, we want to read it as much as possible
            pub fn readAll(self: *Self, buf: []u8) ![]u8 {
                var chunk_buf: [std.crypto.tls.max_ciphertext_len]u8 = undefined; // ZSTD_BLOCKSIZELOG_MAX is 1 << 17
                var out_buf = zstandart.zstd_out_buf{
                    .dst = buf.ptr,
                    .size = buf.len,
                    .pos = 0,
                };

                while (true) {
                    const len = try self.source.read(&chunk_buf);
                    var in_buf = zstandart.zstd_in_buf{
                        .src = &chunk_buf,
                        .size = len,
                        .pos = 0,
                    };

                    const amt = try zstandart.decompressStream(self.state, &in_buf, &out_buf);
                    if (amt == 0) break;
                }

                return buf[0..out_buf.pos];
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
