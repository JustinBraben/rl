//! Catch a fault (segfault / illegal instruction / ...) raised by a guarded
//! call and unwind back to the caller with an error, instead of letting it
//! take the process down. Used by `Reloader` to implement crash-rollback.
//!
//! Pure Zig, no C shim:
//!   * POSIX  — `sigaction` + libc `sigsetjmp` / `siglongjmp` (the dlopen
//!              path already links libc). No `ucontext`, no assembly.
//!   * Windows — a Vectored Exception Handler that rewrites the faulting
//!              thread's `CONTEXT` back to a point captured with
//!              `RtlCaptureContext` before the guarded call. No assembly.
//!
//! Contract: **one guarded call at a time, from one thread.** There is a
//! single global jump target (same limitation as `cr.h`).

const std = @import("std");
const builtin = @import("builtin");

const os_tag = builtin.target.os.tag;

/// Kind of fault that was caught. Best-effort mapping.
pub const Code = enum(u8) {
    none,
    segfault,
    illegal,
    misalign,
    bus,
    fpe,
    stack_overflow,
    abort,
    other,
};

/// Whether guarded calls are implemented for the current target.
pub const supported: bool = switch (os_tag) {
    .windows, .linux, .macos => true,
    else => false,
};

const impl = switch (os_tag) {
    .windows => Windows,
    .linux, .macos => Posix,
    else => Unsupported,
};

var g_code: Code = .none;

/// Install fault handlers. Idempotent. `alt_stack` is used as the POSIX
/// signal alternate stack (so stack-overflow faults can still be handled);
/// ignored on Windows. Must outlive `uninstall`. No-op on unsupported
/// targets — callers that need crash handling should gate on `supported`.
pub fn install(alt_stack: []u8) void {
    impl.install(alt_stack);
}

pub fn uninstall() void {
    if (!supported) return;
    impl.uninstall();
}

/// The fault kind from the most recent caught crash.
pub fn lastCode() Code {
    return g_code;
}

fn Return(comptime Fn: type) type {
    const info = @typeInfo(Fn);
    return switch (info) {
        .@"fn" => |f| f.return_type.?,
        .pointer => |p| @typeInfo(p.child).@"fn".return_type.?,
        else => @compileError("guard.call expects a function or function pointer, got " ++ @typeName(Fn)),
    };
}

/// Run `f(args...)` under the fault guard. On a caught fault, records the
/// code (see `lastCode`) and returns `error.GuestCrashed`; otherwise returns
/// whatever `f` returned.
pub fn call(comptime Fn: type, f: Fn, args: anytype) error{GuestCrashed}!Return(Fn) {
    const Ret = Return(Fn);
    const Ctx = struct {
        f: Fn,
        args: @TypeOf(args),
        ret: Ret = undefined,
    };
    var ctx: Ctx = .{ .f = f, .args = args };

    const trampoline = struct {
        fn t(ud: *anyopaque) callconv(.c) void {
            const c: *Ctx = @ptrCast(@alignCast(ud));
            if (Ret == void) {
                @call(.auto, c.f, c.args);
            } else {
                c.ret = @call(.auto, c.f, c.args);
            }
        }
    }.t;

    g_code = .none;
    if (impl.protect(trampoline, &ctx)) return error.GuestCrashed;
    return ctx.ret;
}

// ---------------------------------------------------------------------------
// Windows: RtlCaptureContext + Vectored Exception Handler

const Windows = struct {
    const w = std.os.windows;
    const ntdll = w.ntdll;

    const EXCEPTION_CONTINUE_EXECUTION: w.LONG = -1;
    const EXCEPTION_INT_DIVIDE_BY_ZERO: w.DWORD = 0xC0000094;
    const EXCEPTION_PRIV_INSTRUCTION: w.DWORD = 0xC0000096;
    const EXCEPTION_IN_PAGE_ERROR: w.DWORD = 0xC0000006;

    var g_saved: w.CONTEXT align(16) = undefined;
    var g_armed: bool = false;
    var g_crashed: bool = false;
    var g_handle: ?*anyopaque = null;

    fn classify(code: w.DWORD) ?Code {
        return switch (code) {
            w.EXCEPTION_ACCESS_VIOLATION, EXCEPTION_IN_PAGE_ERROR => .segfault,
            w.EXCEPTION_ILLEGAL_INSTRUCTION, EXCEPTION_PRIV_INSTRUCTION => .illegal,
            w.EXCEPTION_DATATYPE_MISALIGNMENT => .misalign,
            w.EXCEPTION_STACK_OVERFLOW => .stack_overflow,
            EXCEPTION_INT_DIVIDE_BY_ZERO => .fpe,
            else => null,
        };
    }

    fn veh(info: *w.EXCEPTION_POINTERS) callconv(.winapi) w.LONG {
        if (!g_armed) return w.EXCEPTION_CONTINUE_SEARCH;
        const kind = classify(info.ExceptionRecord.ExceptionCode) orelse
            return w.EXCEPTION_CONTINUE_SEARCH;
        g_code = kind;
        g_crashed = true;
        g_armed = false;
        // Resume the faulting thread at the point captured before the call.
        info.ContextRecord.* = g_saved;
        return EXCEPTION_CONTINUE_EXECUTION;
    }

    fn install(_: []u8) void {
        if (g_handle != null) return;
        g_handle = ntdll.RtlAddVectoredExceptionHandler(1, veh);
    }

    fn uninstall() void {
        if (g_handle) |h| {
            _ = ntdll.RtlRemoveVectoredExceptionHandler(h);
            g_handle = null;
        }
    }

    noinline fn protect(tramp: *const fn (*anyopaque) callconv(.c) void, ud: *anyopaque) bool {
        g_crashed = false;
        g_armed = true;
        ntdll.RtlCaptureContext(&g_saved);
        // Reached both on the initial pass and again (via veh) after a fault.
        if (@atomicLoad(bool, &g_crashed, .seq_cst)) {
            g_armed = false;
            return true;
        }
        tramp(ud);
        g_armed = false;
        return false;
    }
};

// ---------------------------------------------------------------------------
// POSIX: sigaction + libc sigsetjmp / siglongjmp

const Posix = struct {
    const posix = std.posix;

    // Over-sized to cover glibc / musl / Darwin `sigjmp_buf` on x86_64 and
    // aarch64 (largest is glibc aarch64 at ~320 bytes).
    const JmpBuf = extern struct { _opaque: [512]u8 align(16) };

    const sigsetjmp_name = if (builtin.abi.isGnu()) "__sigsetjmp" else "sigsetjmp";
    const sigsetjmp = @extern(*const fn (*JmpBuf, c_int) callconv(.c) c_int, .{ .name = sigsetjmp_name });
    const siglongjmp = @extern(*const fn (*JmpBuf, c_int) callconv(.c) noreturn, .{ .name = "siglongjmp" });

    const signals = [_]posix.SIG{ .SEGV, .BUS, .ILL, .FPE, .ABRT };

    var g_buf: JmpBuf = undefined;
    var g_armed: bool = false;
    var g_old: [signals.len]posix.Sigaction = undefined;
    var g_installed: bool = false;

    fn classify(sig: posix.SIG) Code {
        return switch (sig) {
            .SEGV => .segfault,
            .BUS => .bus,
            .ILL => .illegal,
            .FPE => .fpe,
            .ABRT => .abort,
            else => .other,
        };
    }

    fn handler(sig: posix.SIG, info: *const posix.siginfo_t, uctx: ?*anyopaque) callconv(.c) void {
        _ = info;
        _ = uctx;
        if (!g_armed) {
            // Not our fault to catch: restore whatever was installed before us
            // (Zig's own segfault handler, or the default) and return so the
            // instruction re-faults into it.
            inline for (signals, 0..) |s, i| {
                if (s == sig) {
                    posix.sigaction(sig, &g_old[i], null);
                    return;
                }
            }
            return;
        }
        g_armed = false;
        g_code = classify(sig);
        siglongjmp(&g_buf, 1);
    }

    fn install(alt_stack: []u8) void {
        if (g_installed) return;
        g_installed = true;

        var ss: posix.stack_t = .{
            .sp = alt_stack.ptr,
            .size = alt_stack.len,
            .flags = 0,
        };
        posix.sigaltstack(&ss, null) catch {};

        var act: posix.Sigaction = .{
            .handler = .{ .sigaction = &handler },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.SIGINFO | posix.SA.NODEFER | posix.SA.ONSTACK | posix.SA.RESTART,
        };
        inline for (signals, 0..) |s, i| posix.sigaction(s, &act, &g_old[i]);
    }

    fn uninstall() void {
        if (!g_installed) return;
        g_installed = false;
        inline for (signals, 0..) |s, i| posix.sigaction(s, &g_old[i], null);
    }

    noinline fn protect(tramp: *const fn (*anyopaque) callconv(.c) void, ud: *anyopaque) bool {
        g_armed = true;
        if (sigsetjmp(&g_buf, 1) != 0) {
            g_armed = false;
            return true;
        }
        tramp(ud);
        g_armed = false;
        return false;
    }
};

const Unsupported = struct {
    fn install(_: []u8) void {}
    fn uninstall() void {}
    fn protect(tramp: *const fn (*anyopaque) callconv(.c) void, ud: *anyopaque) bool {
        tramp(ud);
        return false;
    }
};

// ---------------------------------------------------------------------------
// tests

test "call returns the wrapped result when nothing faults" {
    if (!supported) return error.SkipZigTest;
    var scratch: [16 * 1024]u8 = undefined;
    install(&scratch);
    defer uninstall();

    const F = struct {
        fn add3(x: *anyopaque) callconv(.c) usize {
            return @intFromPtr(x) + 3 - @intFromPtr(x);
        }
    };
    const got = try call(@TypeOf(&F.add3), &F.add3, .{@as(*anyopaque, @ptrFromInt(0x1000))});
    try std.testing.expectEqual(@as(usize, 3), got);
}

test "call catches a null dereference" {
    if (!supported) return error.SkipZigTest;
    var scratch: [64 * 1024]u8 = undefined;
    install(&scratch);
    defer uninstall();

    const F = struct {
        fn boom(_: *anyopaque) callconv(.c) void {
            const p: *allowzero volatile u8 = @ptrFromInt(0);
            p.* = 1;
        }
    };
    var dummy: u8 = 0;
    try std.testing.expectError(
        error.GuestCrashed,
        call(@TypeOf(&F.boom), &F.boom, .{@as(*anyopaque, &dummy)}),
    );
    try std.testing.expectEqual(Code.segfault, lastCode());

    // Guard still works for a subsequent good call.
    const G = struct {
        fn ok(_: *anyopaque) callconv(.c) u32 {
            return 7;
        }
    };
    try std.testing.expectEqual(@as(u32, 7), try call(@TypeOf(&G.ok), &G.ok, .{@as(*anyopaque, &dummy)}));
}
