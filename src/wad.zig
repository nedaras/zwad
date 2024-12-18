const std = @import("std");
const compress = @import("compress.zig");
const version = @import("wad/version.zig");
const mem = std.mem;
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
        reader: std.io.CountingReader(ReaderType),

        inner: HeaderIterator,
        entries: Entries,

        zstd: ?compress.zstd.Decompressor(Reader) = null,
        zstd_window_buffer: []u8,

        duplication_buffer: ?[]u8,

        pub const IterateError = HeaderIterator.Error;
        pub const Reader = std.io.CountingReader(ReaderType).Reader;

        pub const HeaderIterator = header.HeaderIterator(ReaderType);

        pub const Entry = struct { // idea is simple pass in Entry(ReaderType) as its main reader and handle cached data its own way
            hash: u64,
            compressed_len: u32,
            decompressed_len: u32,
            type: EntryType,
            duplicate: bool,

            handled_len: usize,
            handle: *Self,

            pub const Error = error{EndOfStream} || compress.zstd.Decompressor(ReaderType).Error;

            pub fn read(entry: Entry, buffer: []u8) Error!usize { // todo: assert if trying to read duplicate on invalid options
                if (entry.duplicate) @panic("reading from duplicate when option `handle_duplicates` is set to false");
                if (buffer.len == 0) return 0;

                var dest = buffer;
                if (std.debug.runtime_safety) { // this performs rly badly, cuz cache cant do stuff when we jumping in memory like that
                    // this is dumb we have handled_len
                    const bh = entry.handle.reader.bytes_read - if (entry.handle.zstd) |zstd| zstd.unreadBytes() else 0;
                    const end = entry.handled_len + entry.compressed_len;

                    if (bh == end) return error.EndOfStream;

                    const len = end - bh;
                    dest.len = @min(len, buffer.len);
                }

                return switch (entry.type) {
                    .raw => {
                        if (entry.handle.zstd == null) {
                            return entry.handle.reader.read(buffer);
                        }

                        const zstd = entry.handle.zstd.?;

                        const cached_slice = zstd.buffer.data[zstd.buffer.unread_index .. zstd.buffer.unread_index + zstd.buffer.unread_len];
                        const copy_len = @min(cached_slice.len, dest.len);

                        @memcpy(buffer[0..copy_len], cached_slice[0..copy_len]);

                        if (copy_len == cached_slice.len) {
                            entry.handle.zstd.?.buffer.unread_index = 0;
                            entry.handle.zstd.?.buffer.unread_len = 0;

                            return copy_len + try entry.handle.reader.read(dest[copy_len..]);
                        }

                        entry.handle.zstd.?.buffer.unread_index += copy_len;
                        entry.handle.zstd.?.buffer.unread_len -= copy_len;

                        return copy_len;
                    },
                    .zstd, .zstd_multi => entry.handle.zstd.?.read(dest), // should we handle multi?, by just reading again on zero,
                    .gzip, .link => @panic("not implemented"),
                };
            }
        };

        const Self = @This();

        const Entries = std.ArrayListUnmanaged(HeaderIterator.Entry);

        pub fn init(allocator: Allocator, reader: ReaderType, options: Options) (error{ OutOfMemory, UnknownVersion } || IterateError)!Self {
            const iter = try header.headerIterator(reader);
            return .{
                .allocator = allocator,
                .reader = std.io.countingReader(reader),
                .inner = iter,
                .entries = try Entries.initCapacity(allocator, iter.entries_len),
                .zstd_window_buffer = options.window_buffer,
                .duplication_buffer = if (options.handle_duplicates) &[_]u8{} else null,
            };
        }

        pub fn deinit(self: *Self) void {
            self.entries.deinit(self.allocator);

            if (self.duplication_buffer) |duplication_buffer| {
                self.allocator.free(duplication_buffer);
            }

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

            // skip bytes and handle duplicates

            if (self.zstd == null and (entry.type == .zstd or entry.type == .zstd_multi)) {
                self.zstd = try compress.zstd.decompressor(self.allocator, self.reader.reader(), .{
                    .window_buffer = self.zstd_window_buffer,
                });
            }

            const bytes_handled = self.reader.bytes_read - if (self.zstd) |zstd| zstd.unreadBytes() else 0;
            if (bytes_handled > entry.offset) { //dupplicate, todo: handle asserts with errors and mb it can be that the user just overread some data
                //std.debug.print("dupe, read: {d}, handled: {d}, offset: {d}, type: {s}\n", .{ self.reader.bytes_read, bytes_handled, entry.offset, @tagName(entry.type) });
                assert(self.entries.capacity > self.entries.items.len);
                const prev_entry = self.entries.allocatedSlice()[self.entries.items.len];
                assert(entry.type == prev_entry.type);
                assert(entry.offset == prev_entry.offset);
                assert(entry.compressed_len == prev_entry.compressed_len);
                assert(entry.decompressed_len == prev_entry.decompressed_len);

                return .{
                    .hash = entry.hash,
                    .compressed_len = entry.compressed_len,
                    .decompressed_len = entry.decompressed_len,
                    .type = entry.type,
                    .duplicate = true,
                    .handled_len = bytes_handled,
                    .handle = self,
                };
            }

            // what are we even skipping here?
            var skip = entry.offset - bytes_handled;
            //std.debug.print("before, read: {d}, handled: {d}, offset: {d}, skip: {d}, type: {s}\n", .{ self.reader.bytes_read, bytes_handled, entry.offset, skip, @tagName(entry.type) });
            if (self.zstd) |*zstd| {
                if (zstd.unreadBytes() >= skip) {
                    zstd.buffer.unread_index += skip;
                    zstd.buffer.unread_len -= skip;

                    skip = 0;
                } else {
                    skip -= zstd.unreadBytes();

                    zstd.buffer.unread_index = 0;
                    zstd.buffer.unread_len = 0;
                }
            }

            if (skip > 0) {
                try self.reader.reader().skipBytes(skip, .{});
            }

            self.zstd.?.completed = false;
            const bh = self.reader.bytes_read - if (self.zstd) |zstd| zstd.unreadBytes() else 0;
            //std.debug.print("after, read: {d}, handled: {d}, offset: {d}, skip: {d}, type: {s}\n", .{ self.reader.bytes_read, bh, entry.offset, skip, @tagName(entry.type) });
            return .{
                .hash = entry.hash,
                .compressed_len = entry.compressed_len,
                .decompressed_len = entry.decompressed_len,
                .type = entry.type,
                .duplicate = false,
                .handled_len = bh,
                .handle = self,
            };
            //  below is code we should implement in the future

            // when we will implement gzip we will need to update its unread bytes to same as zstd
            // and make them work together

            //switch (entry.type) {
            // if its raw we need first ti check if zstd is a thing, if it is mb its cached,
            // if not we can use windows_buffer dirrectly, is still to small need to allocate,
            // but if zstd is a thing on read we need to read it in two parts, cached data and then streaming data
            //.zstd, .zstd_multi => {
            //if (self.zstd == null) {
            //self.zstd = try compress.zstd.decompressor(self.allocator, self.reader.reader(), .{
            //.window_buffer = self.zstd_window_buffer,
            //});
            //}
            //},
            //else => @panic("not zstd"),
            //}

            // Why should we handle duplications, we can make it an options if we want to handle,
            // no in what we're doing we would be fine with just knowing that this curr entry is duplicate
            // when we will try to create an c abi, then ok it prob would be nice to have some default duplication handling
            //if (self.zstd) |*zstd| { // should be more like if zstd stream on use, we could do like if prev entry was zstd
            //const bytes_handled = self.reader.bytes_read - zstd.unreadBytes();
            //if (bytes_handled > entry.offset) {
            // TODO: assert that prev  compressed and decompressed lens are the same and types are the same

            //assert(zstd.buffer.unread_index >= entry.compressed_len);
            //
            //// we will go back in time
            //zstd.buffer.unread_index -= entry.compressed_len; // prob some overflow problems make so 2 -= 3 would be 0
            //zstd.buffer.unread_len += entry.compressed_len;
            //
            //return .{
            //.hash = entry.hash,
            //.compressed_len = entry.compressed_len,
            //.decompressed_len = entry.decompressed_len,
            //.duplicate = true,
            //.decompressor = .{ .zstd = self.zstd.?.reader() },
            //};
            //}
            //
            //const skip = entry.offset - bytes_handled; // we need to know what we're skipping here
            //if (zstd.unreadBytes() >= skip) {
            //zstd.buffer.unread_index += skip;
            //zstd.buffer.unread_len -= skip;
            //} else {
            //try self.reader.reader().skipBytes(skip - zstd.unreadBytes(), .{});
            //
            //zstd.buffer.unread_index = 0;
            //zstd.buffer.unread_len = 0;
            //}
            //
            //if (peek(self)) |next_entry| blk: {
            //if (entry.offset != next_entry.offset) break :blk;
            //// TODO: assert them types and sizes
            //if (zstd.unreadBytes() >= next_entry.compressed_len) break :blk; // it will be cached
            //
            //const cached_bytes = zstd.unreadBytes();
            //const missing_bytes = next_entry.compressed_len - cached_bytes;
            //
            //const cached_slice = zstd.buffer.data[zstd.buffer.unread_index .. zstd.buffer.unread_index + cached_bytes];
            //
            //if (zstd.buffer.data.len >= next_entry.compressed_len) {
            //mem.copyForwards(u8, zstd.buffer.data[0..cached_bytes], cached_slice);
            //const amt = try self.reader.reader().readAll(zstd.buffer.data[cached_bytes .. cached_bytes + missing_bytes]);
            //
            //if (amt != missing_bytes) return error.EndOfStream;
            //
            //zstd.buffer.unread_index = 0;
            //zstd.buffer.unread_len = next_entry.compressed_len;
            //
            //break :blk;
            //}
            //
            //assert(next_entry.compressed_len > self.duplication_buffer.len);
            //
            //const tmp = try self.allocator.alloc(u8, next_entry.compressed_len);
            //@memcpy(tmp[0..cached_bytes], cached_slice);
            //
            //self.allocator.free(self.duplication_buffer);
            //self.duplication_buffer = tmp;

            //                    const amt = try self.reader.reader().readAll(self.duplication_buffer[cached_bytes..]);
            //if (amt != missing_bytes) return error.EndOfStream;
            //
            //zstd.buffer.data = self.duplication_buffer;
            //
            //zstd.buffer.unread_index = 0;
            //zstd.buffer.unread_len = next_entry.compressed_len;
            //}
            //
            //return .{
            //.hash = entry.hash,
            //.compressed_len = entry.compressed_len,
            //.decompressed_len = entry.decompressed_len,
            //.duplicate = false,
            //.decompressor = .{ .zstd = self.zstd.?.reader() },
            //};
            //}
            //unreachable;
        }

        fn peek(self: *Self) ?HeaderIterator.Entry {
            if (self.entries.items.len > 1) {
                return self.entries.items[self.entries.items.len - 2];
            }
            return null;
        }

        fn buildEntries(self: *Self) IterateError!void {
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
