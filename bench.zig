const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const panic = std.debug.panic;

const btree = @import("btree.zig");
const bptree = @import("bptree.zig");

const debug = false;

pub inline fn rdtscp() u64 {
    var hi: u64 = undefined;
    var low: u64 = undefined;
    asm volatile ("rdtscp"
        : [low] "={eax}" (low),
          [hi] "={edx}" (hi),
        :
        : "ecx"
    );
    return (@as(u64, hi) << 32) | @as(u64, low);
}

pub const XorShift64 = struct {
    a: u64 = 123456789,

    pub fn next(self: *XorShift64) u64 {
        var b = self.a;
        b ^= b << 13;
        b ^= b >> 7;
        b ^= b << 17;
        self.a = b;
        return b;
    }
};

pub const Ascending = struct {
    a: u64 = 0,

    pub fn next(self: *Ascending) u64 {
        const b = self.a;
        self.a += 1;
        return b;
    }
};

pub const Descending = struct {
    a: u64 = N,

    pub fn next(self: *Descending) u64 {
        const b = self.a;
        self.a -= 1;
        return b;
    }
};

const N: u64 = 10_000_000;

fn equal(a: u64, b: u64) bool {
    return a == b;
}

fn less_than(a: u64, b: u64) bool {
    return a < b;
}

fn order(a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}

const SipHashContext = struct {
    pub fn hash(ctx: SipHashContext, key: u64) u64 {
        _ = ctx;
        var hasher = std.crypto.auth.siphash.SipHash64(2, 4).init("0x128dad08f12307");
        hasher.update(std.mem.asBytes(&key));
        return hasher.finalInt();
    }

    pub fn eql(ctx: SipHashContext, a: u64, b: u64) bool {
        _ = ctx;
        return a == b;
    }
};

fn bench(map: anytype, rng_init: anytype) !void {
    std.debug.print("{s} {s}\n", .{ @typeName(@TypeOf(map)), @typeName(@TypeOf(rng_init)) });

    const before_writes = std.time.nanoTimestamp();
    var rng = rng_init;
    for (0..N) |_| {
        const k = rng.next() % N;
        if (debug) {
            std.debug.print("writing {}, count = {}, depth = {}\n", .{ k, map.count, map.depth });
        }
        _ = try map.put(k, k);
        if (debug) {
            try map.print(std.io.getStdErr().writer());
            map.validate();
        }
    }
    std.debug.print("writes = {d}s\n", .{@as(f64, @floatFromInt(std.time.nanoTimestamp() - before_writes)) / 1e9});

    const before_reads = std.time.nanoTimestamp();
    rng = rng_init;
    for (0..N) |_| {
        const k = rng.next() % N;
        const v = map.get(k);
        if (v == null or v.? != k) {
            panic("map.get({}) == {?}", .{ k, v });
        }
    }
    std.debug.print("reads = {d}s\n", .{@as(f64, @floatFromInt(std.time.nanoTimestamp() - before_reads)) / 1e9});
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    inline for (&.{
        //Ascending{},
        //Descending{},
        XorShift64{},
    }) |rng| {
        //inline for (&.{11}) |key_count_max| {
        //    var map = try btree.Map(u64, u64, key_count_max, order, debug).init(allocator);
        //    try bench(&map, rng);
        //}
        inline for (&.{
            11,
            15,
            31,
            63,
            127,
        }) |key_count_max| {
            inline for (&.{
                .linear,
                .binary_branchless,
            }) |branch_search| {
                inline for (&.{
                    .linear,
                    .linear_lazy,
                    .binary_branchless,
                }) |leaf_search| {
                    var map = try bptree.Map(u64, u64, equal, less_than, .{
                        .key_count_max = key_count_max,
                        .branch_search = branch_search,
                        .leaf_search = leaf_search,
                        .debug = debug,
                    }).init(allocator);
                    try bench(&map, rng);
                }
            }
        }
        if (!debug) {
            {
                var map = std.HashMap(u64, u64, SipHashContext, std.hash_map.default_max_load_percentage).init(allocator);
                try bench(&map, rng);
            }
            {
                var map = std.AutoHashMap(u64, u64).init(allocator);
                try bench(&map, rng);
            }
        }
        std.debug.print("\n", .{});
    }
}
