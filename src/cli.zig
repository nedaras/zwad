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

    var flag = false;
    while (iter.next()) |arg| {
        if (arg.len < 2 or (arg[0] != '-' or mem.eql(u8, arg, "--"))) {
            flag = true;
        }

        if (flag) {
            try files.append(arg);
            continue;
        }

        var options_iter = cli.optionIterator(arg);
        while (options_iter.next()) |option| switch (option) {
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
                args.options.file = val;
            },
            .hashes => {},
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

    args.files = try files.toOwnedSlice();
    return args;
}
