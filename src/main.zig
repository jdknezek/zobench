const std = @import("std");

pub const Fn = fn (*State) anyerror!void;

pub const Result = struct {
    n: usize,
    ns: u64,
    allocs: usize,
    alloc_mem: usize,
    mem: usize,

    pub fn nsPerOp(self: Result) f64 {
        return @intToFloat(f64, self.ns) / @intToFloat(f64, self.n);
    }

    pub fn allocsPerOp(self: Result) f64 {
        return @intToFloat(f64, self.allocs) / @intToFloat(f64, self.n);
    }

    pub fn allocMemPerOp(self: Result) f64 {
        return @intToFloat(f64, self.alloc_mem) / @intToFloat(f64, self.n);
    }

    pub fn memPerOp(self: Result) f64 {
        return @intToFloat(f64, self.mem) / @intToFloat(f64, self.n);
    }
};

pub const State = struct {
    target_n: usize = 0,
    target_ns: u64 = 0,
    timer: std.time.Timer,
    n: usize = 1,
    ns: usize = 1,

    parent: std.mem.Allocator,
    allocs: usize = 0,
    alloc_mem: usize = 0,
    mem: usize = 0,

    fn init(alloc: std.mem.Allocator) !State {
        const timer = try std.time.Timer.start();
        return State{ .timer = timer, .parent = alloc };
    }

    pub fn resetTimer(self: *State) void {
        self.timer.reset();
        self.ns = 0;
        self.allocs = 0;
        self.mem = 0;
    }

    pub fn startTimer(self: *State) void {
        self.timer.reset();
    }

    pub fn stopTimer(self: *State) void {
        self.ns += self.timer.lap();
    }

    fn runN(self: *State, f: *const Fn, n: usize) !void {
        self.n = n;
        self.resetTimer();
        try f(self);
        self.stopTimer();
    }

    // Adapted from https://golang.org/src/testing/benchmark.go?s=16966:17013#L281
    fn run(self: *State, f: *const Fn) !Result {
        if (self.target_n > 0) {
            try self.runN(f, self.target_n);
        } else {
            var n = self.n;
            while (self.ns < self.target_ns and self.n < 1e9) {
                try self.runN(f, n);

                const prev_n = self.n;
                var prev_ns = self.ns;
                if (prev_ns == 0) {
                    prev_ns = 1;
                }

                n = self.target_ns * prev_n / @as(usize, prev_ns);
                n += n / 5;
                n = std.math.min(n, 100 * prev_n);
                n = std.math.max(n, prev_n + 1);
                n = std.math.min(n, @as(usize, 1e9));
            }
        }

        return Result{
            .n = self.n,
            .ns = self.ns,
            .allocs = self.allocs,
            .alloc_mem = self.alloc_mem,
            .mem = self.mem,
        };
    }

    fn allocFn(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self = @ptrCast(*State, @alignCast(@alignOf(State), ctx));

        const mem = self.parent.vtable.alloc(self.parent.ptr, len, ptr_align, ret_addr) orelse return null;
        self.allocs += 1;
        self.alloc_mem += len;
        self.mem += len;
        return mem;
    }

    fn resizeFn(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self = @ptrCast(*State, @alignCast(@alignOf(State), ctx));

        if (!self.parent.vtable.resize(self.parent.ptr, buf, buf_align, new_len, ret_addr)) return false;
        if (new_len > buf.len) {
            self.allocs += 1;
            const grow_len = new_len - buf.len;
            self.alloc_mem += grow_len;
            self.mem += grow_len;
        } else {
            self.mem -= buf.len - new_len;
        }
        return true;
    }

    fn freeFn(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self = @ptrCast(*State, @alignCast(@alignOf(State), ctx));

        self.parent.vtable.free(self.parent.ptr, buf, buf_align, ret_addr);
        self.mem -= buf.len;
    }

    pub fn allocator(self: *State) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .free = freeFn,
            },
        };
    }
};

pub fn runN(comptime f: *const Fn, n: usize) !Result {
    var b = try State.init(std.testing.allocator);
    b.target_n = n;
    return b.run(f);
}

pub fn runNs(comptime f: *const Fn, ns: u64) !Result {
    var b = try State.init(std.testing.allocator);
    b.target_ns = ns;
    return b.run(f);
}

fn benchmarkAssign(b: *State) !void {
    // Expensive setup
    b.resetTimer();

    var i: usize = 0;
    while (i < b.n) : (i += 1) {
        i = i;
    }
}

test "runN" {
    const result = try runN(benchmarkAssign, 10);
    try std.testing.expect(result.n == 10);

    std.debug.print("\n{} ops / {} ns = {d:.3} ns/op\n", .{ result.n, result.ns, result.nsPerOp() });
}

test "runNs" {
    const result = try runNs(benchmarkAssign, std.time.ns_per_s);
    try std.testing.expect(result.ns >= std.time.ns_per_s);

    std.debug.print("\n{} ops / {} ns = {d:.3} ns/op\n", .{ result.n, result.ns, result.nsPerOp() });
}

fn benchmarkAlloc(b: *State) !void {
    var allocator = b.allocator();

    // Expensive setup

    b.resetTimer();

    var i: usize = 0;
    while (i < b.n) : (i += 1) {
        const p = try allocator.create(u64);
        if (i % 2 == 0) {
            allocator.destroy(p);
        }
    }
}

test "leak" {
    const result = try runN(benchmarkAlloc, 10);

    std.debug.print("\n{d:.3} allocs/op, {d:.3} bytes/op\n", .{ result.allocsPerOp(), result.allocMemPerOp() });
    if (result.mem > 0) {
        std.debug.print("LEAKED {} BYTES!\n", .{result.mem});
    }
}
