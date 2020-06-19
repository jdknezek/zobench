# zobench

Zobench is a simple benchmark library for Zig. It's inspired by [Go's testing.B](https://golang.org/pkg/testing/#B).

## Example

```zig
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
        std.debug.warn("LEAKED {} BYTES!\n", .{ result.mem });
    }
}

```

Output:

```
1/3 test "runN"...
10 ops / 100 ns = 10.000 ns/op
OK
2/3 test "runNs"...
248446278 ops / 1096017300 ns = 4.411 ns/op
OK
3/3 test "alloc"...
1.000 allocs/op, 8.000 bytes/op
LEAKED 40 BYTES!
OK
All 3 tests passed.
```
