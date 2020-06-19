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

const Allocator = struct {
    parent: *std.mem.Allocator,
    allocs: *usize,
    alloc_mem: *usize,
    mem: *usize,

    allocator: std.mem.Allocator,

    pub fn init(parent: *std.mem.Allocator, allocs: *usize, alloc_mem: *usize, mem: *usize) Allocator {
        return Allocator{
            .parent = parent,
            .allocs = allocs,
            .alloc_mem = alloc_mem,
            .mem = mem,
            .allocator = std.mem.Allocator{
                .reallocFn = realloc,
                .shrinkFn = shrink,
            },
        };
    }

    fn realloc(a: *std.mem.Allocator, p: []u8, old_align: u29, new_size: u64, new_align: u29) std.mem.Allocator.Error![]u8 {
        const self = @fieldParentPtr(Allocator, "allocator", a);
        const new_p = try self.parent.reallocFn(self.parent, p, old_align, new_size, new_align);
        self.allocs.* += 1;
        self.alloc_mem.* += new_p.len;
        self.mem.* = self.mem.* - p.len + new_p.len;
        return new_p;
    }

    fn shrink(a: *std.mem.Allocator, p: []u8, old_align: u29, new_size: u64, new_align: u29) []u8 {
        const self = @fieldParentPtr(Allocator, "allocator", a);
        const new_p = self.parent.shrinkFn(self.parent, p, old_align, new_size, new_align);
        self.mem.* = self.mem.* - p.len + new_p.len;
        return new_p;
    }
};

pub const State = struct {
    f: Fn,
    target_n: usize = 0,
    target_ns: u64 = 0,
    timer: std.time.Timer,
    n: usize = 1,
    ns: usize = 1,

    allocs: usize = 0,
    alloc_mem: usize = 0,
    mem: usize = 0,

    fn init(f: Fn) !State {
        const timer = try std.time.Timer.start();
        return State{ .f = f, .timer = timer };
    }

    pub fn allocator(self: *State, parent: *std.mem.Allocator) Allocator {
        return Allocator.init(parent, &self.allocs, &self.alloc_mem, &self.mem);
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

    fn runN(self: *State, n: usize) !void {
        self.n = n;
        self.resetTimer();
        try self.f(self);
        self.stopTimer();
    }

    // Adapted from https://golang.org/src/testing/benchmark.go?s=16966:17013#L281
    fn run(self: *State) !Result {
        if (self.target_n > 0) {
            try self.runN(self.target_n);
        } else {
            var n = self.n;
            while (self.ns < self.target_ns and self.n < 1e9) {
                try self.runN(n);

                const prev_n = self.n;
                var prev_ns = self.ns;

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
};

pub fn runN(f: Fn, n: usize) !Result {
    var b = try State.init(f);
    b.target_n = n;
    return b.run();
}

pub fn runNs(f: Fn, ns: u64) !Result {
    var b = try State.init(f);
    b.target_ns = ns;
    return b.run();
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
    std.testing.expect(result.n == 10);

    std.debug.warn("\n{} ops / {} ns = {d:.3} ns/op\n", .{ result.n, result.ns, result.nsPerOp() });
}

test "runNs" {
    const result = try runNs(benchmarkAssign, std.time.ns_per_s);
    std.testing.expect(result.ns >= std.time.ns_per_s);

    std.debug.warn("\n{} ops / {} ns = {d:.3} ns/op\n", .{ result.n, result.ns, result.nsPerOp() });
}

fn benchmarkAlloc(b: *State) !void {
    var allocator = b.allocator(std.heap.page_allocator);

    // Expensive setup

    b.resetTimer();

    var i: usize = 0;
    while (i < b.n) : (i += 1) {
        const p = try allocator.allocator.create(u64);
        if (i % 2 == 0) {
            allocator.allocator.destroy(p);
        }
    }
}

test "alloc" {
    const result = try runN(benchmarkAlloc, 10);

    std.debug.warn("\n{d:.3} allocs/op, {d:.3} bytes/op\n", .{ result.allocsPerOp(), result.allocMemPerOp() });
    if (result.mem > 0) {
        std.debug.warn("LEAKED {} BYTES!\n", .{result.mem});
    }
}
