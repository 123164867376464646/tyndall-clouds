use std::sync::Arc;
use std::time::Instant;

use winit::application::ApplicationHandler;
use winit::event::{ElementState, MouseButton, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop};
use winit::keyboard::{KeyCode, PhysicalKey};
use winit::window::{Window, WindowId};

// ---------- 可调参数(GUI 面板实时修改) ----------

#[derive(Clone, Copy)]
struct Params {
    // 云形
    coverage: f32,
    density: f32,
    detail_strength: f32,
    cloud_base: f32,
    cloud_top: f32,
    steps: f32,
    light_steps: f32,
    sigma: f32,
    // 动态
    wind_speed: f32,
    wind_angle_deg: f32,
    evolution: f32,
    time_scale: f32,
    // 光照
    sun_elev_deg: f32,
    sun_azim_deg: f32,
    sun_intensity: f32,
    ambient: f32,
    phase_g: f32,
    phase_back: f32,
    phase_mix: f32,
    // 丁达尔效应
    godray_intensity: f32,
    godray_steps: f32,
    haze: f32,
    // 显示
    exposure: f32,
    render_scale: f32,
}

impl Default for Params {
    fn default() -> Self {
        Self {
            coverage: 0.48,
            density: 2.4,
            detail_strength: 0.14,
            cloud_base: 1300.0,
            cloud_top: 3400.0,
            steps: 96.0,
            light_steps: 6.0,
            sigma: 0.075,
            wind_speed: 18.0,
            wind_angle_deg: 35.0,
            evolution: 0.8,
            time_scale: 1.0,
            sun_elev_deg: 9.0,
            sun_azim_deg: -28.0,
            sun_intensity: 30.0,
            ambient: 0.9,
            phase_g: 0.60,
            phase_back: 0.35,
            phase_mix: 0.25,
            godray_intensity: 1.8,
            godray_steps: 24.0,
            haze: 1.1,
            exposure: 1.0,
            render_scale: 0.75,
        }
    }
}

// 与 shader.wgsl 中 Uniforms 严格对应
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Uniforms {
    resolution: [f32; 2],
    time: f32,
    sun_intensity: f32,
    cam_pos: [f32; 3],
    coverage: f32,
    sun_dir: [f32; 3],
    density: f32,
    forward: [f32; 3],
    sigma: f32,
    right: [f32; 3],
    ambient: f32,
    up: [f32; 3],
    exposure: f32,
    cloud_base: f32,
    cloud_top: f32,
    steps: f32,
    light_steps: f32,
    wind_speed: f32,
    wind_angle: f32,
    evolution: f32,
    detail_strength: f32,
    phase_g: f32,
    phase_back: f32,
    phase_mix: f32,
    godray_intensity: f32,
    haze: f32,
    godray_steps: f32,
    _pad0: f32,
    _pad1: f32,
}

#[derive(Default)]
struct InputState {
    forward: bool,
    back: bool,
    left: bool,
    right: bool,
    up: bool,
    down: bool,
    fast: bool,
    dragging: bool,
    last_cursor: Option<(f64, f64)>,
}

struct State {
    window: Arc<Window>,
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,

    cloud_pipeline: wgpu::RenderPipeline,
    blit_pipeline: wgpu::RenderPipeline,
    uniform_buf: wgpu::Buffer,
    cloud_bind_group: wgpu::BindGroup,
    blit_bgl: wgpu::BindGroupLayout,
    blit_sampler: wgpu::Sampler,
    offscreen_view: wgpu::TextureView,
    offscreen_bind_group: wgpu::BindGroup,
    offscreen_size: (u32, u32),

    egui_ctx: egui::Context,
    egui_state: egui_winit::State,
    egui_renderer: egui_wgpu::Renderer,

    last_frame: Instant,
    anim_time: f32,
    fps: f32,
    params: Params,
    input: InputState,
    cam_pos: [f32; 3],
    yaw: f32,
    pitch: f32,
}

const OFFSCREEN_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba16Float;

fn create_offscreen(
    device: &wgpu::Device,
    blit_bgl: &wgpu::BindGroupLayout,
    sampler: &wgpu::Sampler,
    width: u32,
    height: u32,
) -> (wgpu::TextureView, wgpu::BindGroup) {
    let tex = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("offscreen"),
        size: wgpu::Extent3d {
            width: width.max(1),
            height: height.max(1),
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: OFFSCREEN_FORMAT,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
        view_formats: &[],
    });
    let view = tex.create_view(&wgpu::TextureViewDescriptor::default());
    let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("blit"),
        layout: blit_bgl,
        entries: &[
            wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::TextureView(&view),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: wgpu::BindingResource::Sampler(sampler),
            },
        ],
    });
    (view, bind_group)
}

// egui 默认字体不含中文，从系统字体目录加载一个 CJK 字体作为回退
fn install_cjk_font(ctx: &egui::Context) {
    let candidates = [
        "C:\\Windows\\Fonts\\msyh.ttc",
        "C:\\Windows\\Fonts\\msyhl.ttc",
        "C:\\Windows\\Fonts\\simhei.ttf",
        "C:\\Windows\\Fonts\\simsun.ttc",
    ];
    let mut fonts = egui::FontDefinitions::default();
    for path in candidates {
        if let Ok(data) = std::fs::read(path) {
            fonts
                .font_data
                .insert("cjk".to_owned(), Arc::new(egui::FontData::from_owned(data)));
            for family in [egui::FontFamily::Proportional, egui::FontFamily::Monospace] {
                fonts
                    .families
                    .entry(family)
                    .or_default()
                    .push("cjk".to_owned());
            }
            break;
        }
    }
    ctx.set_fonts(fonts);
}

impl State {
    fn new(window: Arc<Window>) -> Self {
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor::default());
        let surface = instance.create_surface(window.clone()).unwrap();

        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: Some(&surface),
            force_fallback_adapter: false,
        }))
        .expect("没有可用的图形适配器");

        let (device, queue) =
            pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor::default()))
                .expect("创建设备失败");

        let caps = surface.get_capabilities(&adapter);
        let format = caps
            .formats
            .iter()
            .copied()
            .find(|f| f.is_srgb())
            .unwrap_or(caps.formats[0]);

        let size = window.inner_size();
        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width: size.width.max(1),
            height: size.height.max(1),
            present_mode: wgpu::PresentMode::Fifo,
            alpha_mode: caps.alpha_modes[0],
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&device, &config);

        // ---- 云渲染管线(输出到离屏 HDR 纹理) ----
        let cloud_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("clouds"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shader.wgsl").into()),
        });

        let uniform_buf = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("uniforms"),
            size: std::mem::size_of::<Uniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let cloud_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: None,
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });

        let cloud_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &cloud_bgl,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: uniform_buf.as_entire_binding(),
            }],
        });

        let cloud_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: None,
            bind_group_layouts: &[&cloud_bgl],
            push_constant_ranges: &[],
        });

        let cloud_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("clouds"),
            layout: Some(&cloud_layout),
            vertex: wgpu::VertexState {
                module: &cloud_shader,
                entry_point: Some("vs_main"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &cloud_shader,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: OFFSCREEN_FORMAT,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        // ---- Blit 管线(离屏 -> 交换链) ----
        let blit_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("blit"),
            source: wgpu::ShaderSource::Wgsl(include_str!("blit.wgsl").into()),
        });

        let blit_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("blit"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });

        let blit_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("blit"),
            bind_group_layouts: &[&blit_bgl],
            push_constant_ranges: &[],
        });

        let blit_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("blit"),
            layout: Some(&blit_layout),
            vertex: wgpu::VertexState {
                module: &blit_shader,
                entry_point: Some("vs_main"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &blit_shader,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        let blit_sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("blit"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        let params = Params::default();
        let ow = (config.width as f32 * params.render_scale) as u32;
        let oh = (config.height as f32 * params.render_scale) as u32;
        let (offscreen_view, offscreen_bind_group) =
            create_offscreen(&device, &blit_bgl, &blit_sampler, ow, oh);

        // ---- egui ----
        let egui_ctx = egui::Context::default();
        install_cjk_font(&egui_ctx);
        let egui_state = egui_winit::State::new(
            egui_ctx.clone(),
            egui::ViewportId::ROOT,
            &window,
            None,
            None,
            None,
        );
        let egui_renderer = egui_wgpu::Renderer::new(&device, format, None, 1, false);

        let now = Instant::now();
        Self {
            window,
            surface,
            device,
            queue,
            config,
            cloud_pipeline,
            blit_pipeline,
            uniform_buf,
            cloud_bind_group,
            blit_bgl,
            blit_sampler,
            offscreen_view,
            offscreen_bind_group,
            offscreen_size: (ow.max(1), oh.max(1)),
            egui_ctx,
            egui_state,
            egui_renderer,
            last_frame: now,
            anim_time: 0.0,
            fps: 60.0,
            params,
            input: InputState::default(),
            cam_pos: [0.0, 320.0, 0.0],
            yaw: 0.0,
            pitch: 0.06,
        }
    }

    fn resize(&mut self, width: u32, height: u32) {
        self.config.width = width.max(1);
        self.config.height = height.max(1);
        self.surface.configure(&self.device, &self.config);
        self.ensure_offscreen();
    }

    fn ensure_offscreen(&mut self) {
        let ow = ((self.config.width as f32 * self.params.render_scale) as u32).max(1);
        let oh = ((self.config.height as f32 * self.params.render_scale) as u32).max(1);
        if (ow, oh) != self.offscreen_size {
            let (view, bg) =
                create_offscreen(&self.device, &self.blit_bgl, &self.blit_sampler, ow, oh);
            self.offscreen_view = view;
            self.offscreen_bind_group = bg;
            self.offscreen_size = (ow, oh);
        }
    }

    fn update_camera(&mut self, dt: f32) {
        let speed = if self.input.fast { 900.0 } else { 220.0 } * dt;
        let (sy, cy) = self.yaw.sin_cos();
        let fwd = [sy, 0.0, -cy];
        let right = [cy, 0.0, sy];
        let mut delta = [0.0f32; 3];
        let mut add = |v: [f32; 3], s: f32| {
            delta[0] += v[0] * s;
            delta[1] += v[1] * s;
            delta[2] += v[2] * s;
        };
        if self.input.forward {
            add(fwd, speed);
        }
        if self.input.back {
            add(fwd, -speed);
        }
        if self.input.right {
            add(right, speed);
        }
        if self.input.left {
            add(right, -speed);
        }
        if self.input.up {
            add([0.0, 1.0, 0.0], speed);
        }
        if self.input.down {
            add([0.0, 1.0, 0.0], -speed);
        }
        for i in 0..3 {
            self.cam_pos[i] += delta[i];
        }
        self.cam_pos[1] = self.cam_pos[1].max(2.0);
    }

    fn build_ui(ctx: &egui::Context, p: &mut Params, fps: f32, offscreen: (u32, u32)) {
        egui::Window::new("☁ 体积云参数")
            .anchor(egui::Align2::RIGHT_TOP, [-10.0, 10.0])
            .default_width(300.0)
            .show(ctx, |ui| {
                ui.label(format!(
                    "帧率 {fps:.0} FPS   |   渲染分辨率 {}×{}",
                    offscreen.0, offscreen.1
                ));
                ui.separator();

                egui::CollapsingHeader::new("☁ 云形")
                    .default_open(true)
                    .show(ui, |ui| {
                        ui.add(egui::Slider::new(&mut p.coverage, 0.30..=0.70).text("覆盖率"));
                        ui.add(egui::Slider::new(&mut p.density, 0.5..=5.0).text("密度"));
                        ui.add(egui::Slider::new(&mut p.detail_strength, 0.0..=0.35).text("细节侵蚀"));
                        ui.add(egui::Slider::new(&mut p.sigma, 0.03..=0.15).text("消光系数"));
                        ui.add(egui::Slider::new(&mut p.cloud_base, 400.0..=2500.0).text("云底高度 m"));
                        ui.add(egui::Slider::new(&mut p.cloud_top, 1500.0..=6000.0).text("云顶高度 m"));
                    });

                egui::CollapsingHeader::new("🌀 动态流动")
                    .default_open(true)
                    .show(ui, |ui| {
                        ui.add(egui::Slider::new(&mut p.wind_speed, 0.0..=80.0).text("风速 m/s"));
                        ui.add(egui::Slider::new(&mut p.wind_angle_deg, 0.0..=360.0).text("风向 °"));
                        ui.add(egui::Slider::new(&mut p.evolution, 0.0..=2.5).text("翻腾演化"));
                        ui.add(egui::Slider::new(&mut p.time_scale, 0.0..=4.0).text("时间流速"));
                    });

                egui::CollapsingHeader::new("☀ 光照与太阳")
                    .default_open(true)
                    .show(ui, |ui| {
                        ui.add(egui::Slider::new(&mut p.sun_elev_deg, 1.0..=80.0).text("太阳高度角 °"));
                        ui.add(egui::Slider::new(&mut p.sun_azim_deg, -180.0..=180.0).text("太阳方位角 °"));
                        ui.add(egui::Slider::new(&mut p.sun_intensity, 5.0..=80.0).text("阳光强度"));
                        ui.add(egui::Slider::new(&mut p.ambient, 0.0..=2.5).text("环境光"));
                        ui.add(egui::Slider::new(&mut p.phase_g, 0.30..=0.85).text("前向散射 g"));
                        ui.add(egui::Slider::new(&mut p.phase_mix, 0.0..=0.6).text("后向散射混合"));
                    });

                egui::CollapsingHeader::new("🌅 丁达尔效应")
                    .default_open(true)
                    .show(ui, |ui| {
                        ui.add(egui::Slider::new(&mut p.godray_intensity, 0.0..=4.0).text("光柱强度"));
                        ui.add(egui::Slider::new(&mut p.haze, 0.0..=3.0).text("大气雾密度"));
                        ui.add(egui::Slider::new(&mut p.godray_steps, 8.0..=64.0).text("光柱步进数"));
                    });

                egui::CollapsingHeader::new("🖥 渲染质量")
                    .default_open(false)
                    .show(ui, |ui| {
                        ui.add(egui::Slider::new(&mut p.steps, 32.0..=192.0).text("云步进数"));
                        ui.add(egui::Slider::new(&mut p.light_steps, 3.0..=8.0).text("光照步进数"));
                        ui.add(egui::Slider::new(&mut p.render_scale, 0.30..=1.0).text("渲染比例"));
                        ui.add(egui::Slider::new(&mut p.exposure, 0.4..=2.5).text("曝光"));
                    });

                ui.separator();
                ui.horizontal(|ui| {
                    if ui.button("重置默认").clicked() {
                        *p = Params::default();
                    }
                    if ui.button("黄昏光柱预设").clicked() {
                        *p = Params {
                            sun_elev_deg: 8.0,
                            sun_intensity: 46.0,
                            coverage: 0.55,
                            haze: 1.6,
                            godray_intensity: 2.0,
                            evolution: 1.0,
                            ..Params::default()
                        };
                    }
                });
                ui.label("WASD 移动 · Space/Ctrl 升降 · Shift 加速\n鼠标左键拖拽视角 · Esc 退出");
            });
    }

    fn render(&mut self) {
        let now = Instant::now();
        let dt = (now - self.last_frame).as_secs_f32().min(0.1);
        self.last_frame = now;
        if dt > 0.0 {
            self.fps = self.fps * 0.95 + (1.0 / dt) * 0.05;
        }
        self.anim_time += dt * self.params.time_scale;

        if !self.egui_ctx.wants_keyboard_input() {
            self.update_camera(dt);
        }

        // ---- egui 帧(可能修改 params) ----
        let raw_input = self.egui_state.take_egui_input(&self.window);
        let mut p = self.params;
        let fps = self.fps;
        let osize = self.offscreen_size;
        let full_output = self.egui_ctx.run(raw_input, |ctx| {
            Self::build_ui(ctx, &mut p, fps, osize);
        });
        p.cloud_top = p.cloud_top.max(p.cloud_base + 300.0);
        self.params = p;
        self.egui_state
            .handle_platform_output(&self.window, full_output.platform_output);

        self.ensure_offscreen();

        // ---- uniforms ----
        let (sy, cy) = self.yaw.sin_cos();
        let (sp, cp) = self.pitch.sin_cos();
        let forward = [sy * cp, sp, -cy * cp];
        let right = [cy, 0.0, sy];
        let up = [
            right[1] * forward[2] - right[2] * forward[1],
            right[2] * forward[0] - right[0] * forward[2],
            right[0] * forward[1] - right[1] * forward[0],
        ];
        let elev = self.params.sun_elev_deg.to_radians();
        let azim = self.params.sun_azim_deg.to_radians();
        let sun_dir = [
            elev.cos() * azim.sin(),
            elev.sin(),
            -elev.cos() * azim.cos(),
        ];

        let uniforms = Uniforms {
            resolution: [self.offscreen_size.0 as f32, self.offscreen_size.1 as f32],
            time: self.anim_time,
            sun_intensity: self.params.sun_intensity,
            cam_pos: self.cam_pos,
            coverage: self.params.coverage,
            sun_dir,
            density: self.params.density,
            forward,
            sigma: self.params.sigma,
            right,
            ambient: self.params.ambient,
            up,
            exposure: self.params.exposure,
            cloud_base: self.params.cloud_base,
            cloud_top: self.params.cloud_top,
            steps: self.params.steps,
            light_steps: self.params.light_steps,
            wind_speed: self.params.wind_speed,
            wind_angle: self.params.wind_angle_deg.to_radians(),
            evolution: self.params.evolution,
            detail_strength: self.params.detail_strength,
            phase_g: self.params.phase_g,
            phase_back: self.params.phase_back,
            phase_mix: self.params.phase_mix,
            godray_intensity: self.params.godray_intensity,
            haze: self.params.haze,
            godray_steps: self.params.godray_steps,
            _pad0: 0.0,
            _pad1: 0.0,
        };
        self.queue
            .write_buffer(&self.uniform_buf, 0, bytemuck::bytes_of(&uniforms));

        // ---- 取帧 ----
        let frame = match self.surface.get_current_texture() {
            Ok(f) => f,
            Err(wgpu::SurfaceError::Lost | wgpu::SurfaceError::Outdated) => {
                self.surface.configure(&self.device, &self.config);
                return;
            }
            Err(e) => {
                eprintln!("获取交换链帧失败: {e:?}");
                return;
            }
        };
        let surface_view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor::default());

        // Pass 1: 体积云 -> 离屏
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("clouds"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &self.offscreen_view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });
            pass.set_pipeline(&self.cloud_pipeline);
            pass.set_bind_group(0, &self.cloud_bind_group, &[]);
            pass.draw(0..3, 0..1);
        }

        // Pass 2: 离屏 -> 交换链
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("blit"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &surface_view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });
            pass.set_pipeline(&self.blit_pipeline);
            pass.set_bind_group(0, &self.offscreen_bind_group, &[]);
            pass.draw(0..3, 0..1);
        }

        // Pass 3: egui 面板
        let prims = self
            .egui_ctx
            .tessellate(full_output.shapes, full_output.pixels_per_point);
        for (id, delta) in &full_output.textures_delta.set {
            self.egui_renderer
                .update_texture(&self.device, &self.queue, *id, delta);
        }
        let screen = egui_wgpu::ScreenDescriptor {
            size_in_pixels: [self.config.width, self.config.height],
            pixels_per_point: full_output.pixels_per_point,
        };
        self.egui_renderer
            .update_buffers(&self.device, &self.queue, &mut encoder, &prims, &screen);
        {
            let pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("egui"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &surface_view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Load,
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });
            let mut pass = pass.forget_lifetime();
            self.egui_renderer.render(&mut pass, &prims, &screen);
        }

        self.queue.submit(Some(encoder.finish()));
        for id in &full_output.textures_delta.free {
            self.egui_renderer.free_texture(id);
        }
        self.window.pre_present_notify();
        frame.present();
    }

    fn on_key(&mut self, code: KeyCode, pressed: bool) {
        match code {
            KeyCode::KeyW | KeyCode::ArrowUp => self.input.forward = pressed,
            KeyCode::KeyS | KeyCode::ArrowDown => self.input.back = pressed,
            KeyCode::KeyA | KeyCode::ArrowLeft => self.input.left = pressed,
            KeyCode::KeyD | KeyCode::ArrowRight => self.input.right = pressed,
            KeyCode::Space => self.input.up = pressed,
            KeyCode::ControlLeft => self.input.down = pressed,
            KeyCode::ShiftLeft => self.input.fast = pressed,
            _ => {}
        }
    }
}

#[derive(Default)]
struct App {
    state: Option<State>,
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.state.is_some() {
            return;
        }
        let attrs = Window::default_attributes()
            .with_title("wgpu 体积云 v2  |  丁达尔效应 + 动态云层 + 实时调参")
            .with_inner_size(winit::dpi::LogicalSize::new(1480, 820));
        let window = Arc::new(event_loop.create_window(attrs).unwrap());
        self.state = Some(State::new(window));
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        let Some(state) = self.state.as_mut() else {
            return;
        };

        // egui 优先处理事件；被面板消费的输入不再传给相机
        let response = state.egui_state.on_window_event(&state.window, &event);
        if response.repaint {
            state.window.request_redraw();
        }

        match event {
            WindowEvent::CloseRequested => event_loop.exit(),
            WindowEvent::Resized(size) => state.resize(size.width, size.height),
            WindowEvent::KeyboardInput { event, .. } => {
                if let PhysicalKey::Code(code) = event.physical_key {
                    if code == KeyCode::Escape {
                        event_loop.exit();
                        return;
                    }
                    if !state.egui_ctx.wants_keyboard_input() {
                        state.on_key(code, event.state == ElementState::Pressed);
                    }
                }
            }
            WindowEvent::MouseInput { state: btn, button: MouseButton::Left, .. } => {
                if response.consumed || state.egui_ctx.wants_pointer_input() {
                    state.input.dragging = false;
                    state.input.last_cursor = None;
                } else {
                    state.input.dragging = btn == ElementState::Pressed;
                    if !state.input.dragging {
                        state.input.last_cursor = None;
                    }
                }
            }
            WindowEvent::CursorMoved { position, .. } => {
                if state.input.dragging && !state.egui_ctx.wants_pointer_input() {
                    if let Some((lx, ly)) = state.input.last_cursor {
                        let dx = (position.x - lx) as f32;
                        let dy = (position.y - ly) as f32;
                        state.yaw += dx * 0.0032;
                        state.pitch = (state.pitch - dy * 0.0032).clamp(-1.5, 1.5);
                    }
                    state.input.last_cursor = Some((position.x, position.y));
                } else if !state.input.dragging {
                    state.input.last_cursor = None;
                }
            }
            WindowEvent::RedrawRequested => state.render(),
            _ => {}
        }
    }

    fn about_to_wait(&mut self, _event_loop: &ActiveEventLoop) {
        if let Some(state) = &self.state {
            state.window.request_redraw();
        }
    }
}

fn main() {
    env_logger::init();
    let event_loop = EventLoop::new().unwrap();
    event_loop.set_control_flow(ControlFlow::Poll);
    let mut app = App::default();
    event_loop.run_app(&mut app).unwrap();
}
