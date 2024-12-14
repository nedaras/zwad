const std = @import("std");
const zstandart = @import("compress/zstandart/zstandart.zig");
const io = std.io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

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

            const WindowBuffer = struct {
                data: []u8,
                unread_index: usize = 0,
                unread_len: usize = 0,
            };

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

            pub const ReadError = ReaderType.Error || error{
                MalformedFrame,
                MalformedBlock,
                Unexpected,
            };

            pub const Reader = io.Reader(*Self, ReadError, read);

            pub fn read(self: *Self, buffer: []u8) ReadError!usize {
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
