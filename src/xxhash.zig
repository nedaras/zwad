const std = @import("std");
const xxhash = @import("xxhash/xxhash.zig");
const assert = std.debug.assert;

pub fn XxHash3(bits: comptime_int) type {
    if (bits != 128 and bits != 64) @compileError("XxHash3 only supports 64 or 128 bits hashes");
    return struct {
        pub const Hash = if (bits == 128) u128 else u64;

        const Self = @This();

        state: xxhash.XXH3_state_t,

        pub inline fn hash(input: []const u8) Hash {
            if (bits == 64) {
                return xxhash.XXH3_64bits(input.ptr, input.len);
            }
            @panic("not implemented");
        }

        pub fn init() Self {
            var state: xxhash.XXH3_state_t = undefined;
            assert(xxhash.XXH3_64bits_reset(&state) == .XXH_OK);
            return .{
                .state = state,
            };
        }

        pub inline fn reset(self: *Self) void {
            assert(xxhash.XXH3_64bits_reset(&self.state) == .XXH_OK);
        }

        pub fn update(self: *Self, input: []const u8) void {
            if (bits == 128) {
                assert(xxhash.XXH3_128bits_update(&self.state, input.ptr, input.len) == .XXH_OK);
                return;
            }
            assert(xxhash.XXH3_64bits_update(&self.state, input.ptr, input.len) == .XXH_OK);
        }

        pub inline fn final(self: *const Self) Hash {
            if (bits == 128) {
                return @bitCast(xxhash.XXH3_128bits_digest(&self.state));
            }
            return xxhash.XXH3_64bits_digest(&self.state);
        }
    };
}

pub const XxHash64 = struct {
    const Self = @This();

    state: xxhash.XXH64_state_t,

    pub inline fn hash(seed: u64, input: []const u8) u64 {
        return xxhash.XXH64(input.ptr, input.len, seed);
    }

    pub fn init(seed: u64) Self {
        var state: xxhash.XXH64_state_t = undefined;
        assert(xxhash.XXH64_reset(&state, seed) == .XXH_OK);

        return .{
            .state = state,
        };
    }

    pub inline fn update(self: *Self, input: []const u8) void {
        assert(xxhash.XXH64_update(&self.state, input.ptr, input.len) == .XXH_OK);
    }

    pub inline fn reset(self: *Self, seed: u64) void {
        assert(xxhash.XXH64_reset(&self.state, seed) == .XXH_OK);
    }

    pub inline fn final(self: *const Self) u64 {
        return xxhash.XXH64_digest(&self.state);
    }
};
