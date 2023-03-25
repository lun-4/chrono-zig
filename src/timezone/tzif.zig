const std = @import("std");
const testing = std.testing;
const posix = @import("./posix.zig");

const TZ = posix.TZ;
const log = std.log.scoped(.tzif);

pub const TimeZone = struct {
    allocator: std.mem.Allocator,
    version: Version,
    transitionTimes: []i64,
    transitionTypes: []u8,
    localTimeTypes: []LocalTimeType,
    designations: []u8,
    leapSeconds: []LeapSecond,
    transitionIsStd: []bool,
    transitionIsUT: []bool,
    string: []u8,
    posixTZ: ?TZ,

    pub fn deinit(this: @This()) void {
        this.allocator.free(this.transitionTimes);
        this.allocator.free(this.transitionTypes);
        this.allocator.free(this.localTimeTypes);
        this.allocator.free(this.designations);
        this.allocator.free(this.leapSeconds);
        this.allocator.free(this.transitionIsStd);
        this.allocator.free(this.transitionIsUT);
        this.allocator.free(this.string);
    }

    fn findTransitionTime(this: @This(), utc: i64) ?usize {
        var left: usize = 0;
        var right: usize = this.transitionTimes.len;

        while (left < right) {
            // Avoid overflowing in the midpoint calculation
            const mid = left + (right - left) / 2;
            // Compare the key with the midpoint element
            if (this.transitionTimes[mid] == utc) {
                if (mid + 1 < this.transitionTimes.len) {
                    return mid;
                } else {
                    return null;
                }
            } else if (this.transitionTimes[mid] > utc) {
                right = mid;
            } else if (this.transitionTimes[mid] < utc) {
                left = mid + 1;
            }
        }

        if (right == this.transitionTimes.len) {
            return null;
        } else if (right > 0) {
            return right - 1;
        } else {
            return 0;
        }
    }

    pub const ConversionResult = struct {
        timestamp: i64,
        offset: i32,
        dst: bool,
        designation: []const u8,
    };

    pub fn localTimeFromUTC(this: @This(), utc: i64) ?ConversionResult {
        if (this.findTransitionTime(utc)) |idx| {
            const transition_type = this.transitionTypes[idx];
            const local_time_type = this.localTimeTypes[transition_type];

            var designation = this.designations[local_time_type.idx .. this.designations.len - 1];
            for (designation, 0..) |c, i| {
                if (c == 0) {
                    designation = designation[0..i];
                    break;
                }
            }

            return ConversionResult{
                .timestamp = utc + local_time_type.utoff,
                .offset = local_time_type.utoff,
                .dst = local_time_type.dst,
                .designation = designation,
            };
        } else if (this.posixTZ) |posixTZ| {
            // Base offset on the TZ string
            const offset_res = posixTZ.offset(utc);
            return ConversionResult{
                .timestamp = utc - offset_res.offset,
                .offset = offset_res.offset,
                .dst = offset_res.dst,
                .designation = offset_res.designation,
            };
        } else {
            return null;
        }
    }

    pub fn localTimeToUTC(this: @This(), localtime: i64) ?ConversionResult {
        _ = this;
        _ = localtime;
        std.debug.panic("Unimplemented", .{});
        return null;
    }
};

pub const Version = enum(u8) {
    V1 = 0,
    V2 = '2',
    V3 = '3',

    pub fn timeSize(this: @This()) u32 {
        return switch (this) {
            .V1 => 4,
            .V2, .V3 => 8,
        };
    }

    pub fn leapSize(this: @This()) u32 {
        return this.timeSize() + 4;
    }

    pub fn string(this: @This()) []const u8 {
        return switch (this) {
            .V1 => "1",
            .V2 => "2",
            .V3 => "3",
        };
    }
};

pub const LocalTimeType = struct {
    utoff: i32,
    /// Indicates whether this local time is Daylight Saving Time
    dst: bool,
    idx: u8,
};

pub const LeapSecond = struct {
    occur: i64,
    corr: i32,
};

const TIME_TYPE_SIZE = 6;

pub const TZifHeader = struct {
    version: Version,
    isutcnt: u32,
    isstdcnt: u32,
    leapcnt: u32,
    timecnt: u32,
    typecnt: u32,
    charcnt: u32,

    pub fn dataSize(this: @This(), dataBlockVersion: Version) u32 {
        return this.timecnt * dataBlockVersion.timeSize() +
            this.timecnt +
            this.typecnt * TIME_TYPE_SIZE +
            this.charcnt +
            this.leapcnt * dataBlockVersion.leapSize() +
            this.isstdcnt +
            this.isutcnt;
    }
};

pub fn parseHeader(reader: anytype, seekableStream: anytype) !TZifHeader {
    var magic_buf: [4]u8 = undefined;
    try reader.readNoEof(&magic_buf);
    if (!std.mem.eql(u8, "TZif", &magic_buf)) {
        log.warn("File is missing magic string 'TZif'", .{});
        return error.InvalidFormat;
    }

    // Check verison
    const version = reader.readEnum(Version, .Little) catch |err| switch (err) {
        error.InvalidValue => return error.UnsupportedVersion,
        else => |e| return e,
    };
    if (version == .V1) {
        return error.UnsupportedVersion;
    }

    // Seek past reserved bytes
    try seekableStream.seekBy(15);

    return TZifHeader{
        .version = version,
        .isutcnt = try reader.readInt(u32, .Big),
        .isstdcnt = try reader.readInt(u32, .Big),
        .leapcnt = try reader.readInt(u32, .Big),
        .timecnt = try reader.readInt(u32, .Big),
        .typecnt = try reader.readInt(u32, .Big),
        .charcnt = try reader.readInt(u32, .Big),
    };
}

pub fn parse(allocator: std.mem.Allocator, reader: anytype, seekableStream: anytype) !TimeZone {
    const v1_header = try parseHeader(reader, seekableStream);
    try seekableStream.seekBy(v1_header.dataSize(.V1));

    const v2_header = try parseHeader(reader, seekableStream);

    // Parse transition times
    var transition_times = try allocator.alloc(i64, v2_header.timecnt);
    errdefer allocator.free(transition_times);
    {
        var prev: i64 = -(2 << 59); // Earliest time supported, this is earlier than the big bang
        var i: usize = 0;
        while (i < transition_times.len) : (i += 1) {
            transition_times[i] = try reader.readInt(i64, .Big);
            if (transition_times[i] <= prev) {
                return error.InvalidFormat;
            }
            prev = transition_times[i];
        }
    }

    // Parse transition types
    var transition_types = try allocator.alloc(u8, v2_header.timecnt);
    errdefer allocator.free(transition_types);
    try reader.readNoEof(transition_types);
    for (transition_types) |transition_type| {
        if (transition_type >= v2_header.typecnt) {
            return error.InvalidFormat; // a transition type index is out of bounds
        }
    }

    // Parse local time type records
    var local_time_types = try allocator.alloc(LocalTimeType, v2_header.typecnt);
    errdefer allocator.free(local_time_types);
    {
        var i: usize = 0;
        while (i < local_time_types.len) : (i += 1) {
            local_time_types[i].utoff = try reader.readInt(i32, .Big);
            local_time_types[i].dst = switch (try reader.readByte()) {
                0 => false,
                1 => true,
                else => return error.InvalidFormat,
            };

            local_time_types[i].idx = try reader.readByte();
            if (local_time_types[i].idx >= v2_header.charcnt) {
                return error.InvalidFormat;
            }
        }
    }

    // Read designations
    var time_zone_designations = try allocator.alloc(u8, v2_header.charcnt);
    errdefer allocator.free(time_zone_designations);
    try reader.readNoEof(time_zone_designations);

    // Parse leap seconds records
    var leap_seconds = try allocator.alloc(LeapSecond, v2_header.leapcnt);
    errdefer allocator.free(leap_seconds);
    {
        var i: usize = 0;
        while (i < leap_seconds.len) : (i += 1) {
            leap_seconds[i].occur = try reader.readInt(i64, .Big);
            if (i == 0 and leap_seconds[i].occur < 0) {
                return error.InvalidFormat;
            } else if (i != 0 and leap_seconds[i].occur - leap_seconds[i - 1].occur < 2419199) {
                return error.InvalidFormat; // There must be at least 28 days worth of seconds between leap seconds
            }

            leap_seconds[i].corr = try reader.readInt(i32, .Big);
            if (i == 0 and (leap_seconds[0].corr != 1 and leap_seconds[0].corr != -1)) {
                log.warn("First leap second correction is not 1 or -1: {}", .{leap_seconds[0]});
                return error.InvalidFormat;
            } else if (i != 0) {
                const diff = leap_seconds[i].corr - leap_seconds[i - 1].corr;
                if (diff != 1 and diff != -1) {
                    log.warn("Too large of a difference between leap seconds: {}", .{diff});
                    return error.InvalidFormat;
                }
            }
        }
    }

    // Parse standard/wall indicators
    var transition_is_std = try allocator.alloc(bool, v2_header.isstdcnt);
    errdefer allocator.free(transition_is_std);
    {
        var i: usize = 0;
        while (i < transition_is_std.len) : (i += 1) {
            transition_is_std[i] = switch (try reader.readByte()) {
                1 => true,
                0 => false,
                else => return error.InvalidFormat,
            };
        }
    }

    // Parse UT/local indicators
    var transition_is_ut = try allocator.alloc(bool, v2_header.isutcnt);
    errdefer allocator.free(transition_is_ut);
    {
        var i: usize = 0;
        while (i < transition_is_ut.len) : (i += 1) {
            transition_is_ut[i] = switch (try reader.readByte()) {
                1 => true,
                0 => false,
                else => return error.InvalidFormat,
            };
        }
    }

    // Parse TZ string from footer
    if ((try reader.readByte()) != '\n') return error.InvalidFormat;
    const tz_string = try reader.readUntilDelimiterAlloc(allocator, '\n', 60);
    errdefer allocator.free(tz_string);

    const posixTZ: ?TZ = if (tz_string.len > 0)
        try posix.parse(tz_string)
    else
        null;

    return TimeZone{
        .allocator = allocator,
        .version = v2_header.version,
        .transitionTimes = transition_times,
        .transitionTypes = transition_types,
        .localTimeTypes = local_time_types,
        .designations = time_zone_designations,
        .leapSeconds = leap_seconds,
        .transitionIsStd = transition_is_std,
        .transitionIsUT = transition_is_ut,
        .string = tz_string,
        .posixTZ = posixTZ,
    };
}

pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) !TimeZone {
    const cwd = std.fs.cwd();

    const file = try cwd.openFile(path, .{});
    defer file.close();

    return parse(allocator, file.reader(), file.seekableStream());
}

test "parse invalid bytes" {
    var fbs = std.io.fixedBufferStream("dflkasjreklnlkvnalkfek");
    try testing.expectError(error.InvalidFormat, parse(std.testing.allocator, fbs.reader(), fbs.seekableStream()));
}

test "parse UTC zoneinfo" {
    var fbs = std.io.fixedBufferStream(@embedFile("zoneinfo/UTC"));

    const res = try parse(std.testing.allocator, fbs.reader(), fbs.seekableStream());
    defer res.deinit();

    try testing.expectEqual(Version.V2, res.version);
    try testing.expectEqualSlices(i64, &[_]i64{}, res.transitionTimes);
    try testing.expectEqualSlices(u8, &[_]u8{}, res.transitionTypes);
    try testing.expectEqualSlices(LocalTimeType, &[_]LocalTimeType{.{ .utoff = 0, .dst = false, .idx = 0 }}, res.localTimeTypes);
    try testing.expectEqualSlices(u8, "UTC\x00", res.designations);
}

test "parse Pacific/Honolulu zoneinfo and calculate local times" {
    const transition_times = [7]i64{ -2334101314, -1157283000, -1155436200, -880198200, -769395600, -765376200, -712150200 };
    const transition_types = [7]u8{ 1, 2, 1, 3, 4, 1, 5 };
    const local_time_types = [6]LocalTimeType{
        .{ .utoff = -37886, .dst = false, .idx = 0 },
        .{ .utoff = -37800, .dst = false, .idx = 4 },
        .{ .utoff = -34200, .dst = true, .idx = 8 },
        .{ .utoff = -34200, .dst = true, .idx = 12 },
        .{ .utoff = -34200, .dst = true, .idx = 16 },
        .{ .utoff = -36000, .dst = false, .idx = 4 },
    };
    const designations = "LMT\x00HST\x00HDT\x00HWT\x00HPT\x00";
    const is_std = &[6]bool{ false, false, false, false, true, false };
    const is_ut = &[6]bool{ false, false, false, false, true, false };
    const string = "HST10";

    var fbs = std.io.fixedBufferStream(@embedFile("zoneinfo/Pacific/Honolulu"));

    const res = try parse(std.testing.allocator, fbs.reader(), fbs.seekableStream());
    defer res.deinit();

    try testing.expectEqual(Version.V2, res.version);
    try testing.expectEqualSlices(i64, &transition_times, res.transitionTimes);
    try testing.expectEqualSlices(u8, &transition_types, res.transitionTypes);
    try testing.expectEqualSlices(LocalTimeType, &local_time_types, res.localTimeTypes);
    try testing.expectEqualSlices(u8, designations, res.designations);
    try testing.expectEqualSlices(bool, is_std, res.transitionIsStd);
    try testing.expectEqualSlices(bool, is_ut, res.transitionIsUT);
    try testing.expectEqualSlices(u8, string, res.string);

    {
        const conversion = res.localTimeFromUTC(-1156939200).?;
        try testing.expectEqual(@as(i64, -1156973400), conversion.timestamp);
        try testing.expectEqual(true, conversion.dst);
        try testing.expectEqualSlices(u8, "HDT", conversion.designation);
    }
    {
        const conversion = res.localTimeFromUTC(1546300800).?;
        try testing.expectEqual(@as(i64, 1546300800) - 10 * std.time.s_per_hour, conversion.timestamp);
        try testing.expectEqual(false, conversion.dst);
        try testing.expectEqualSlices(u8, "HST", conversion.designation);
    }
}
