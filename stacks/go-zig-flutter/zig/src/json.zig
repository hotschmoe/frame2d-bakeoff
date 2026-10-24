//! Minimal JSON DOM parser. Values live in the allocator passed to `parse` (use an arena); strings
//! without escapes point into the input text, so the text must outlive the value.
const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("util.zig");

pub const Field = struct { key: []const u8, val: Value };

pub const Value = union(enum) {
    null,
    bool: bool,
    num: f64,
    str: []const u8,
    arr: []const Value,
    obj: []const Field,

    pub fn get(self: Value, key: []const u8) ?Value {
        if (self != .obj) return null;
        for (self.obj) |f| if (std.mem.eql(u8, f.key, key)) return f.val;
        return null;
    }
};

pub const Error = error{ Syntax, OutOfMemory };

const max_depth = 200;

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    a: Allocator,

    fn ws(self: *Parser) void {
        while (self.pos < self.src.len) : (self.pos += 1) switch (self.src[self.pos]) {
            ' ', '\t', '\n', '\r' => {},
            else => return,
        };
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn lit(self: *Parser, word: []const u8) Error!void {
        if (!std.mem.startsWith(u8, self.src[self.pos..], word)) return error.Syntax;
        self.pos += word.len;
    }

    fn value(self: *Parser, depth: u32) Error!Value {
        if (depth > max_depth) return error.Syntax;
        self.ws();
        const c = self.peek() orelse return error.Syntax;
        switch (c) {
            '{' => {
                self.pos += 1;
                var fields: util.List(Field) = .{};
                self.ws();
                if (self.peek() == '}') {
                    self.pos += 1;
                    return .{ .obj = &.{} };
                }
                while (true) {
                    self.ws();
                    const key = try self.string();
                    self.ws();
                    if (self.peek() != ':') return error.Syntax;
                    self.pos += 1;
                    const v = try self.value(depth + 1);
                    try fields.append(self.a, .{ .key = key, .val = v });
                    self.ws();
                    switch (self.peek() orelse return error.Syntax) {
                        ',' => self.pos += 1,
                        '}' => {
                            self.pos += 1;
                            return .{ .obj = fields.items() };
                        },
                        else => return error.Syntax,
                    }
                }
            },
            '[' => {
                self.pos += 1;
                var items: util.List(Value) = .{};
                self.ws();
                if (self.peek() == ']') {
                    self.pos += 1;
                    return .{ .arr = &.{} };
                }
                while (true) {
                    const v = try self.value(depth + 1);
                    try items.append(self.a, v);
                    self.ws();
                    switch (self.peek() orelse return error.Syntax) {
                        ',' => self.pos += 1,
                        ']' => {
                            self.pos += 1;
                            return .{ .arr = items.items() };
                        },
                        else => return error.Syntax,
                    }
                }
            },
            '"' => return .{ .str = try self.string() },
            't' => {
                try self.lit("true");
                return .{ .bool = true };
            },
            'f' => {
                try self.lit("false");
                return .{ .bool = false };
            },
            'n' => {
                try self.lit("null");
                return .null;
            },
            else => return self.number(),
        }
    }

    fn number(self: *Parser) Error!Value {
        const start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) switch (self.src[self.pos]) {
            '0'...'9', '+', '-', '.', 'e', 'E' => {},
            else => break,
        };
        if (self.pos == start) return error.Syntax;
        const v = std.fmt.parseFloat(f64, self.src[start..self.pos]) catch return error.Syntax;
        return .{ .num = v };
    }

    fn string(self: *Parser) Error![]const u8 {
        if (self.peek() != '"') return error.Syntax;
        self.pos += 1;
        const start = self.pos;
        // fast path: no escapes
        while (self.pos < self.src.len) : (self.pos += 1) {
            switch (self.src[self.pos]) {
                '"' => {
                    const s = self.src[start..self.pos];
                    self.pos += 1;
                    return s;
                },
                '\\' => break,
                else => {},
            }
        }
        var out: util.List(u8) = .{};
        try out.appendSlice(self.a, self.src[start..self.pos]);
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            self.pos += 1;
            switch (c) {
                '"' => return out.items(),
                '\\' => {
                    const e = self.peek() orelse return error.Syntax;
                    self.pos += 1;
                    switch (e) {
                        '"', '\\', '/' => try out.append(self.a, e),
                        'b' => try out.append(self.a, 8),
                        'f' => try out.append(self.a, 12),
                        'n' => try out.append(self.a, '\n'),
                        'r' => try out.append(self.a, '\r'),
                        't' => try out.append(self.a, '\t'),
                        'u' => {
                            if (self.pos + 4 > self.src.len) return error.Syntax;
                            var cp = std.fmt.parseInt(u21, self.src[self.pos..][0..4], 16) catch return error.Syntax;
                            self.pos += 4;
                            if (cp >= 0xD800 and cp < 0xDC00 and std.mem.startsWith(u8, self.src[self.pos..], "\\u") and self.pos + 6 <= self.src.len) {
                                const lo = std.fmt.parseInt(u21, self.src[self.pos + 2 ..][0..4], 16) catch return error.Syntax;
                                if (lo >= 0xDC00 and lo < 0xE000) {
                                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                    self.pos += 6;
                                }
                            }
                            var tmp: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(cp, &tmp) catch return error.Syntax;
                            try out.appendSlice(self.a, tmp[0..n]);
                        },
                        else => return error.Syntax,
                    }
                },
                else => try out.append(self.a, c),
            }
        }
        return error.Syntax;
    }
};

pub fn parse(a: Allocator, text: []const u8) Error!Value {
    var p = Parser{ .src = text, .a = a };
    const v = try p.value(0);
    p.ws();
    if (p.pos != text.len) return error.Syntax;
    return v;
}
