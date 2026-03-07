const std = @import("std");

const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const zgui = @import("zgui");

const content_dir = @import("build_options").content_dir;

const State = @import("state.zig");

// zig fmt: off
const wgsl_shader =
\\  @group(0) @binding(0) var<uniform> offsetRotationScale: vec4<f32>;
\\  struct VertexOut {
\\      @builtin(position) position_clip: vec4<f32>,
\\      @location(0) color: vec4<f32>,
\\  }
\\  @vertex fn vs_main(
\\      @location(0) vertex: vec2<f32>,
\\      @location(1) color: vec4<f32>,
\\  ) -> VertexOut {
\\      let sinV = sin(offsetRotationScale[2]);
\\      let cosV = cos(offsetRotationScale[2]);
\\      var output: VertexOut;
\\
\\      var newVertex: vec2<f32>;
\\      newVertex[0] = offsetRotationScale[3] * vertex[0] * cosV - offsetRotationScale[3] * vertex[1] * sinV + offsetRotationScale[0];
\\      newVertex[1] = offsetRotationScale[3] * vertex[0] * sinV + offsetRotationScale[3] * vertex[1] * cosV + offsetRotationScale[1];
\\      output.position_clip = vec4(newVertex, 0.0, 1.0);
\\      output.color = color;
\\      return output;
\\  }
\\  @fragment fn fs_main(
\\      vertOut: VertexOut,
\\  ) -> @location(0) vec4<f32> {
\\      return vertOut.color;
\\  }
// zig fmt: on
;

pub const Vertex = struct {
    position: [2]f32,
    color: [4]f32,
};

pub const MeshType = enum(u32) { triangle, asteroid };

pub const Mesh = struct {
    index_offset: u32,
    vertex_offset: i32,
    num_indices: u32,
    num_vertices: u32,
    collision_sphere_radius: f32,
};

const ShaderInputType = [4]f32; //posX, posY, rotation, scale

pub const Config = struct {
    vsync: bool,
};

pub const GraphicsState = struct {
    config: Config,
    window: *zglfw.Window,
    gctx: *zgpu.GraphicsContext,
    pipeline: zgpu.RenderPipelineHandle,
    bind_group: zgpu.BindGroupHandle,
    vertex_buffer: zgpu.BufferHandle,
    index_buffer: zgpu.BufferHandle,

    meshes: std.ArrayList(Mesh),

    pub fn init(self: *GraphicsState, allocator: std.mem.Allocator) !void {
        try zglfw.init();
        zglfw.windowHint(.client_api, .no_api);

        zgui.init(allocator);
        zgui.plot.init();

        const window = try zglfw.Window.create(1400, 800, "", null, null);
        window.setSizeLimits(400, 400, -1, -1);
        zglfw.makeContextCurrent(window);

        const gctx = try zgpu.GraphicsContext.create(
            allocator,
            .{
                .window = window,
                .fn_getTime = @ptrCast(&zglfw.getTime),
                .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
                .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
                .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
                .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
                .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
                .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
                .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
            },
            .{},
        );
        errdefer gctx.destroy(allocator);

        var arena_allocator_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_allocator_state.deinit();
        const arena_allocator = arena_allocator_state.allocator();

        const full_font_path = std.fs.path.joinZ(arena_allocator, &.{ std.fs.selfExeDirPathAlloc(arena_allocator) catch unreachable, content_dir, "Roboto-Medium.ttf" }) catch unreachable;

        const scale_factor = scale_factor: {
            const scale = window.getContentScale();
            break :scale_factor @max(scale[0], scale[1]);
        };

        _ = zgui.io.addFontFromFile(
            full_font_path,
            std.math.floor(16.0 * scale_factor),
        );

        zgui.backend.init(
            window,
            gctx.device,
            @intFromEnum(zgpu.GraphicsContext.swapchain_format),
            @intFromEnum(zgpu.wgpu.TextureFormat.undef),
        );
        zgui.getStyle().scaleAllSizes(scale_factor);

        const bind_group_layout = gctx.createBindGroupLayout(&.{
            zgpu.bufferEntry(0, .{ .vertex = true }, .uniform, true, 0),
        });
        defer gctx.releaseResource(bind_group_layout);

        const bind_group = gctx.createBindGroup(bind_group_layout, &.{
            .{
                .binding = 0,
                .buffer_handle = gctx.uniforms.buffer,
                .offset = 0,
                .size = @sizeOf(ShaderInputType),
            },
        });

        var meshes: std.ArrayList(Mesh) = .empty;
        var meshes_indices: std.ArrayList(u32) = .empty;
        defer meshes_indices.deinit(allocator);
        var meshes_vertices: std.ArrayList(Vertex) = .empty;
        defer meshes_vertices.deinit(allocator);
        initMeshes(allocator, &meshes, &meshes_indices, &meshes_vertices);

        const total_num_vertices = @as(u32, @intCast(meshes_vertices.items.len));
        const total_num_indices = @as(u32, @intCast(meshes_indices.items.len));
        // std.debug.print("Num vertices: {d}, Num indices: {d}\n", .{ total_num_vertices, total_num_indices });
        // std.debug.print("Vertex buffer size: {d}\n", .{total_num_vertices * @sizeOf(Vertex)});

        const vertex_buffer = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .vertex = true },
            .size = total_num_vertices * @sizeOf(Vertex),
        });

        gctx.queue.writeBuffer(gctx.lookupResource(vertex_buffer).?, 0, Vertex, meshes_vertices.items);

        const index_buffer = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .index = true },
            .size = total_num_indices * @sizeOf(u32),
        });
        gctx.queue.writeBuffer(gctx.lookupResource(index_buffer).?, 0, u32, meshes_indices.items);

        const pipeline_layout = gctx.createPipelineLayout(&.{bind_group_layout});
        defer gctx.releaseResource(pipeline_layout);

        const pipeline = pipeline: {
            const shader_module = zgpu.createWgslShaderModule(gctx.device, wgsl_shader, "shader");
            defer shader_module.release();

            const color_targets = [_]zgpu.wgpu.ColorTargetState{.{
                .format = zgpu.GraphicsContext.swapchain_format,
            }};

            const vertex_attributes = [_]zgpu.wgpu.VertexAttribute{
                .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
                .{ .format = .float32x4, .offset = @offsetOf(Vertex, "color"), .shader_location = 1 },
            };
            const vertex_buffers = [_]zgpu.wgpu.VertexBufferLayout{.{
                .array_stride = @sizeOf(Vertex),
                .attribute_count = vertex_attributes.len,
                .attributes = &vertex_attributes,
            }};

            const pipeline_descriptor = zgpu.wgpu.RenderPipelineDescriptor{
                .vertex = zgpu.wgpu.VertexState{
                    .module = shader_module,
                    .entry_point = "vs_main",
                    .buffer_count = vertex_buffers.len,
                    .buffers = &vertex_buffers,
                },
                .primitive = zgpu.wgpu.PrimitiveState{
                    .front_face = .ccw,
                    .cull_mode = .none,
                    .topology = .triangle_list,
                },
                .fragment = &zgpu.wgpu.FragmentState{
                    .module = shader_module,
                    .entry_point = "fs_main",
                    .target_count = color_targets.len,
                    .targets = &color_targets,
                },
            };
            break :pipeline gctx.createRenderPipeline(pipeline_layout, pipeline_descriptor);
        };

        const config = Config{
            .vsync = true,
        };

        self.* = .{
            .config = config,
            .window = window,
            .gctx = gctx,
            .pipeline = pipeline,
            .bind_group = bind_group,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,

            .meshes = meshes,
        };

        self.setVSync(true);
    }

    pub fn deinit(self: *GraphicsState, allocator: std.mem.Allocator) void {
        self.window.destroy();
        self.gctx.releaseResource(self.pipeline);
        self.gctx.releaseResource(self.bind_group);
        self.gctx.destroy(allocator);

        self.meshes.deinit(allocator);

        zgui.backend.deinit();
        zgui.plot.deinit();
        zgui.deinit();
        zglfw.terminate();
    }

    pub fn setVSync(self: *GraphicsState, value: bool) void {
        const gctx = self.gctx;
        self.config.vsync = value;
        if (value) {
            gctx.swapchain_descriptor.present_mode = zgpu.wgpu.PresentMode.fifo;
            // zglfw.swapInterval(1);
        } else {
            gctx.swapchain_descriptor.present_mode = zgpu.wgpu.PresentMode.immediate;
            // zglfw.swapInterval(0);
        }

        gctx.swapchain.release();
        gctx.swapchain = gctx.device.createSwapChain(
            gctx.surface,
            gctx.swapchain_descriptor,
        );
    }
};

fn initMeshes(
    allocator: std.mem.Allocator,
    meshes: *std.ArrayList(Mesh),
    meshes_indices: *std.ArrayList(u32),
    meshes_vertices: *std.ArrayList(Vertex),
) void {
    // Basic Triangle
    {
        const vertex_data = [_]Vertex{
            .{ .position = [2]f32{ 0.0, 1.0 }, .color = [4]f32{ 1.0, 0.0, 0.0, 1.0 } },
            .{ .position = [2]f32{ -1.0, -1.0 }, .color = [4]f32{ 0.0, 1.0, 0.0, 1.0 } },
            .{ .position = [2]f32{ 1.0, -1.0 }, .color = [4]f32{ 0.0, 0.0, 1.0, 1.0 } },
        };

        const index_data = [_]u32{ 0, 1, 2 };

        appendMesh(
            allocator,
            &vertex_data,
            &index_data,
            meshes,
            meshes_indices,
            meshes_vertices,
        );
    }

    // Basic Asteroid
    {
        const vertex_data = [_]Vertex{
            .{ .position = [2]f32{ 0.0, 1.0 }, .color = [4]f32{ 0.5, 0.5, 0.0, 1.0 } },
            .{ .position = [2]f32{ -0.7, 0.0 }, .color = [4]f32{ 0.5, 0.5, 0.0, 1.0 } },
            .{ .position = [2]f32{ -0.3, -1.0 }, .color = [4]f32{ 0.5, 0.5, 0.0, 1.0 } },
            .{ .position = [2]f32{ 0.3, -1.0 }, .color = [4]f32{ 0.5, 0.5, 0.0, 1.0 } },
            .{ .position = [2]f32{ 0.7, 0.0 }, .color = [4]f32{ 0.5, 0.5, 0.0, 1.0 } },
        };

        const index_data = [_]u32{ 0, 1, 4, 1, 2, 4, 2, 3, 4 };

        appendMesh(
            allocator,
            &vertex_data,
            &index_data,
            meshes,
            meshes_indices,
            meshes_vertices,
        );
    }
}

fn appendMesh(
    allocator: std.mem.Allocator,
    vertex_data: []const Vertex,
    index_data: []const u32,
    meshes: *std.ArrayList(Mesh),
    meshes_indices: *std.ArrayList(u32),
    meshes_vertices: *std.ArrayList(Vertex),
) void {
    // Approximate radius of collision sphere, based on vertex data.
    // Assume that mesh is centered around (0,0).
    // TODO: Utilize SIMD and avoid usage of sqrt
    var collision_sphere_radius: f32 = 0.0;
    for (vertex_data) |vertex| {
        const vertex_distance = std.math.sqrt(vertex.position[0] * vertex.position[0] + vertex.position[1] * vertex.position[1]);
        if (vertex_distance > collision_sphere_radius) {
            collision_sphere_radius = vertex_distance;
        }
    }

    meshes.append(allocator, .{
        .index_offset = @as(u32, @intCast(meshes_indices.items.len)),
        .vertex_offset = @as(i32, @intCast(meshes_vertices.items.len)),
        .num_indices = @as(u32, @intCast(index_data.len)),
        .num_vertices = @as(u32, @intCast(vertex_data.len)),
        .collision_sphere_radius = collision_sphere_radius,
    }) catch unreachable;

    meshes_indices.appendSlice(allocator, index_data) catch unreachable;
    meshes_vertices.appendSlice(allocator, vertex_data) catch unreachable;
}

pub fn render(allocator: std.mem.Allocator, state: *State.State, graphics: *GraphicsState) void {
    const gctx = graphics.gctx;

    const window_name = "My First Game";
    const window_width = gctx.swapchain_descriptor.width;
    const window_height = gctx.swapchain_descriptor.height;

    const window_title: [:0]u8 = std.fmt.allocPrintSentinel(allocator, "{s}, Player: {s}, Res: {}×{}", .{
        window_name,
        state.player_name,
        window_width,
        window_height,
    }, 0) catch unreachable;
    defer allocator.free(window_title);

    zglfw.setWindowTitle(graphics.window, window_title);

    zglfw.pollEvents();

    zgui.backend.newFrame(
        window_width,
        window_height,
    );

    // Set the settings menu position to custom values
    zgui.setNextWindowPos(.{ .x = 20.0, .y = 20.0, .cond = .once });

    if (zgui.begin("Settings", .{ .flags = .{ .always_auto_resize = true } })) {
        zgui.bulletText(
            "Average: {d:.3} ms/frame ({d:.1} fps)",
            .{ gctx.stats.average_cpu_time, gctx.stats.fps },
        );

        _ = zgui.checkbox("Debug", .{ .v = &state.debug_state.enabled });

        if (state.debug_state.enabled) {
            {
                var frame_time_data = allocator.create(State.FrameStatsDataPoint) catch unreachable;
                frame_time_data.time = gctx.stats.time;
                frame_time_data.avg_cpu_time = gctx.stats.average_cpu_time;
                frame_time_data.fps = gctx.stats.fps;
                frame_time_data.avg_render_time = state.debug_state.avg_render_perf_in_ns / std.time.ns_per_us;
                state.frame_time_history.append(&frame_time_data.node);
                while (state.frame_time_history.len() > 100) {
                    const node = state.frame_time_history.popFirst() orelse unreachable;
                    const data_point: *State.FrameStatsDataPoint = @fieldParentPtr("node", node);
                    allocator.destroy(data_point);
                }
            }

            zgui.bulletText(
                "Avg Update: {d} µs, Avg Render: ({d} µs)",
                .{ state.debug_state.avg_update_perf_in_ns / 1000, state.debug_state.avg_render_perf_in_ns / 1000 },
            );
            if (zgui.plot.beginPlot("FPS Graph", .{ .h = 300.0 })) {
                defer zgui.plot.endPlot();
                zgui.plot.setupAxis(.x1, .{
                    .label = "time",
                    .flags = .{
                        .no_tick_labels = true,
                        .auto_fit = true,
                    },
                });
                zgui.plot.setupAxis(.y1, .{
                    .label = "FPS",
                });
                zgui.plot.setupAxis(.y2, .{
                    .label = "Avg CPU (µs)",
                    .flags = .{ .opposite = true },
                });
                zgui.plot.setupAxis(.y3, .{
                    .label = "Avg Render (µs)",
                    .flags = .{ .opposite = true },
                });
                zgui.plot.setupAxisLimits(.y1, .{ .min = 0, .max = 160 });
                zgui.plot.setupAxisLimits(.y2, .{ .min = 0, .max = 20 });
                zgui.plot.setupAxisLimits(.y3, .{ .min = 0, .max = 8000 });
                zgui.plot.setupLegend(.{ .north = true, .west = true }, .{ .horizontal = true });
                zgui.plot.setupFinish();

                const frame_time_line = State.FrameStatsLine.init(allocator, state.frame_time_history) catch unreachable;
                defer frame_time_line.deinit(allocator);
                zgui.plot.setAxis(zgui.plot.Axis.y1);
                zgui.plot.plotLine("FPS", f64, .{
                    .xv = frame_time_line.time_v,
                    .yv = frame_time_line.fps_v,
                });
                zgui.plot.setAxis(zgui.plot.Axis.y2);
                zgui.plot.plotLine("Avg CPU", f64, .{
                    .xv = frame_time_line.time_v,
                    .yv = frame_time_line.avg_cpu_time_v,
                });
                zgui.plot.setAxis(zgui.plot.Axis.y3);
                zgui.plot.plotLine("Avg Render", f64, .{
                    .xv = frame_time_line.time_v,
                    .yv = frame_time_line.avg_render_time_v,
                });
            }
            zgui.bulletText(
                "Object count : {d}",
                .{state.objects.count()},
            );

            _ = zgui.sliderFloat("Player Speed", .{
                .v = &state.config.player_speed,
                .min = 0.01,
                .max = 2.0,
            });

            _ = zgui.sliderFloat("Shot Delay", .{
                .v = &state.config.shot_delay,
                .min = 0.01,
                .max = 2.0,
            });
            _ = zgui.sliderFloat("Shot Speed", .{
                .v = &state.config.shot_speed,
                .min = 0.01,
                .max = 2.0,
            });

            _ = zgui.sliderFloat("Asteroid Spawn Delay", .{
                .v = &state.config.asteroid_spawn_delay,
                .min = 0.01,
                .max = 5.0,
            });
            _ = zgui.sliderFloat("Asteroid Speed", .{
                .v = &state.config.asteroid_speed,
                .min = 0.01,
                .max = 1.0,
            });
        }

        var vsync = graphics.config.vsync;
        if (zgui.checkbox("VSync", .{ .v = &vsync })) {
            graphics.setVSync(vsync);
        }

        var limit_fps = (state.config.fps_target > 0);
        _ = zgui.checkbox("Limit Framerate", .{ .v = &limit_fps });

        if (limit_fps) {
            if (state.config.fps_target <= 0) {
                state.config.fps_target = 60;
            }
            var fps_target = @as(i32, state.config.fps_target);
            if (zgui.sliderInt("Target FPS", .{ .v = &fps_target, .min = 30, .max = 160 })) {
                state.config.fps_target = @truncate(fps_target);
            }
        } else {
            state.config.fps_target = -1;
        }
    }
    zgui.end();

    if (state.game_state == State.GameState.starting) {
        // Set the starting menu position to custom values
        zgui.setNextWindowPos(.{
            .x = 0.5 * @as(f32, @floatFromInt(window_width)),
            .y = 0.3 * @as(f32, @floatFromInt(window_height)),
            .cond = .once,
        });
        if (zgui.begin("Start Menu", .{ .flags = .{ .always_auto_resize = true } })) {
            var player_name = [_:0]u8{0} ** 12;
            if (zgui.inputText(
                "Player Name",
                .{
                    .buf = player_name[0..],
                },
            )) {
                var i: usize = 0;
                var player_name_array = [_]u8{0} ** 12;
                while (player_name[i] != 0) : (i += 1) {
                    player_name_array[i] = player_name[i];
                }

                if (i != state.player_name.len) {
                    allocator.free(state.player_name);
                    state.player_name = allocator.alloc(u8, i) catch unreachable;
                }

                @memcpy(state.player_name, player_name_array[0..i]);
            }

            if (zgui.button("Start", .{})) {
                state.startGame();
            }
            zgui.sameLine(.{});
            if (zgui.button("Quit", .{})) {
                graphics.window.setShouldClose(true);
            }
        }
        zgui.end();
    }
    if (state.game_state == State.GameState.gameover) {
        // Set the starting menu position to custom values
        zgui.setNextWindowPos(.{
            .x = 0.5 * @as(f32, @floatFromInt(window_width)),
            .y = 0.3 * @as(f32, @floatFromInt(window_height)),
            .cond = .once,
        });
        if (zgui.begin("Gameover Menu", .{ .flags = .{ .always_auto_resize = true } })) {
            zgui.text("Git gud!", .{});
            if (zgui.button("Restart", .{})) {
                state.startGame();
            }
            zgui.sameLine(.{});
            if (zgui.button("Quit", .{})) {
                graphics.window.setShouldClose(true);
            }
        }
        zgui.end();
    }

    const back_buffer_view = gctx.swapchain.getCurrentTextureView();
    defer back_buffer_view.release();

    const commands = commands: {
        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        const color_attachments = [_]zgpu.wgpu.RenderPassColorAttachment{.{
            .view = back_buffer_view,
            .load_op = .load,
            .store_op = .store,
        }};
        const render_pass_info = zgpu.wgpu.RenderPassDescriptor{
            .color_attachment_count = color_attachments.len,
            .color_attachments = &color_attachments,
        };

        object_pass: {
            if (state.game_state != State.GameState.running) {
                break :object_pass;
            }

            const pass = encoder.beginRenderPass(render_pass_info);
            defer {
                pass.end();
                pass.release();
            }

            const pipeline = gctx.lookupResource(graphics.pipeline) orelse break :object_pass;
            pass.setPipeline(pipeline);

            var objects_iterator = state.objects.iterator();
            while (objects_iterator.next()) |render_object_entry| {
                const render_object = render_object_entry.value_ptr;
                const vb_info = gctx.lookupResourceInfo(graphics.vertex_buffer) orelse break :object_pass;
                const ib_info = gctx.lookupResourceInfo(graphics.index_buffer) orelse break :object_pass;
                const bind_group = gctx.lookupResource(graphics.bind_group) orelse break :object_pass;

                {
                    pass.setVertexBuffer(0, vb_info.gpuobj.?, 0, vb_info.size);
                    pass.setIndexBuffer(ib_info.gpuobj.?, .uint32, 0, ib_info.size);

                    const shader_inputs = ShaderInputType{
                        render_object.pos[0],
                        render_object.pos[1],
                        render_object.rot,
                        render_object.scale,
                    };

                    const mem = gctx.uniformsAllocate(ShaderInputType, 1);
                    mem.slice[0] = shader_inputs;

                    pass.setBindGroup(
                        @intCast(0),
                        bind_group,
                        &.{mem.offset},
                    );
                    const mesh_id = @intFromEnum(render_object.mesh_type);
                    pass.drawIndexed(
                        graphics.meshes.items[mesh_id].num_indices,
                        1,
                        graphics.meshes.items[mesh_id].index_offset,
                        graphics.meshes.items[mesh_id].vertex_offset,
                        0,
                    );
                }
            }
        }

        { //GUI pass
            const pass = encoder.beginRenderPass(render_pass_info);
            defer {
                pass.end();
                pass.release();
            }

            zgui.backend.draw(pass);
        }

        break :commands encoder.finish(null);
    };
    defer commands.release();

    gctx.submit(&.{commands});
    _ = gctx.present();
}
