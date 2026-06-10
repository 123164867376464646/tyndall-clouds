// 将离屏渲染的云图放大(双线性)绘制到交换链
// 离屏分辨率 = 窗口分辨率 × 渲染比例，比例可在 GUI 中实时调整

struct VsOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

@group(0) @binding(0) var src_tex: texture_2d<f32>;
@group(0) @binding(1) var src_samp: sampler;

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> VsOut {
    let x = f32(vi / 2u) * 4.0 - 1.0;
    let y = f32(vi % 2u) * 4.0 - 1.0;
    var out: VsOut;
    out.pos = vec4<f32>(x, y, 0.0, 1.0);
    out.uv = vec2<f32>((x + 1.0) * 0.5, 1.0 - (y + 1.0) * 0.5);
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    return vec4<f32>(textureSample(src_tex, src_samp, in.uv).rgb, 1.0);
}
