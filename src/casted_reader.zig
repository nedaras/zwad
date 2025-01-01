const std = @import("std");

// todo: when zig fixes its stuff unreachanble prongs on anytypes should not be a problem, remove this thing
pub inline fn castedReader(comptime Error: type, reader: anytype) std.io.Reader(@TypeOf(reader), Error, switch (@typeInfo(@TypeOf(reader))) {
    .Pointer => |P| P.child.read,
    else => @TypeOf(reader).read,
}) {
    return .{ .context = reader };
}
