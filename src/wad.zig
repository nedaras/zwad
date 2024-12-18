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
        reader: std.io.CountingReader(ReaderType),

        inner: HeaderIterator,
        entries: Entries,

        zstd: ?compress.zstd.Decompressor(ParentReader) = null,
        zstd_window_buffer: []u8,

        duplication_buffer: ?[]u8,

        unread_file_bytes: u32 = 0,

        pub const IterateError = HeaderIterator.Error;

        pub const HeaderIterator = header.HeaderIterator(ReaderType);
        pub const ParentReader = io.CountingReader(ReaderType).Reader;

        pub const Entry = struct {
            hash: u64,
            compressed_len: u32,
            decompressed_len: u32,

            decompressor: ?union(enum) {
                none: ParentReader,
                zstd: compress.zstd.Decompressor(ParentReader).Reader,
            },

            unread_bytes: *u32,
            cached_buf: []u8,

            pub const Error = compress.zstd.Decompressor(io.CountingReader(ReaderType).Reader).Error;
            pub const Reader = io.Reader(Entry, Error, read);

            pub fn read(entry: Entry, buf: []u8) Error!usize { // return zero on ends
                std.debug.print("unread_bytes: {d}\n", .{entry.unread_bytes.*});
                if (entry.decompressor == null) @panic("reading from duplicate when option `handle_duplicates` is set to false");
                const dest = buf[0..@min(buf.len, entry.unread_bytes.*)];
                assert(entry.unread_bytes.* > 0);

                var amt: usize = 0;
                // todo: we need to modify the chaced buffer here
                switch (entry.decompressor.?) {
                    .none => |stream| {
                        const read_bytes = entry.compressed_len - entry.unread_bytes.*;
                        if (entry.cached_buf.len > read_bytes) {
                            const cached_slice = entry.cached_buf[read_bytes..];
                            const copy_len = @min(cached_slice.len, dest.len);

                            if (dest.len - copy_len > 0) {
                                amt += try stream.read(dest[copy_len..]);
                            }
                            // doing copy after, cuz it feels better not to change buffer when erroring
                            @memcpy(dest[0..copy_len], cached_slice[0..copy_len]);
                            amt += copy_len;
                        } else {
                            amt += try stream.read(dest);
                        }
                    },
                    .zstd => |zstd_stream| amt += try zstd_stream.read(dest),
                }
                entry.unread_bytes.* -= @intCast(amt); // problam we're having is that they're compressed and this line just makes no sence
                return amt;
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

            //if (self.zstd != null and prev(self) != null) {
            //const prev_entry = prev(self).?;
            //const read_bytes = prev_entry.compressed_len - self.unread_file_bytes;

            //const skip = @min(self.zstd.?.unreadBytes(), read_bytes);

            //self.zstd.?.buffer.unread_index += skip;
            //self.zstd.?.buffer.unread_len -= skip;

            //if (self.unread_file_bytes > skip) {
            //try self.reader.reader().skipBytes(self.unread_file_bytes - skip, .{});
            //}

            //self.unread_file_bytes = 0;
            //} else if (self.unread_file_bytes > 0) {
            //try self.reader.reader().skipBytes(self.unread_file_bytes, .{});
            //self.unread_file_bytes = 0;
            //}

            const entry = self.entries.getLast();
            defer self.entries.items.len -= 1;

            // prob initing zstd inside init function would be better and more efficent
            if (self.zstd == null and (entry.type == .zstd or entry.type == .zstd_multi)) {
                self.zstd = try compress.zstd.decompressor(self.allocator, self.reader.reader(), .{
                    .window_buffer = self.zstd_window_buffer,
                });
            }

            const bytes_handled = self.reader.bytes_read - if (self.zstd) |zstd| zstd.unreadBytes() else 0;
            if (bytes_handled > entry.offset) { //dupplicate, todo: handle asserts with errors and mb it can be that the user just overread some data
                std.debug.print("dupe, read: {d}, handled: {d}, offset: {d}, type: {s}\n", .{ self.reader.bytes_read, bytes_handled, entry.offset, @tagName(entry.type) });
                assert(self.entries.capacity > self.entries.items.len);
                const prev_entry = self.entries.allocatedSlice()[self.entries.items.len];
                assert(entry.type == prev_entry.type);
                assert(entry.offset == prev_entry.offset);
                assert(entry.compressed_len == prev_entry.compressed_len);
                assert(entry.decompressed_len == prev_entry.decompressed_len);

                self.unread_file_bytes = entry.compressed_len;
                const cached_buf = if (self.zstd) |zstd| zstd.buffer.data[zstd.buffer.unread_index .. zstd.buffer.unread_index + zstd.buffer.unread_len] else unreachable;
                return .{
                    .hash = entry.hash,
                    .compressed_len = entry.compressed_len,
                    .decompressed_len = entry.decompressed_len,
                    .decompressor = null,
                    .unread_bytes = &self.unread_file_bytes,
                    .cached_buf = cached_buf,
                };
            }

            // what are we even skipping here, is it some kinf of padding? probs.
            var skip = entry.offset - bytes_handled;
            std.debug.print("before, read: {d}, handled: {d}, offset: {d}, skip: {d}, type: {s}\n", .{ self.reader.bytes_read, bytes_handled, entry.offset, skip, @tagName(entry.type) });
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
            std.debug.print("after, read: {d}, handled: {d}, offset: {d}, skip: {d}, type: {s}\n", .{ self.reader.bytes_read, bh, entry.offset, skip, @tagName(entry.type) });
            self.unread_file_bytes = entry.compressed_len;
            const cached_buf = if (self.zstd) |zstd| zstd.buffer.data[zstd.buffer.unread_index .. zstd.buffer.unread_index + zstd.buffer.unread_len] else unreachable;
            return .{
                .hash = entry.hash,
                .compressed_len = entry.compressed_len,
                .decompressed_len = entry.decompressed_len,
                .decompressor = switch (entry.type) {
                    .raw => .{ .none = self.reader.reader() },
                    .zstd, .zstd_multi => .{ .zstd = self.zstd.?.reader() },
                    else => @panic("not implemented"),
                },
                .unread_bytes = &self.unread_file_bytes,
                .cached_buf = cached_buf,
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

        fn peek(self: *const Self) ?HeaderIterator.Entry {
            if (self.entries.items.len > 1) {
                return self.entries.items[self.entries.items.len - 2];
            }
            return null;
        }

        fn prev(self: *const Self) ?HeaderIterator.Entry {
            if (self.entries.capacity > self.entries.items.len) {
                return self.entries.allocatedSlice()[self.entries.items.len];
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
