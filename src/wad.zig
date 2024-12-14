const std = @import("std");
const compress = @import("compress.zig");
const version = @import("wad/version.zig");
const mem = std.mem;
const zstd = compress.zstd;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

pub const header = @import("./wad/header.zig");

pub fn StreamIterator(comptime ReaderType: type) type {
    return struct {
        pub const Reader = std.io.CountingReader(ReaderType).Reader;

        pub const HeaderIterator = header.HeaderIterator(ReaderType);
        pub const Error = HeaderIterator.Error;

        const Entries = std.ArrayList(HeaderIterator.Entry);

        reader: std.io.CountingReader(ReaderType),

        inner: HeaderIterator,
        entries: Entries,

        zstd: ?zstd.Decompressor(Reader) = null,
        zstd_window_buffer: []u8,

        pub const Entry = struct {
            hash: u64,
            compressed_len: u32,
            decompressed_len: u32,

            decompressor: union(enum) {
                none: Reader,
                zstd: zstd.Decompressor(Reader).Reader,
            },

            // add read_func
        };

        const Self = @This();

        pub fn init(allocator: Allocator, reader: ReaderType, window_buf: []u8) (error{ OutOfMemory, UnknownVersion } || Error)!Self {
            const iter = try header.headerIterator(reader);
            return .{
                .reader = std.io.countingReader(reader),
                .inner = iter,
                .entries = try Entries.initCapacity(allocator, iter.entries_len),
                .zstd_window_buffer = window_buf,
            };
        }

        pub fn deinit(self: *Self) void {
            self.entries.deinit();
            if (self.zstd) |*z| {
                z.deinit();
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

            const bytes_handled = self.reader.bytes_read - (if (self.zstd) |z| z.unreadBytes() else 0);
            if (bytes_handled > entry.offset) {
                if (entry.type != .zstd and entry.type != .zstd_multi) {
                    @panic("duplication cant be handled, not zstd");
                }
                if (self.zstd) |*z| {
                    const cached_len = z.buffer.unread_index;
                    if (entry.compressed_len > cached_len) {
                        @panic("duplication cant be handled, not cached");
                    }

                    z.buffer.unread_index -= entry.compressed_len;
                    z.buffer.unread_len += entry.compressed_len;

                    std.debug.print("handling dupe\n", .{});

                    return .{
                        .hash = entry.hash,
                        .compressed_len = entry.compressed_len,
                        .decompressed_len = entry.decompressed_len,
                        .decompressor = .{ .zstd = self.zstd.?.reader() },
                    };
                } else unreachable;
                // duplicate
            }

            var skip = entry.offset - bytes_handled; // we need to understand what we're skipping
            if (self.zstd) |*z| {
                if (z.unreadBytes() > skip) {
                    z.buffer.unread_index += skip;
                    z.buffer.unread_len -= skip;
                    skip = 0;
                } else {
                    const amt = z.buffer.unread_len - z.buffer.unread_index;
                    z.buffer.unread_index = z.buffer.unread_len;
                    skip -= amt;
                }
            }
            try self.reader.reader().skipBytes(skip, .{});

            std.debug.print("nread: {d}, hash: {x}, offset: {d}, compressed_len: {d}\n", .{ self.reader.bytes_read, entry.hash, entry.offset, entry.compressed_len });

            if ((entry.type == .zstd or entry.type == .zstd_multi) and self.zstd == null) {
                self.zstd = try zstd.decompressor(self.entries.allocator, self.reader.reader(), .{ .window_buffer = self.zstd_window_buffer });
            }

            if (self.entries.items.len > 1) {
                const n = self.entries.items[self.entries.items.len - 2];
                if (entry.offset == n.offset) {
                    // we need to find out if its going to be cached, if it is we will not allocate shit
                    // TODO: check if curr type is same with prev type
                    std.debug.print("there will be a duplicate\n", .{});
                    if (n.type == .zstd or n.type == .zstd_multi) {
                        if (n.compressed_len > self.zstd.?.unreadBytes()) {
                            std.debug.print("duplication will not be cached\n", .{});
                            // do smth
                        }
                    } else {
                        std.debug.print("duplication will not be cached\n", .{});
                    }
                }
            }

            return .{
                .hash = entry.hash,
                .compressed_len = entry.compressed_len,
                .decompressed_len = entry.decompressed_len,
                .decompressor = switch (entry.type) {
                    .raw => @panic("raw"),
                    .link => @panic("link"),
                    .gzip => @panic("gzip"),
                    .zstd, .zstd_multi => .{ .zstd = self.zstd.?.reader() },
                },
            };
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
