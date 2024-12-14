const std = @import("std");
const compress = @import("compress.zig");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

pub const header = @import("./wad/header.zig");

pub fn Iterator(comptime ReaderType: type) type {
    return struct {
        pub const HeaderIterator = header.HeaderIterator(ReaderType);
        pub const Error = HeaderIterator.Error;

        const Entries = std.ArrayList(HeaderIterator.Entry);

        inner: HeaderIterator,
        entries: Entries,

        const Self = @This();

        pub fn init(allocator: Allocator, reader: ReaderType) (error{ OutOfMemory, UnknownVersion } || Error)!Self {
            const iter = try header.headerIterator(reader);
            return .{
                .inner = iter,
                .entries = try Entries.initCapacity(allocator, iter.entries_len),
            };
        }

        pub fn deinit(self: *Self) void {
            self.entries.deinit();
            self.* = undefined;
        }

        pub fn next(self: *Self) Error!?u32 {
            // for streaming!
            //  * read the iner iterator first nd build a sorted array (by offset)
            //  * then when we have all data in mem we can just stream it, and know what corresponds to what

            if (self.inner.index == 0) {
                try buildEntries(self);
            }

            assert(self.inner.index == self.inner.entries_len);

            if (self.entries.items.len == 0) {
                return null;
            }

            const entry = self.entries.getLast();
            self.entries.items.len -= 1;

            if (self.entries.getLastOrNull()) |e| {
                if (entry.offset == e.offset) {
                    std.debug.print("duplicate!!\n", .{});
                }
            }

            return entry.offset;
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
            // we should do in place sort
            std.sort.block(HeaderIterator.Entry, self.entries.items, Context{}, Context.lessThan);
        }
    };
}

pub fn iterator(allocator: Allocator, reader: anytype) !Iterator(@TypeOf(reader)) {
    return Iterator(@TypeOf(reader)).init(allocator, reader);
}
