const std = @import("std");
const xxhash = @import("xxhash/xxhash.zig");
const assert = std.debug.assert;

pub fn XxHash3(bits: comptime_int) type {
    if (bits != 128 and bits != 64) @compileError("XxHash3 only supports 64 or 128 bits hashes");
    return struct {
        const Self = @This();
        const Hash = if (bits == 128) u128 else u64;

        state: xxhash.XXH3_state_t,

        pub fn init(seed: u64) Self {
            if (bits == 64) {
                @panic("not implemented");
            }

            var state: xxhash.XXH3_state_t = undefined;
            assert(xxhash.XXH3_128bits_reset(&state) == .XXH_OK);

            state.seed = seed;
            return .{
                .state = state,
            };
        }

        pub fn update(self: *Self, input: []const u8) void {
            if (bits == 128) {
                assert(xxhash.XXH3_128bits_update(&self.state, input.ptr, input.len) == .XXH_OK);
                return;
            }
            @panic("not implemented");
        }

        pub fn final(self: *const Self) Hash {
            if (bits == 128) {
                const hash = xxhash.XXH3_128bits_digest(&self.state);
                return @bitCast(hash); // it is safe to cast.
            }
            @panic("not implemented");
        }
    };
}

pub const XxHash64 = struct {
    pub inline fn hash(seed: u64, input: []const u8) u64 {
        return xxhash.XXH64(input.ptr, input.len, seed);
    }
};
