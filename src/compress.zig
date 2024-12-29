const std = @import("std");
const zstandart = @import("compress/zstandart/zstandart.zig");
const io = std.io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const WindowBuffer = struct {
    data: []u8,
    unread_index: usize = 0,
    unread_len: usize = 0,
};

pub const zstd = struct {
    pub const DecompressorOptions = struct {
        window_buffer: []u8,
    };

    pub fn Decompressor(comptime ReaderType: type) type {
        return struct {
            source: ReaderType,
            handle: *zstandart.DecompressStream,
            buffer: WindowBuffer,
            completed: bool = false,

            const Self = @This();

            pub fn init(allocator: Allocator, rt: ReaderType, options: DecompressorOptions) !Self {
                return .{
                    .source = rt,
                    .handle = try zstandart.initDecompressStream(allocator),
                    .buffer = .{
                        .data = options.window_buffer,
                    },
                };
            }

            pub fn deinit(self: *Self) void {
                zstandart.deinitDecompressStream(self.handle);
                self.* = undefined;
            }

            pub const Error = ReaderType.Error || error{
                MalformedFrame,
                MalformedBlock,
                Unexpected,
            };

            pub const Reader = io.Reader(*Self, Error, read);

            pub fn read(self: *Self, buffer: []u8) Error!usize {
                if (buffer.len == 0) return 0;
                if (self.completed) {
                    self.completed = false;
                    return 0;
                }

                var out_buf = zstandart.OutBuffer{
                    .dst = buffer.ptr,
                    .size = buffer.len,
                    .pos = 0,
                };

                if (self.unreadBytes() > 0) {
                    const unhanled = self.buffer.data[self.buffer.unread_index .. self.buffer.unread_index + self.buffer.unread_len];

                    var in_buf = zstandart.InBuffer{
                        .src = unhanled.ptr,
                        .size = unhanled.len,
                        .pos = 0,
                    };

                    defer {
                        self.buffer.unread_index += in_buf.pos;
                        self.buffer.unread_len -= in_buf.pos;
                    }

                    const amt = zstandart.decompressStream(self.handle, &in_buf, &out_buf) catch |err| switch (err) {
                        error.NoSpaceLeft => unreachable,
                        else => |e| return e,
                    };
                    if (amt == 0) self.completed = true;

                    return out_buf.pos;
                }

                while (out_buf.pos == 0) {
                    const data_len = try self.source.readAll(self.buffer.data);
                    assert(data_len > 0);
                    var in_buf = zstandart.InBuffer{
                        .src = self.buffer.data.ptr,
                        .size = data_len,
                        .pos = 0,
                    };

                    defer {
                        self.buffer.unread_index = in_buf.pos;
                        self.buffer.unread_len = data_len - in_buf.pos;
                    }

                    const amt = zstandart.decompressStream(self.handle, &in_buf, &out_buf) catch |err| switch (err) {
                        error.NoSpaceLeft => unreachable,
                        else => |e| return e,
                    };

                    if (amt == 0) {
                        self.completed = true;
                        break;
                    }

                    if (out_buf.pos == 0) {
                        assert(data_len == in_buf.pos);
                    }
                }

                return out_buf.pos;
            }

            pub fn reader(self: *Self) Reader {
                return .{ .context = self };
            }

            /// Resets state and updates a reader.
            pub fn setReader(self: *Self, rd: ReaderType) void {
                self.source = rd;
                reset(self);
            }

            //pub fn skipBytes(amt: usize) !void {

            //}

            pub fn reset(self: *Self) void {
                self.buffer.unread_index = 0;
                self.buffer.unread_len = 0;
                self.completed = false;
            }

            pub fn unreadBytes(self: Self) usize {
                return self.buffer.unread_len;
            }
        };
    }

    pub fn decompressor(allocator: Allocator, reader: anytype, options: DecompressorOptions) !Decompressor(@TypeOf(reader)) {
        return try Decompressor(@TypeOf(reader)).init(allocator, reader, options);
    }
};

// remaking zstd so it would not overread bytes
pub const btrstd = struct {
    pub const DecompressorOptions = struct {
        window_buffer: []u8,
        decompressed_size: usize,
        compressed_size: usize,
    };

    pub fn Decompressor(comptime ReaderType: type) type {
        return struct {
            source: ReaderType,
            inner: *zstandart.DecompressStream,

            buffer: std.RingBuffer,

            available_bytes: usize,
            unread_bytes: usize,

            pub const Error = ReaderType.Error || zstandart.DecompressStreamError;

            const Self = @This();

            pub fn init(allocator: Allocator, rt: ReaderType, options: DecompressorOptions) !Self {
                return .{
                    .source = rt,
                    .inner = try zstandart.initDecompressStream(allocator),
                    .available_bytes = options.decompressed_size,
                    .unread_bytes = options.compressed_size,
                    .buffer = .{
                        .data = options.window_buffer,
                        .write_index = 0,
                        .read_index = 0,
                    },
                };
            }

            pub fn deinit(self: *Self) void {
                zstandart.deinitDecompressStream(self.handle);
                self.* = undefined;
            }

            pub fn read(self: *Self, buffer: []u8) Error!usize {
                const dest = buffer[0..@min(buffer.len, self.available_bytes)];
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

                    // we need to decompress second part
                    _ = try zstandart.decompressStream(self.inner, &in_first_buf, &out_buf);
                    n += in_first_buf.pos;

                    if (slice.second.len > 0) {
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

                self.available_bytes -= out_buf.pos;
                return out_buf.pos;
            }

            /// Write unread bytes to a ring buffer
            fn fill(self: *Self) !void {
                const write_len = @min(self.buffer.data.len - len(self), self.unread_bytes);
                if (write_len == 0) return;

                const slice = self.buffer.sliceAt(self.buffer.write_index, write_len);

                const n1 = try self.source.read(slice.first);
                var n2: usize = 0;

                if (n1 == slice.first.len) {
                    n2 = try self.source.read(slice.second);
                }

                self.buffer.write_index = self.buffer.mask2(self.buffer.write_index + n1 + n2);
                self.unread_bytes -= n1 + n2;
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
};
