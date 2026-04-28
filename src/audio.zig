const std = @import("std");

const zaudio = @import("zaudio");
const ztracy = @import("ztracy");

const content_dir = @import("build_options").content_dir;

const State = @import("state.zig");

pub const Config = struct {
    master_volume: f32 = 1.0,
    music_volume: f32 = 1.0,
    sound_volume: f32 = 1.0,
};

pub const AudioState = struct {
    config: Config,
    device: *zaudio.Device,
    engine: *zaudio.Engine,
    mutex: std.Thread.Mutex = .{},
    sounds: std.ArrayList(*zaudio.Sound),
    sfx_group: *zaudio.SoundGroup,
    music: *zaudio.Sound,
    spawned_sounds: std.ArrayList(*zaudio.Sound),

    fn audioCallback(
        device: *zaudio.Device,
        output: ?*anyopaque,
        _: ?*const anyopaque,
        frame_count: u32,
    ) callconv(.c) void {
        const tracy_zone = ztracy.ZoneNC(@src(), "Audio Update", 0x00_00_ff_00);
        defer tracy_zone.End();

        const audio = @as(*AudioState, @ptrCast(@alignCast(device.getUserData())));

        audio.engine.asNodeGraphMut().readPcmFrames(output.?, frame_count, null) catch {};
    }

    pub fn init(self: *AudioState, allocator: std.mem.Allocator, config: Config) !void {
        zaudio.init(allocator);

        const device = device: {
            var device_config = zaudio.Device.Config.init(.playback);
            device_config.data_callback = audioCallback;
            device_config.user_data = self;
            device_config.sample_rate = 48_000;
            device_config.period_size_in_frames = 480;
            device_config.period_size_in_milliseconds = 10;
            device_config.playback.format = .float32;
            device_config.playback.channels = 2;
            break :device try zaudio.Device.create(null, device_config);
        };

        const engine = engine: {
            var engine_config = zaudio.Engine.Config.init();
            engine_config.device = device;
            engine_config.no_auto_start = .true32;
            break :engine try zaudio.Engine.create(engine_config);
        };

        const sfx_group = try engine.createSoundGroup(.{}, null);

        const music = try engine.createSoundFromFile(
            content_dir ++ "custom_music.wav",
            .{ .flags = .{
                .looping = true,
                .stream = true,
            } },
        );

        self.* = .{
            .config = config,
            .device = device,
            .engine = engine,
            .sounds = .empty,
            .sfx_group = sfx_group,
            .music = music,
            .spawned_sounds = .empty,
        };

        try self.sounds.append(allocator, try self.engine.createSoundFromFile(
            content_dir ++ "lasershot.wav",
            .{ .sgroup = self.sfx_group },
        ));
        try self.sounds.append(allocator, try self.engine.createSoundFromFile(
            content_dir ++ "blip.wav",
            .{ .sgroup = self.sfx_group },
        ));

        try self.sfx_group.asNodeMut().attachOutputBus(0, self.engine.asNodeGraphMut().getEndpointMut(), 0);

        try self.music.asNodeMut().attachOutputBus(0, self.engine.asNodeGraphMut().getEndpointMut(), 0);
        try self.music.start();

        self.configChanged();
    }

    pub fn deinit(self: *AudioState, allocator: std.mem.Allocator) void {
        for (self.spawned_sounds.items) |sound| sound.destroy();
        self.spawned_sounds.deinit(allocator);
        for (self.sounds.items) |sound| sound.destroy();
        self.sounds.deinit(allocator);
        self.sfx_group.destroy();
        self.music.destroy();
        self.engine.destroy();
        self.device.destroy();

        zaudio.deinit();
    }

    pub fn storeConfig(self: *AudioState) !void {
        try self.config.storeToFile();
    }

    pub fn defaultConfig(self: *AudioState) void {
        self.setConfig(Config{});
    }

    pub fn setConfig(self: *AudioState, config: Config) void {
        self.config = config;
        self.configChanged();
    }

    fn configChanged(self: *AudioState) void {
        self.setMasterVolume(self.config.master_volume);
        self.setMusicVolume(self.config.music_volume);
        self.setSoundVolume(self.config.sound_volume);
    }

    pub fn setMasterVolume(self: *AudioState, volume: f32) void {
        self.config.master_volume = volume;
        self.engine.setVolume(volume) catch unreachable;
    }

    pub fn setMusicVolume(self: *AudioState, volume: f32) void {
        self.config.music_volume = volume;
        self.music.setVolume(volume);
    }

    pub fn setSoundVolume(self: *AudioState, volume: f32) void {
        self.config.sound_volume = volume;
        self.sfx_group.setVolume(volume);
    }

    pub fn spawnSound(self: *AudioState, allocator: std.mem.Allocator, sound_idx: u8) !void {
        const tracy_zone = ztracy.ZoneNC(@src(), "Spawn Sound", 0x00_00_ff_00);
        defer tracy_zone.End();

        var sound: *zaudio.Sound = undefined;
        switch (sound_idx) {
            0...1 => {
                sound = try self.engine.createSoundCopy(self.sounds.items[sound_idx], .{}, self.sfx_group);
            },
            else => return error.InvalidSoundIndex,
        }

        try self.spawned_sounds.append(allocator, sound);
        try sound.start();
    }

    pub fn cleanupFinishedSounds(self: *AudioState) void {
        var i: usize = 0;
        while (i < self.spawned_sounds.items.len) {
            const sound = self.spawned_sounds.items[i];
            if (!sound.isPlaying()) {
                sound.destroy();
                _ = self.spawned_sounds.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};
