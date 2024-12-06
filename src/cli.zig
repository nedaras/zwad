const std = @import("std");
const cli = @import("cli/options.zig");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

pub const help = @embedFile("cli/help.cli");

pub const Diagnostics = struct {
    allocator: Allocator,
    errors: std.ArrayListUnmanaged(Error) = .{},

    pub const Error = union(enum) {
        unknown_option: struct {
            option: []const u8,
        },
        unexpected_argument: struct {
            option: []const u8,
        },
        empty_argument: struct {
            option: []const u8,
        },
    };

    pub fn deinit(self: *Diagnostics) void {
        self.errors.deinit(self.allocator);
    }
};

pub const Arguments = struct {
    allocator: Allocator,
    iter: std.process.ArgIterator,

    options: struct {
        extract: bool = false,
        list: bool = false,
        file: ?[]const u8 = null,
        hashes: ?[]const u8 = null,
    } = .{},

    files: []const []const u8 = &.{},

    pub fn deinit(self: *Arguments) void {
        self.iter.deinit();
        self.allocator.free(self.files);
    }
};

pub const ParseOptions = struct {
    diagnostics: ?*Diagnostics = null,
};

pub const ParseArgumentsError = error{
    OutOfMemory,
    UnknownOption,
    UnexpectedArgument,
    EmptyArgument,
};

pub fn parseArguments(allocator: Allocator, options: ParseOptions) ParseArgumentsError!Arguments {
    var iter = try std.process.argsWithAllocator(allocator);
    errdefer iter.deinit();

    _ = iter.next(); // skip cwd arg

    var args = Arguments{
        .allocator = allocator,
        .iter = iter,
    };

    var files = std.ArrayList([]const u8).init(allocator);
    defer files.deinit();

    const Index = struct { u8, isize };
    var map = [_]Index{
        .{ 'f', -1 },
        .{ 'h', -1 },
    };

    var idx: usize = 0;
    var flag = false;
    while (iter.next()) |arg| : (idx += 1) {
        if (arg.len < 2 or (arg[0] != '-' or mem.eql(u8, arg, "--"))) {
            flag = true;
        }

        if (flag) {
            try files.append(arg);
            continue;
        }

        var options_iter = cli.optionIterator(arg);
        while (options_iter.next()) |option| : (idx += 1) switch (option) {
            .list => |val| {
                if (val != null) {
                    assert(options_iter.index == null);
                    const end = arg.len - val.?.len - 1;
                    if (options.diagnostics) |diagnostics| {
                        try diagnostics.errors.append(allocator, .{ .unexpected_argument = .{ .option = arg[2..end] } });
                        continue;
                    }
                    return error.UnexpectedArgument;
                }
                args.options.list = true;
            },
            .extract => |val| {
                if (val != null) {
                    assert(options_iter.index == null);
                    const end = arg.len - val.?.len - 1;
                    if (options.diagnostics) |diagnostics| {
                        try diagnostics.errors.append(allocator, .{ .unexpected_argument = .{ .option = arg[2..end] } });
                        continue;
                    }
                    return error.UnexpectedArgument;
                }
                args.options.extract = true;
            },
            .file => |val| {
                if (val != null and val.?.len == 0) {
                    assert(options_iter.index == null);
                    const end = arg.len - val.?.len - 1;
                    if (options.diagnostics) |diagnostics| {
                        try diagnostics.errors.append(allocator, .{ .empty_argument = .{ .option = arg[2..end] } });
                        continue;
                    }
                    return error.EmptyArgument;
                }
                if (val == null) {
                    for (&map) |*i| if (i[0] == 'f') {
                        i[1] = @intCast(idx);
                        break;
                    };
                } else {
                    args.options.hashes = val;
                }
            },
            .hashes => |val| {
                if (val != null and val.?.len == 0) {
                    assert(options_iter.index == null);
                    const end = arg.len - val.?.len - 1;
                    if (options.diagnostics) |diagnostics| {
                        try diagnostics.errors.append(allocator, .{ .empty_argument = .{ .option = arg[2..end] } });
                        continue;
                    }
                    return error.EmptyArgument;
                }
                if (val == null) {
                    for (&map) |*i| if (i[0] == 'h') {
                        i[1] = @intCast(idx);
                        break;
                    };
                } else {
                    args.options.hashes = val;
                }
            },
            .unknown => {
                if (options.diagnostics) |diagnostics| {
                    try diagnostics.errors.append(allocator, .{
                        .unknown_option = .{ .option = if (options_iter.index) |i| arg[i - 1 .. i] else arg[2..] },
                    });
                    continue;
                }
                return error.UnknownOption;
            },
        };
    }

    const Context = struct {
        pub fn lessThan(self: @This(), a: Index, b: Index) bool {
            _ = self;
            return a[1] < b[1];
        }
    };
    std.sort.block(Index, &map, Context{}, Context.lessThan);

    var len: usize = map.len;
    for (map, 0..) |item, i| {
        const o, const n = item;
        assert(o == 'f' or o == 'h');
        if (n == -1) {
            len -= 1;
            continue;
        }

        if (i >= files.items.len) {
            len -= 1;
            if (options.diagnostics) |diagnostics| {
                try diagnostics.errors.append(allocator, .{ .empty_argument = .{ .option = &.{o} } });
                continue;
            }
            return error.EmptyArgument;
        }

        if (o == 'f') {
            args.options.file = files.items[i];
            continue;
        }
        args.options.hashes = files.items[i];
    }

    files.replaceRange(0, len, &.{}) catch unreachable; // we're removing elements so it cant error
    args.files = try files.toOwnedSlice();

    return args;
}
