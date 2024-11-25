const std = @import("std");
const zstandart = @import("compress/zstandart/zstandart.zig");
const io = std.io;
const assert = std.debug.assert;

pub const zstd = struct {
    pub fn Decompressor(comptime ReaderType: type) type {
        return struct {
            source: ReaderType,
            state: *zstandart.DecompressStream, // somewhere in this struct it should be some like size thing

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

            // todo: add like decompressed size man or mb zstd can provide it inside header or sum, we want to read it as least as possible
            pub fn readAll(self: *Self, buf: []u8) ![]u8 {
                var chunk_buf: [std.crypto.tls.max_ciphertext_len]u8 = undefined; // ZSTD_BLOCKSIZELOG_MAX is 1 << 17
                var out_buf = zstandart.zstd_out_buf{
                    .dst = buf.ptr,
                    .size = buf.len,
                    .pos = 0,
                };

                const content_size = try readSize(self, &out_buf);
                std.debug.print("content_size: {d}\n", .{content_size.?});

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

            fn readSize(self: *Self, out_buf: *zstandart.zstd_out_buf) !?usize {
                var header: [zstandart.MAX_FRAME_HEADER_BYTES]u8 = undefined;
                var len = try self.source.readAll(header[0..zstandart.MIN_FRAME_HEADER_BYTES]);
                if (len != zstandart.MIN_FRAME_HEADER_BYTES) return error.EndOfStream;

                const frame_size = zstandart.getFrameContentSize(header[0..len]) catch |err| switch (err) {
                    error.BufferTooSmall => {
                        len += try self.source.readAll(header[len..]);
                        if (len != header.len) return error.EndOfStream;

                        var in_buf = zstandart.zstd_in_buf{
                            .src = &header,
                            .size = len,
                            .pos = 0,
                        };

                        const frame_size = try zstandart.getFrameContentSize(&header);
                        _ = try zstandart.decompressStream(self.state, &in_buf, out_buf);
                        return frame_size;
                    },
                    error.SizeUnknown => null,
                    else => return err,
                };

                var in_buf = zstandart.zstd_in_buf{
                    .src = &header,
                    .size = len,
                    .pos = 0,
                };

                _ = try zstandart.decompressStream(self.state, &in_buf, out_buf);
                return frame_size;
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
