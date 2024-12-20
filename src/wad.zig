const std = @import("std");
const compress = @import("compress.zig");
const version = @import("wad/version.zig");
const mem = std.mem;
const io = std.io;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

pub const header = @import("wad/header.zig");
pub const EntryType = @import("wad/toc.zig").EntryType;

pub const Options = struct {
    // If it is set to false, then it's callers responsability
    // for handling duplicates and `decompressor` will be set to null.
    handle_duplicates: bool = true,
    window_buffer: []u8,
};

pub fn StreamIterator(comptime ReaderType: type) type {
    return struct {
        allocator: Allocator,
        reader: ReaderType,

        inner: HeaderIterator,
        entries: Entries,

        zstd: compress.zstd.Decompressor(ReaderType),
        duplication_buffer: ?[]u8,

        unread_file_bytes: u32 = 0,
        available_file_bytes: u32 = 0,

        pub const HeaderIterator = header.HeaderIterator(ReaderType);

        pub const Entry = struct { // idea is simple pass in Entry(ReaderType) as its main reader and handle cached data its own way
            hash: u64,
            compressed_len: u32,
            decompressed_len: u32,

            decompressor: ?union(enum) {
                none: ReaderType,
                zstd: compress.zstd.Decompressor(ReaderType).Reader,
            },

            unread_bytes: *u32,
            available_bytes: *u32,

            cache: *compress.WindowBuffer,

            pub const Error = compress.zstd.Decompressor(ReaderType).Error;
            pub const Reader = io.Reader(Entry, Error, read);

            pub fn read(entry: Entry, buffer: []u8) Error!usize { // todo: assert if trying to read duplicate on invalid options
                if (entry.decompressor == null) @panic("reading from duplicate when option `handle_duplicates` is set to false");

                const dest = buffer[0..@min(buffer.len, entry.available_bytes.*)];
                if (dest.len == 0) return 0;

                var input_amt: u32 = 0;
                var output_amt: u32 = 0;
                var flag = false;

                const cached_bytes = entry.cache.unread_len;
                switch (entry.decompressor.?) {
                    .none => |stream| {
                        if (cached_bytes == 0) {
                            const amt: u32 = @intCast(try stream.read(dest));
                            output_amt += amt;
                            input_amt += amt;
                        } else {
                            const copy_len: u32 = @intCast(@min(cached_bytes, dest.len));
                            if (copy_len != dest.len) {
                                const amt: u32 = @intCast(try stream.read(dest[copy_len..]));
                                input_amt += amt;
                                output_amt += amt;
                            }
                            @memcpy(dest[0..copy_len], entry.cache.data[entry.cache.unread_index .. entry.cache.unread_index + copy_len]);

                            input_amt += copy_len;
                            output_amt += copy_len;

                            entry.cache.unread_index += copy_len;
                            entry.cache.unread_len -= copy_len;
                        }
                    },
                    .zstd => |zstd_stream| {
                        const amt: u32 = @intCast(try zstd_stream.read(dest));

                        output_amt += amt;
                        flag = amt == 0;

                        if (cached_bytes == 0) {
                            input_amt += @intCast(entry.cache.unread_index);
                        } else input_amt += @intCast(cached_bytes - entry.cache.unread_len);
                    },
                }

                entry.unread_bytes.* -= input_amt;
                entry.available_bytes.* -= output_amt;

                if (flag and entry.unread_bytes.* > 0) {
                    return read(entry, buffer);
                }

                return output_amt;
            }

            pub fn duplicate(entry: Entry) bool {
                return entry.decompressor == null;
            }

            pub fn reader(entry: Entry) Reader {
                return .{ .context = entry };
            }
        };

        const Self = @This();

        const Entries = std.ArrayListUnmanaged(HeaderIterator.Entry);

        pub fn init(allocator: Allocator, reader: ReaderType, options: Options) !Self {
            const iter = try header.headerIterator(reader);
            return .{
                .allocator = allocator,
                .reader = reader,
                .inner = iter,
                .entries = try Entries.initCapacity(allocator, iter.entries_len),
                .zstd = try compress.zstd.decompressor(allocator, reader, .{ .window_buffer = options.window_buffer }),
                .duplication_buffer = if (options.handle_duplicates) &[_]u8{} else null,
            };
        }

        pub fn deinit(self: *Self) void {
            self.entries.deinit(self.allocator);
            self.zstd.deinit();

            if (self.duplication_buffer) |duplication_buffer| {
                self.allocator.free(duplication_buffer);
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
                }
            }

            assert(self.inner.index == self.inner.entries_len);
            if (self.entries.items.len == 0) {
                return null;
            }

            const entry = self.entries.getLast();
            defer self.entries.items.len -= 1;

            if (self.entries.items.len != self.entries.capacity) {
                const prev_entry = self.entries.allocatedSlice()[self.entries.items.len];

                if (entry.offset == prev_entry.offset) {
                    assert(entry.compressed_len == prev_entry.compressed_len);
                    assert(entry.decompressed_len == prev_entry.decompressed_len);
                    assert(entry.type == prev_entry.type);

                    return .{
                        .hash = entry.hash,
                        .compressed_len = entry.compressed_len,
                        .decompressed_len = entry.decompressed_len,
                        .decompressor = null,
                        .unread_bytes = &self.unread_file_bytes,
                        .available_bytes = &self.available_file_bytes,
                        .cache = &self.zstd.buffer,
                    };
                }

                const skip = entry.offset - prev_entry.offset - prev_entry.compressed_len + self.unread_file_bytes;
                if (skip > 0) {
                    // todo: reset zstd state if just half of data was read or smth
                    const skip_cache = @min(self.zstd.unreadBytes(), skip);
                    const skip_raw = skip - skip_cache;

                    self.zstd.buffer.unread_index += skip_cache;
                    self.zstd.buffer.unread_len -= skip_cache;

                    if (skip_raw > 0) {
                        // @setCold(true);
                        try self.reader.skipBytes(skip_raw, .{});
                    }
                    self.unread_file_bytes = 0;
                }
            }

            self.unread_file_bytes = entry.compressed_len;
            self.available_file_bytes = entry.decompressed_len;
            self.zstd.completed = false;

            return .{
                .hash = entry.hash,
                .compressed_len = entry.compressed_len,
                .decompressed_len = entry.decompressed_len,
                .decompressor = switch (entry.type) {
                    .raw => .{ .none = self.reader },
                    .zstd, .zstd_multi => .{ .zstd = self.zstd.reader() },
                    else => @panic("not implemented"),
                },
                .unread_bytes = &self.unread_file_bytes,
                .available_bytes = &self.available_file_bytes,
                .cache = &self.zstd.buffer,
            };
        }

        fn peek(self: *Self) ?HeaderIterator.Entry {
            if (self.entries.items.len > 1) {
                return self.entries.items[self.entries.items.len - 2];
            }
            return null;
        }

        fn buildEntries(self: *Self) HeaderIterator.Error!void {
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

pub fn streamIterator(allocator: Allocator, reader: anytype, options: Options) !StreamIterator(@TypeOf(reader)) {
    return StreamIterator(@TypeOf(reader)).init(allocator, reader, options);
}
