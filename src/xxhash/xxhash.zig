pub const XXH_errorcode = enum(c_int) {
    XXH_OK = 0,
    XXH_ERROR = 1,
};

pub const XXH64_hash_t = u64;
pub const XXH32_hash_t = u32;

pub const XXH3_SECRET_DEFAULT_SIZE = 192;
pub const XXH3_INTERNALBUFFER_SIZE = 256;

pub const XXH3_state_t = extern struct {
    acc: [8]XXH64_hash_t align(64),
    customSecret: [XXH3_SECRET_DEFAULT_SIZE]u8 align(64),
    buffer: [XXH3_INTERNALBUFFER_SIZE]u8 align(64),
    bufferedSize: XXH32_hash_t,
    useSeed: XXH32_hash_t,
    nbStripesSoFar: usize,
    totalLen: XXH64_hash_t,
    nbStripesPerBlock: usize,
    secretLimit: usize,
    seed: XXH64_hash_t,
    reserved64: XXH64_hash_t,
    extSecret: [*:0]u8,
};

pub const XXH128_hash_t = extern struct {
    low64: XXH64_hash_t,
    high64: XXH64_hash_t,
};

pub extern fn XXH3_128bits_reset(statePtr: *XXH3_state_t) XXH_errorcode;

pub extern fn XXH3_128bits_update(statePtr: *XXH3_state_t, input: [*]const u8, length: usize) XXH_errorcode;

pub extern fn XXH3_128bits_digest(statePtr: *const XXH3_state_t) XXH128_hash_t;

pub extern fn XXH3_64bits(input: [*]const u8, length: usize) u64;

pub extern fn XXH64(input: [*]const u8, length: usize, seed: u64) u64;
