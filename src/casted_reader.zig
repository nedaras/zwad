const std = @import("std");

pub inline fn castedReader(comptime Error: type, reader: anytype) std.io.Reader(@TypeOf(reader), Error, switch (@typeInfo(@TypeOf(reader))) {
    .Pointer => |P| P.child.read,
    else => @TypeOf(reader).read,
}) {
    return .{ .context = reader };
}
