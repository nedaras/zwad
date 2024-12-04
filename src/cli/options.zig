const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

pub const Option = enum {
    extract,
    list,
    file,
    hashes,
    unknown,
};

pub const OptionIterator = struct {
    buffer: []const u8,
    index: ?usize,

    pub fn next(self: *OptionIterator) ?Option { // ?struct { Option, ?[]const u8 }
        var start = self.index orelse return null;
        if (start == 0) {
            if (self.buffer.len < 2) {
                self.index = null;
                return null;
            }
            if (self.buffer[0] == '-' and self.buffer[1] == '-') {
                self.index = null;
                return getOptionFromName(self.buffer[2..]); // todo: handle key value pairs --file=bob
            }
            self.index.? += 1;
            start += 1;
        }

        if (start == self.buffer.len) {
            self.index = null;
            return null;
        }
        self.index.? += 1;

        return switch (self.buffer[start]) {
            't' => .list,
            'x' => .extract,
            'f' => .file,
            else => .unknown,
        };
    }
};

pub fn optionIterator(slice: []const u8) OptionIterator {
    assert(mem.count(u8, slice, " ") == 0);
    return .{
        .buffer = slice,
        .index = 0,
    };
}

fn getOptionFromName(name: []const u8) Option {
    if (mem.eql(u8, name, "list")) return .list;
    if (mem.eql(u8, name, "extract")) return .extract;
    if (mem.eql(u8, name, "get")) return .extract;
    if (mem.eql(u8, name, "file")) return .file;
    return .unknown;
}
