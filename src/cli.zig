const std = @import("std");
const cli = @import("cli/options.zig");
const logger = @import("logger.zig");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

pub const help = @embedFile("cli/messages/help.cli");

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
        missing_operation,
        multiple_operations,
    };

    pub fn deinit(self: *Diagnostics) void {
        self.errors.deinit(self.allocator);
    }
};

pub const Action = enum {
    extract,
    list,
    create,
};

pub const Options = struct {
    file: ?[]const u8,
    hashes: ?[]const u8,
    directory: ?[]const u8,
    verbose: bool,
};

pub const Arguments = struct {
    allocator: Allocator,
    iter: std.process.ArgIterator,

    operation: Action,
    options: Options,

    files: []const []const u8 = &.{},

    pub fn deinit(self: *Arguments) void {
        self.iter.deinit();
        self.allocator.free(self.files);
    }
};

pub const ParseOptions = struct {
    diagnostics: *Diagnostics,
};

pub fn parseArguments(allocator: Allocator, options: ParseOptions) Allocator.Error!Arguments {
    var iter = try std.process.argsWithAllocator(allocator);
    errdefer iter.deinit();

    // this does look cursed that we're initing it here
    logger.init(std.fs.path.basename(iter.next().?));

    var args = Arguments{
        .allocator = allocator,
        .iter = iter,
        .operation = undefined,
        .options = .{
            .file = null,
            .hashes = null,
            .directory = null,
            .verbose = false,
        },
    };

    var operation: ?Action = null;

    var files = std.ArrayList([]const u8).init(allocator);
    defer files.deinit();

    while (iter.next()) |arg| {
        if (arg.len < 2 or (arg[0] != '-' or mem.eql(u8, arg, "--"))) {
            try files.append(arg);
            continue;
        }

        var options_iter = cli.optionIterator(arg);
        while (options_iter.next()) |option| switch (option) {
            .list => |val| {
                if (operation != null) {
                    try options.diagnostics.errors.append(allocator, .multiple_operations);
                    continue;
                }

                if (val != null) {
                    assert(options_iter.index == null);
                    const end = arg.len - val.?.len - 1;
                    try options.diagnostics.errors.append(allocator, .{ .unexpected_argument = .{ .option = arg[2..end] } });
                    continue;
                }

                operation = .list;
            },
            .extract => |val| {
                if (operation != null) {
                    try options.diagnostics.errors.append(allocator, .multiple_operations);
                    continue;
                }

                if (val != null) {
                    assert(options_iter.index == null);
                    const end = arg.len - val.?.len - 1;
                    try options.diagnostics.errors.append(allocator, .{ .unexpected_argument = .{ .option = arg[2..end] } });
                    continue;
                }

                operation = .extract;
            },
            .create => |val| {
                if (operation != null) {
                    try options.diagnostics.errors.append(allocator, .multiple_operations);
                    continue;
                }

                if (val != null) {
                    assert(options_iter.index == null);
                    const end = arg.len - val.?.len - 1;
                    try options.diagnostics.errors.append(allocator, .{ .unexpected_argument = .{ .option = arg[2..end] } });
                    continue;
                }

                operation = .create;
            },
            .file => |val| {
                if (val) |v| {
                    if (v.len == 0) {
                        assert(options_iter.index == null);
                        const end = arg.len - val.?.len - 1;
                        try options.diagnostics.errors.append(allocator, .{ .empty_argument = .{ .option = arg[2..end] } });
                        continue;
                    }

                    args.options.file = v;
                    continue;
                }

                const next = iter.next();
                if (next == null or next.?.len == 0) {
                    try options.diagnostics.errors.append(allocator, .{ .empty_argument = .{ .option = "f" } });
                    continue;
                }

                args.options.file = next.?;
            },
            .hashes => |val| {
                if (val) |v| {
                    if (v.len == 0) {
                        assert(options_iter.index == null);
                        const end = arg.len - val.?.len - 1;
                        try options.diagnostics.errors.append(allocator, .{ .empty_argument = .{ .option = arg[2..end] } });
                        continue;
                    }

                    args.options.hashes = v;
                    continue;
                }

                const next = iter.next();
                if (next == null or next.?.len == 0) {
                    try options.diagnostics.errors.append(allocator, .{ .empty_argument = .{ .option = "h" } });
                    continue;
                }

                args.options.hashes = next.?;
            },
            .directory => |val| {
                if (val) |v| {
                    if (v.len == 0) {
                        assert(options_iter.index == null);
                        const end = arg.len - val.?.len - 1;
                        try options.diagnostics.errors.append(allocator, .{ .empty_argument = .{ .option = arg[2..end] } });
                        continue;
                    }

                    args.options.directory = v;
                    continue;
                }

                const next = iter.next();
                if (next == null or next.?.len == 0) {
                    try options.diagnostics.errors.append(allocator, .{ .empty_argument = .{ .option = "C" } });
                    continue;
                }

                args.options.directory = next.?;
            },
            .verbose => |val| {
                if (val != null) {
                    assert(options_iter.index == null);
                    const end = arg.len - val.?.len - 1;
                    try options.diagnostics.errors.append(allocator, .{ .unexpected_argument = .{ .option = arg[2..end] } });
                    continue;
                }
                args.options.verbose = true;
            },
            .unknown => {
                try options.diagnostics.errors.append(allocator, .{
                    .unknown_option = .{ .option = if (options_iter.index) |i| arg[i - 1 .. i] else arg[2..] },
                });
            },
        };
    }

    if (operation == null) {
        try options.diagnostics.errors.append(allocator, .missing_operation);
        return args;
    }

    args.files = try files.toOwnedSlice();
    args.operation = operation.?;

    return args;
}
