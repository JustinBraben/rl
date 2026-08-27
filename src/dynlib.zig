//! Cross-platform dynamic library loading.
//!
//! `std.DynLib` has no Windows arm in Zig 0.16 (its `InnerType` switch turns
//! into `@compileError` for `.windows`), so Windows uses a hand-rolled
//! `LoadLibraryW` / `GetProcAddress` / `FreeLibrary` path while every other
//! OS forwards to `std.DynLib` (a real `dlopen`, so the guest's own shared
//! dependencies resolve against the host's already-loaded copies).

const std = @import("std");
const builtin = @import("builtin");

const native_os = builtin.target.os.tag;
const log = std.log.scoped(.rl);

pub const Error = error{
    /// The OS refused to load the library (missing file, bad image, an
    /// unresolved dependency symbol, ...). The specific reason is logged at
    /// debug level.
    LibraryLoadFailed,
    /// The path could not be encoded for the platform loader.
    BadPathName,
};

pub const DynLib = struct {
    inner: Inner,

    const Inner = switch (native_os) {
        .windows => WindowsDynLib,
        else => PosixDynLib,
    };

    /// `path` is WTF-8 on Windows, an opaque byte sequence elsewhere.
    pub fn open(path: []const u8) Error!DynLib {
        return .{ .inner = try Inner.open(path) };
    }

    pub fn close(self: *DynLib) void {
        self.inner.close();
    }

    /// Look up an exported symbol. `T` should be a function-pointer type
    /// (`*const fn (...) callconv(.c) ...`). Returns `null` if absent.
    pub fn lookup(self: *DynLib, comptime T: type, name: [:0]const u8) ?T {
        return self.inner.lookup(T, name);
    }
};

const PosixDynLib = struct {
    lib: std.DynLib,

    fn open(path: []const u8) Error!PosixDynLib {
        const lib = std.DynLib.open(path) catch |err| {
            log.debug("dlopen('{s}') failed: {s}", .{ path, @errorName(err) });
            return switch (err) {
                error.NameTooLong, error.BadPathName => error.BadPathName,
                else => error.LibraryLoadFailed,
            };
        };
        return .{ .lib = lib };
    }

    fn close(self: *PosixDynLib) void {
        self.lib.close();
        self.* = undefined;
    }

    fn lookup(self: *PosixDynLib, comptime T: type, name: [:0]const u8) ?T {
        return self.lib.lookup(T, name);
    }
};

const WindowsDynLib = struct {
    handle: std.os.windows.HMODULE,

    const windows = std.os.windows;

    extern "kernel32" fn LoadLibraryW(lpLibFileName: windows.LPCWSTR) callconv(.winapi) ?windows.HMODULE;
    extern "kernel32" fn GetProcAddress(hModule: windows.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(hLibModule: windows.HMODULE) callconv(.winapi) windows.BOOL;

    fn open(path: []const u8) Error!WindowsDynLib {
        var wbuf: [windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const len = windows.wtf8ToWtf16Le(wbuf[0 .. wbuf.len - 1], path) catch return error.BadPathName;
        wbuf[len] = 0;
        const handle = LoadLibraryW(wbuf[0..len :0].ptr) orelse {
            log.debug("LoadLibraryW('{s}') failed: {}", .{ path, windows.GetLastError() });
            return error.LibraryLoadFailed;
        };
        return .{ .handle = handle };
    }

    fn close(self: *WindowsDynLib) void {
        _ = FreeLibrary(self.handle);
        self.* = undefined;
    }

    fn lookup(self: *WindowsDynLib, comptime T: type, name: [:0]const u8) ?T {
        const addr = GetProcAddress(self.handle, name.ptr) orelse return null;
        return @ptrCast(@alignCast(addr));
    }
};
