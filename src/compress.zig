const std = @import("std");
const zstandart = @import("compress/zstandart/zstandart.zig");
const io = std.io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const zstd = struct {
    pub const DecompressorOptions = struct {
        window_buffer: []u8,
    };

    pub const CompressOptions = struct {
        level: zstandart.Level = .level_2,
        window_buffer: []u8,
    };

    pub fn Decompressor(comptime ReaderType: type) type {
        return struct {
            source: ReaderType,
            inner: *zstandart.DecompressStream,

            // todo: check asm if mask and mask2 functions uses modules we need to our own ring buffer
            buffer: std.RingBuffer,

            available_bytes: ?usize, // we should get this our self using zstd
            unread_bytes: ?usize, // this idk should be set by an user, or mb zstd can give it back

            pub const Error = ReaderType.Error || zstandart.DecompressStreamError;
            pub const Reader = io.Reader(*Self, Error, read);

            const Self = @This();

            pub fn init(allocator: Allocator, rt: ReaderType, options: DecompressorOptions) !Self {
                return .{
                    .source = rt,
                    .inner = try zstandart.initDecompressStream(allocator),
                    .available_bytes = null,
                    .unread_bytes = null,
                    .buffer = .{
                        .data = options.window_buffer,
                        .write_index = 0,
                        .read_index = 0,
                    },
                };
            }

            pub fn deinit(self: *Self) void {
                zstandart.deinitDecompressStream(self.inner);
                self.* = undefined;
            }

            pub fn read(self: *Self, buffer: []u8) Error!usize {
                const dest = buffer[0..@min(buffer.len, self.available_bytes.?)];
                if (dest.len == 0) return 0;

                var out_buf = zstandart.OutBuffer{
                    .dst = dest.ptr,
                    .size = dest.len,
                    .pos = 0,
                };

                while (out_buf.pos == 0) {
                    try fill(self);
                    const slice = self.buffer.sliceAt(self.buffer.read_index, len(self));
                    var n: usize = 0;
                    var in_first_buf = zstandart.InBuffer{
                        .src = slice.first.ptr,
                        .size = slice.first.len,
                        .pos = 0,
                    };

                    _ = try zstandart.decompressStream(self.inner, &in_first_buf, &out_buf);
                    n += in_first_buf.pos;

                    const first_part_handled = in_first_buf.pos == in_first_buf.size;
                    if (first_part_handled and slice.second.len > 0) {
                        var in_second_buf = zstandart.InBuffer{
                            .src = slice.second.ptr,
                            .size = slice.second.len,
                            .pos = 0,
                        };
                        _ = try zstandart.decompressStream(self.inner, &in_second_buf, &out_buf);
                        n += in_second_buf.pos;
                    }

                    self.buffer.read_index = self.buffer.mask2(self.buffer.read_index + n);
                }

                self.available_bytes.? -= out_buf.pos;
                return out_buf.pos;
            }

            pub fn reader(self: *Self) Reader {
                return .{ .context = self };
            }

            /// Write unread bytes to a ring buffer
            fn fill(self: *Self) !void {
                const write_len = @min(self.buffer.data.len - len(self), self.unread_bytes.?);
                if (write_len == 0) return;

                const slice = self.buffer.sliceAt(self.buffer.write_index, write_len);

                const n1 = try self.source.read(slice.first);
                var n2: usize = 0;

                if (n1 == slice.first.len) {
                    n2 = try self.source.read(slice.second);
                }

                self.buffer.write_index = self.buffer.mask2(self.buffer.write_index + n1 + n2);
                self.unread_bytes.? -= n1 + n2;
            }

            // idk why ring buffers len() function returns [0; buf_len * 2)
            fn len(self: *const Self) usize {
                if (self.buffer.isFull()) return self.buffer.data.len;

                const mri = self.buffer.mask(self.buffer.read_index);
                const mwi = self.buffer.mask(self.buffer.write_index);

                const wrap_offset = self.buffer.data.len * @intFromBool(mwi < mri);
                const adjusted_write_index = mwi + wrap_offset;
                return adjusted_write_index - mri;
            }
        };
    }

    pub fn decompressor(allocator: Allocator, reader: anytype, options: DecompressorOptions) !Decompressor(@TypeOf(reader)) {
        return try Decompressor(@TypeOf(reader)).init(allocator, reader, options);
    }

    pub fn Compressor(comptime WriterType: type) type {
        return struct {
            source: WriterType,
            inner: *zstandart.CompressStream,

            buffer: []u8,

            unread_bytes: usize = 0,

            const Self = @This();

            pub fn init(allocator: Allocator, wt: WriterType, options: CompressOptions) !Self {
                return .{
                    .source = wt,
                    .inner = try zstandart.initCompressStream(allocator),
                    .buffer = options.window_buffer,
                };
            }

            pub fn deinit(self: *Self) void {
                zstandart.deinitCompressStream(self.inner);
                self.* = undefined;
            }

            // tood: ensure that zstd reads whole input, write should compress all the input datacw
            pub fn write(self: *Self, input: []const u8) !usize {
                var in_buf = zstandart.InBuffer{
                    .src = input.ptr,
                    .size = @min(input.len, self.unread_bytes),
                    .pos = 0,
                };

                var out_buf = zstandart.OutBuffer{
                    .dst = self.buffer.ptr,
                    .size = self.buffer.len,
                    .pos = 0,
                };

                var n: usize = 0;
                while (in_buf.pos != in_buf.size) {
                    defer out_buf.pos = 0;

                    _ = try zstandart.compressStream(self.inner, &in_buf, &out_buf);

                    if (out_buf.pos > 0) {
                        try self.source.writeAll(self.buffer[0..out_buf.pos]);

                        n += out_buf.pos;
                    }
                }

                assert(out_buf.pos == 0);
                if (self.unread_bytes == in_buf.pos) {
                    assert(try zstandart.endStream(self.inner, &out_buf) == 0);
                }

                try self.source.writeAll(self.buffer[0..out_buf.pos]);
                self.unread_bytes -= in_buf.pos;

                return n + out_buf.pos;
            }

            pub inline fn setFrameSize(self: *Self, n: usize) void {
                assert(self.unread_bytes == 0);
                zstandart.setPladgedSize(self.inner, n) catch unreachable;
                self.unread_bytes = n;
            }
        };
    }

    pub fn compressor(allocator: Allocator, writer: anytype, options: CompressOptions) !Compressor(@TypeOf(writer)) {
        return try Compressor(@TypeOf(writer)).init(allocator, writer, options);
    }
};
