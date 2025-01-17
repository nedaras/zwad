const std = @import("std");
const compress = @import("compress.zig");
const version = @import("wad/version.zig");
const toc = @import("wad/toc.zig");
const mem = std.mem;
const io = std.io;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

pub const output = @import("wad/output.zig");
pub const header = @import("wad/header.zig");
pub const EntryType = @import("wad/toc.zig").EntryType;

// todo: after implementing create add pipeToFileSystem function

pub const max_file_size = output.max_file_size;
pub const max_archive_size = output.max_archive_size;

pub const max_entries_len = output.max_entries_len;

pub fn maxBlockSize(entries_len: u32) u64 {
    assert(max_entries_len > entries_len);
    return max_archive_size - @sizeOf(output.Header) - @sizeOf(output.Entry) * @as(u64, entries_len);
}

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

        pub const Entry = struct {
            hash: u64,
            compressed_size: u32,
            decompressed_size: u32,

            subchunk_len: u4,
            subchunk_index: u16,

            checksum: ?u64,
            decompressor: ?union(enum) {
                none: ReaderType,
                zstd: *compress.zstd.Decompressor(ReaderType),
            },

            unread_bytes: *u32,
            available_bytes: *u32,

            pub const Error = compress.zstd.Decompressor(ReaderType).Error;
            pub const Reader = io.Reader(Entry, Error, read);

            pub fn read(entry: Entry, buffer: []u8) Error!usize {
                if (entry.decompressor == null) @panic("reading from duplicate when option `handle_duplicates` is set to false");
                if (buffer.len == 0) return 0;

                const dest = buffer[0..@min(buffer.len, entry.available_bytes.*)];
                if (dest.len == 0) return 0;

                return switch (entry.decompressor.?) {
                    .none => |stream| {
                        const n: u32 = @intCast(try stream.read(dest));

                        entry.unread_bytes.* -= n;
                        entry.available_bytes.* -= n;

                        return n;
                    },
                    .zstd => |zstd| {
                        const n = try zstd.read(dest);

                        // todo: this is wrong, cuz idk need to check
                        entry.unread_bytes.* = @intCast(zstd.unread_bytes.?);
                        entry.available_bytes.* -= @intCast(n);

                        return n;
                    },
                };
            }

            pub fn duplicate(entry: Entry) bool {
                return entry.decompressor == null;
            }

            pub fn reader(entry: Entry) Reader {
                return .{ .context = entry };
            }
        };

        const Self = @This();

        const Entries = std.ArrayListUnmanaged(header.Entry);

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
                    const v = self.inner.ver;
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

                // todo: check if duplication can be verfied
                if (entry.offset == prev_entry.offset) {
                    if (entry.compressed_size != prev_entry.compressed_size) return error.InvalidFile;
                    if (entry.decompressed_size != prev_entry.decompressed_size) return error.InvalidFile;
                    if (entry.type != prev_entry.type) return error.InvalidFile;
                    if (entry.type != prev_entry.type) return error.InvalidFile;
                    if (entry.checksum != prev_entry.checksum) return error.InvalidFile;

                    return .{
                        .hash = entry.hash,
                        .compressed_size = entry.compressed_size,
                        .decompressed_size = entry.decompressed_size,
                        .subchunk_len = entry.subchunk_len,
                        .subchunk_index = entry.subchunk_index,
                        .checksum = entry.checksum,
                        .decompressor = null,
                        .unread_bytes = &self.unread_file_bytes,
                        .available_bytes = &self.available_file_bytes,
                    };
                }

                // todo: check for overflows
                const skip = entry.offset - prev_entry.offset - prev_entry.compressed_size + self.unread_file_bytes;
                if (skip > 0) {
                    try self.reader.skipBytes(skip, .{});
                }
            }

            self.unread_file_bytes = entry.compressed_size;
            self.available_file_bytes = entry.decompressed_size;

            if (entry.type == .zstd or entry.type == .zstd_multi) {
                self.zstd.unread_bytes = entry.compressed_size;
                self.zstd.available_bytes = entry.decompressed_size;
            }

            return .{
                .hash = entry.hash,
                .compressed_size = entry.compressed_size,
                .decompressed_size = entry.decompressed_size,
                .subchunk_len = entry.subchunk_len,
                .subchunk_index = entry.subchunk_index,
                .checksum = entry.checksum,
                .decompressor = switch (entry.type) {
                    .raw => .{ .none = self.reader },
                    .zstd, .zstd_multi => .{ .zstd = &self.zstd },
                    else => @panic("not implemented"),
                },
                .unread_bytes = &self.unread_file_bytes,
                .available_bytes = &self.available_file_bytes,
            };
        }

        fn peek(self: *Self) ?header.Entry {
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
                fn lessThan(_: void, a: header.Entry, b: header.Entry) bool {
                    return a.offset > b.offset;
                }
            };
            // we should do in place sort, so it would be O(log(n))
            std.sort.block(header.Entry, self.entries.items, {}, Context.lessThan);
        }
    };
}

pub fn streamIterator(allocator: Allocator, reader: anytype, options: Options) !StreamIterator(@TypeOf(reader)) {
    return StreamIterator(@TypeOf(reader)).init(allocator, reader, options);
}
