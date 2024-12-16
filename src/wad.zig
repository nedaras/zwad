const std = @import("std");
const compress = @import("compress.zig");
const version = @import("wad/version.zig");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

pub const header = @import("./wad/header.zig");

pub fn StreamIterator(comptime ReaderType: type) type {
    return struct {
        pub const Reader = std.io.CountingReader(ReaderType).Reader;

        pub const HeaderIterator = header.HeaderIterator(ReaderType);
        pub const Error = HeaderIterator.Error;

        const Entries = std.ArrayListUnmanaged(HeaderIterator.Entry);

        allocator: Allocator,
        reader: std.io.CountingReader(ReaderType),

        inner: HeaderIterator,
        entries: Entries,

        zstd: ?compress.zstd.Decompressor(Reader) = null,
        zstd_window_buffer: []u8,

        duplication_buffer: []u8 = &[_]u8{},

        pub const Entry = struct {
            hash: u64,
            compressed_len: u32,
            decompressed_len: u32,

            decompressor: union(enum) {
                none: Reader,
                zstd: compress.zstd.Decompressor(Reader).Reader,
            },

            // add read_func
        };

        const Self = @This();

        pub fn init(allocator: Allocator, reader: ReaderType, window_buf: []u8) (error{ OutOfMemory, UnknownVersion } || Error)!Self {
            const iter = try header.headerIterator(reader);
            return .{
                .allocator = allocator,
                .reader = std.io.countingReader(reader),
                .inner = iter,
                .entries = try Entries.initCapacity(allocator, iter.entries_len),
                .zstd_window_buffer = window_buf,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.duplication_buffer);
            self.entries.deinit(self.allocator);
            if (self.zstd) |*zstd| {
                zstd.deinit();
            }

            self.* = undefined;
        }

        pub fn next(self: *Self) !?Entry {
            if (self.inner.index == 0) {
                try buildEntries(self);

                if (self.entries.getLastOrNull()) |entry| {
                    const v = self.inner.version;
                    const off = version.sizeOfHeader(v) + version.sizeOfEntry(v) * self.inner.entries_len;
                    if (entry.offset != off) {
                        return error.InvalidFile;
                    }
                    self.reader.bytes_read = off;
                }
            }

            assert(self.inner.index == self.inner.entries_len);

            if (self.entries.items.len == 0) {
                return null;
            }

            const entry = self.entries.getLast();
            defer self.entries.items.len -= 1;

            // when we will implement gzip we will need to update its unread bytes to same as zstd
            // and make them work together

            switch (entry.type) {
                .zstd, .zstd_multi => {
                    if (self.zstd == null) {
                        self.zstd = try compress.zstd.decompressor(self.allocator, self.reader.reader(), .{
                            .window_buffer = self.zstd_window_buffer,
                        });
                    }
                },
                else => @panic("not zstd"),
            }

            if (self.zstd) |*zstd| { // should be more like if zstd stream on use, we could do like if prev entry was zstd
                const bytes_handled = self.reader.bytes_read - zstd.unreadBytes();
                if (bytes_handled > entry.offset) {
                    // TODO: assert that prev  compressed and decompressed lens are the same and types are the same

                    assert(zstd.buffer.unread_index >= entry.compressed_len);

                    // we will go back
                    zstd.buffer.unread_index -= entry.compressed_len; // prob some overflow problems make so 2 -= 3 would be 0
                    zstd.buffer.unread_len += entry.compressed_len;

                    return .{
                        .hash = entry.hash,
                        .compressed_len = entry.compressed_len,
                        .decompressed_len = entry.decompressed_len,
                        .decompressor = .{ .zstd = self.zstd.?.reader() },
                    };
                }

                const skip = entry.offset - bytes_handled; // we need to know what we're skipping here
                if (zstd.unreadBytes() >= skip) {
                    zstd.buffer.unread_index += skip;
                    zstd.buffer.unread_len -= skip;
                } else {
                    try self.reader.reader().skipBytes(skip - zstd.unreadBytes(), .{});

                    zstd.buffer.unread_index = 0;
                    zstd.buffer.unread_len = 0;
                }

                if (peek(self)) |next_entry| blk: {
                    if (entry.offset != next_entry.offset) break :blk;
                    // TODO: assert them types and sizes
                    if (zstd.unreadBytes() >= next_entry.compressed_len) break :blk; // it will be cached

                    const cached_bytes = zstd.unreadBytes();
                    const missing_bytes = next_entry.compressed_len - cached_bytes;

                    const cached_slice = zstd.buffer.data[zstd.buffer.unread_index .. zstd.buffer.unread_index + cached_bytes];

                    if (zstd.buffer.data.len >= next_entry.compressed_len) {
                        mem.copyForwards(u8, zstd.buffer.data[0..cached_bytes], cached_slice);
                        const amt = try self.reader.reader().readAll(zstd.buffer.data[cached_bytes .. cached_bytes + missing_bytes]);

                        if (amt != missing_bytes) return error.EndOfStream;

                        zstd.buffer.unread_index = 0;
                        zstd.buffer.unread_len = next_entry.compressed_len;

                        break :blk;
                    }

                    assert(next_entry.compressed_len > self.duplication_buffer.len);

                    const tmp = try self.allocator.alloc(u8, next_entry.compressed_len);
                    @memcpy(tmp[0..cached_bytes], cached_slice);

                    self.allocator.free(self.duplication_buffer);
                    self.duplication_buffer = tmp;

                    const amt = try self.reader.reader().readAll(self.duplication_buffer[cached_bytes..]);
                    if (amt != missing_bytes) return error.EndOfStream;

                    zstd.buffer.data = self.duplication_buffer;

                    zstd.buffer.unread_index = 0;
                    zstd.buffer.unread_len = next_entry.compressed_len;
                }

                return .{
                    .hash = entry.hash,
                    .compressed_len = entry.compressed_len,
                    .decompressed_len = entry.decompressed_len,
                    .decompressor = .{ .zstd = self.zstd.?.reader() },
                };
            }

            @panic("end");
        }

        fn peek(self: *Self) ?HeaderIterator.Entry {
            if (self.entries.items.len > 1) {
                return self.entries.items[self.entries.items.len - 2];
            }
            return null;
        }

        fn buildEntries(self: *Self) Error!void {
            while (try self.inner.next()) |entry| {
                const item = self.entries.addOneAssumeCapacity();
                item.* = entry;
            }

            const Context = struct {
                fn lessThan(_: @This(), a: HeaderIterator.Entry, b: HeaderIterator.Entry) bool {
                    return a.offset > b.offset;
                }
            };
            // we should do in place sort, so it would be O(log(n))
            std.sort.block(HeaderIterator.Entry, self.entries.items, Context{}, Context.lessThan);
        }
    };
}

pub fn streamIterator(allocator: Allocator, reader: anytype, window_buf: []u8) !StreamIterator(@TypeOf(reader)) {
    return StreamIterator(@TypeOf(reader)).init(allocator, reader, window_buf);
}
