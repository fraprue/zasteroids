const std = @import("std");

const Audio = @import("audio.zig");
const Render = @import("render.zig");
const State = @import("state.zig");

const config_file_name = "config.ini";

pub const Config = struct {
    audio: Audio.Config,
    render: Render.Config,
    game: State.Config,
};

pub fn loadConfig() Config {
    var game_config = State.Config{};
    var audio_config = Audio.Config{};
    var render_config = Render.Config{};

    var config_file: ?std.fs.File = undefined;
    config_file = std.fs.cwd().openFile(config_file_name, .{ .mode = .read_only }) catch null;

    if (config_file) |file| {
        defer file.close();
        loadConfigSection(State.Config, &game_config, "game", file) catch std.debug.print("No game config section found. Using default game config.\n", .{});
        loadConfigSection(Audio.Config, &audio_config, "audio", file) catch std.debug.print("No audio config section found. Using default audio config.\n", .{});
        loadConfigSection(Render.Config, &render_config, "graphics", file) catch std.debug.print("No graphics config section found. Using default graphics config.\n", .{});
        std.debug.print("Config loaded successfully from {s}.\n", .{config_file_name});
    } else {
        std.debug.print("No config file found. Using default config.\n", .{});
    }
    return Config{
        .audio = audio_config,
        .render = render_config,
        .game = game_config,
    };
}

fn loadConfigSection(comptime T: type, config: *T, section_name: []const u8, config_file: std.fs.File) !void {
    var file_buffer: [512]u8 = undefined;
    var reader = config_file.reader(&file_buffer);

    var section_line = try reader.interface.takeDelimiter('\n');
    while (section_line != null) {
        const trimmed_section_line = std.mem.trim(u8, section_line.?, "\r[]");
        if (std.mem.eql(u8, trimmed_section_line, section_name)) {
            // Found the section header, now read the key-value pairs
            var value_line = try reader.interface.takeDelimiter('\n');
            while (value_line != null) {
                const trimmed_value_line = std.mem.trim(u8, value_line.?, "\r");
                if (std.mem.startsWith(u8, trimmed_value_line, "[") and std.mem.endsWith(u8, trimmed_value_line, "]")) {
                    // Reached the next section header, stop reading this section
                    break;
                }

                var it = std.mem.splitScalar(u8, trimmed_value_line, '=');
                const key = it.next() orelse continue;
                const value_str = it.next() orelse continue;

                inline for (@typeInfo(T).@"struct".fields) |field| {
                    if (std.mem.eql(u8, key, field.name)) {
                        const field_type = @TypeOf(@field(config, field.name));
                        if (field_type == bool) {
                            @field(config, field.name) = try std.fmt.parseInt(u8, value_str, 10) != 0;
                        } else if (field_type == f32) {
                            @field(config, field.name) = try std.fmt.parseFloat(field_type, value_str);
                        } else if (field_type == i16) {
                            @field(config, field.name) = try std.fmt.parseInt(field_type, value_str, 10);
                        } else {
                            std.debug.print("Unsupported config field type for key {s}\n", .{key});
                        }
                        break;
                    }
                }

                value_line = try reader.interface.takeDelimiter('\n');
            }
            return;
        }
        section_line = try reader.interface.takeDelimiter('\n');
    }
    return error.SectionNotFound;
}

pub fn saveConfig(config: Config) void {
    var config_file = std.fs.cwd().createFile(config_file_name, .{}) catch |err| {
        std.debug.print("Failed to create config file. Error: {}\n", .{err});
        return;
    };
    defer config_file.close();

    var file_buffer: [512]u8 = undefined;
    var writer = config_file.writer(&file_buffer);
    defer writer.interface.flush() catch |err| std.debug.print("Failed to flush config file. Error: {}\n", .{err});

    saveConfigSection(State.Config, &config.game, "game", &writer) catch |err| std.debug.print("Failed to save game config section. Error: {}\n", .{err});
    saveConfigSection(Audio.Config, &config.audio, "audio", &writer) catch |err| std.debug.print("Failed to save audio config section. Error: {}\n", .{err});
    saveConfigSection(Render.Config, &config.render, "graphics", &writer) catch |err| std.debug.print("Failed to save graphics config section. Error: {}\n", .{err});

    std.debug.print("Config saved successfully to {s}.\n", .{config_file_name});
}

fn saveConfigSection(comptime T: type, config: *const T, section_name: []const u8, config_writer: *std.fs.File.Writer) !void {
    try config_writer.interface.print("[{s}]\n", .{section_name});

    inline for (@typeInfo(T).@"struct".fields) |field| {
        const field_name = field.name;
        const field_value = @field(config, field_name);
        if (@TypeOf(field_value) == bool) {
            try config_writer.interface.print("{s}={d}\n", .{ field_name, @intFromBool(field_value) });
        } else {
            try config_writer.interface.print("{s}={d}\n", .{ field_name, field_value });
        }
    }
}
