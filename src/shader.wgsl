// 体积云渲染：全屏三角形 + 片元着色器内做光线步进
//
// 思路：
//   1. 云层位于 CLOUD_BASE ~ CLOUD_TOP 高度的平板(slab)内
//   2. 视线与平板求交，在区间内做 80 步主步进
//   3. 密度 = FBM 值噪声 × 高度造型曲线 - 覆盖率阈值 - 细节侵蚀
//   4. 每个采样点向太阳方向做 5 步光照步进，按 Beer 定律算自阴影
//   5. HG 相位函数产生"银边"，多重散射近似让云底不会死黑
//   6. 前向能量守恒积分，透射率低于阈值提前退出

struct Uniforms {
    resolution: vec2<f32>,
    time: f32,
    _pad0: f32,
    cam_pos: vec3<f32>,
    _pad1: f32,
    sun_dir: vec3<f32>,
    _pad2: f32,
    forward: vec3<f32>,
    _pad3: f32,
    right: vec3<f32>,
    _pad4: f32,
    up: vec3<f32>,
    _pad5: f32,
}

@group(0) @binding(0) var<uniform> u: Uniforms;

const CLOUD_BASE: f32 = 1500.0;   // 云底高度(米)
const CLOUD_TOP: f32 = 3600.0;    // 云顶高度
const COVERAGE: f32 = 0.50;       // 云覆盖率 0~1
const DENSITY: f32 = 2.2;         // 密度增益，越大云越厚实、边缘越清晰
const SIGMA: f32 = 0.075;         // 消光系数缩放
const MARCH_STEPS: i32 = 80;
const PI: f32 = 3.14159265;

// ---------- 噪声 ----------

fn hash13(p: vec3<f32>) -> f32 {
    var p3 = fract(p * 0.1031);
    p3 = p3 + dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}

fn noise3(x: vec3<f32>) -> f32 {
    let i = floor(x);
    let f = fract(x);
    let w = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(
            mix(hash13(i + vec3<f32>(0.0, 0.0, 0.0)), hash13(i + vec3<f32>(1.0, 0.0, 0.0)), w.x),
            mix(hash13(i + vec3<f32>(0.0, 1.0, 0.0)), hash13(i + vec3<f32>(1.0, 1.0, 0.0)), w.x),
            w.y,
        ),
        mix(
            mix(hash13(i + vec3<f32>(0.0, 0.0, 1.0)), hash13(i + vec3<f32>(1.0, 0.0, 1.0)), w.x),
            mix(hash13(i + vec3<f32>(0.0, 1.0, 1.0)), hash13(i + vec3<f32>(1.0, 1.0, 1.0)), w.x),
            w.y,
        ),
        w.z,
    );
}

// 分形布朗运动，octaves 由调用方决定(光照步进用低八度省性能)
fn fbm(p: vec3<f32>, octaves: i32) -> f32 {
    var v = 0.0;
    var a = 0.5;
    var q = p;
    // 每个八度做一次旋转+频率翻倍，打散轴向条纹
    let m = mat3x3<f32>(
        vec3<f32>(0.0, 0.8, 0.6),
        vec3<f32>(-0.8, 0.36, -0.48),
        vec3<f32>(-0.6, -0.48, 0.64),
    );
    for (var i = 0; i < octaves; i++) {
        v += a * noise3(q);
        q = m * q * 2.02;
        a *= 0.5;
    }
    return v;
}

fn remap(v: f32, a: f32, b: f32, c: f32, d: f32) -> f32 {
    return c + (v - a) / (b - a) * (d - c);
}

// ---------- 云密度 ----------

fn cloud_density(p: vec3<f32>, cheap: bool) -> f32 {
    let h = (p.y - CLOUD_BASE) / (CLOUD_TOP - CLOUD_BASE);
    if (h < 0.0 || h > 1.0) {
        return 0.0;
    }

    let wind = vec3<f32>(1.0, 0.0, 0.35) * u.time * 14.0;
    let q = (p + wind) * 0.00042;

    var octaves = 5;
    if (cheap) {
        octaves = 3;
    }
    var shape = fbm(q, octaves);

    // 高度造型：底部收紧、顶部渐薄，接近积云轮廓
    let profile = saturate(remap(h, 0.0, 0.08, 0.0, 1.0))
                * saturate(remap(h, 0.25, 1.0, 1.0, 0.0));
    shape = shape * profile;

    var d = shape - (1.0 - COVERAGE);
    if (d <= 0.0) {
        return 0.0;
    }

    if (!cheap) {
        // 高频细节只侵蚀云的边缘(d 小的地方)，保留核心
        let detail = fbm((p + wind * 2.5) * 0.0031, 3);
        d = d - detail * 0.13 * (1.0 - saturate(d * 6.0));
    }
    return max(d, 0.0) * DENSITY;
}

// ---------- 光照 ----------

fn henyey_greenstein(cos_theta: f32, g: f32) -> f32 {
    let g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5));
}

// 朝太阳方向步进，返回到达该点的光学厚度 tau
fn light_march(p: vec3<f32>) -> f32 {
    var tau = 0.0;
    var marched = 0.0;
    for (var j = 0; j < 5; j++) {
        let seg = 80.0 * exp2(f32(j));
        let lp = p + u.sun_dir * (marched + seg * 0.5);
        tau += cloud_density(lp, true) * seg * SIGMA;
        marched += seg;
    }
    return tau;
}

// ---------- 背景 ----------

fn sky_color(rd: vec3<f32>) -> vec3<f32> {
    let t = saturate(rd.y);
    var col = mix(vec3<f32>(0.62, 0.72, 0.86), vec3<f32>(0.18, 0.40, 0.78), pow(t, 0.6));

    let s = saturate(dot(rd, u.sun_dir));
    // 太阳光晕 + 日盘
    col += vec3<f32>(1.0, 0.85, 0.6) * pow(s, 7.0) * 0.22;
    col += vec3<f32>(1.0, 0.92, 0.8) * smoothstep(0.9993, 0.9998, s) * 18.0;
    return col;
}

fn ground_color(ro: vec3<f32>, rd: vec3<f32>) -> vec3<f32> {
    let t = -ro.y / rd.y;
    let p = ro + rd * t;
    let n = noise3(vec3<f32>(p.x * 0.0015, 0.0, p.z * 0.0015));
    var col = mix(vec3<f32>(0.21, 0.26, 0.15), vec3<f32>(0.14, 0.18, 0.11), n);
    col *= 0.75 + 0.5 * saturate(u.sun_dir.y);
    // 远处融入大气雾色
    let fog = 1.0 - exp(-t * 0.00012);
    return mix(col, vec3<f32>(0.66, 0.74, 0.86), fog);
}

// ---------- 体积云步进 ----------

// 返回 rgb = 云的累计散射光, a = 剩余透射率(用于和背景合成)
fn march_clouds(ro: vec3<f32>, rd: vec3<f32>, jitter: f32, bg: vec3<f32>) -> vec4<f32> {
    var rdy = rd.y;
    if (abs(rdy) < 1e-4) {
        rdy = 1e-4;
    }
    let t_bot = (CLOUD_BASE - ro.y) / rdy;
    let t_top = (CLOUD_TOP - ro.y) / rdy;
    var t0 = min(t_bot, t_top);
    var t1 = max(t_bot, t_top);
    t0 = max(t0, 0.0);
    // 太远的云直接当背景，近地平线的超长射线也截断掉
    if (t1 <= 0.0 || t0 > 30000.0) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    t1 = min(t1, t0 + 16000.0);

    let dt = (t1 - t0) / f32(MARCH_STEPS);
    var t = t0 + dt * jitter;

    let cos_theta = dot(rd, u.sun_dir);
    // 前向散射(银边) + 少量后向散射
    let phase = mix(
        henyey_greenstein(cos_theta, 0.55),
        henyey_greenstein(cos_theta, -0.35),
        0.3,
    );
    let sun_col = vec3<f32>(1.0, 0.93, 0.82);

    var trans = 1.0;
    var col = vec3<f32>(0.0);

    for (var i = 0; i < MARCH_STEPS; i++) {
        if (trans < 0.015) {
            break;
        }
        let p = ro + rd * t;
        let den = cloud_density(p, false);
        if (den > 0.004) {
            let tau = light_march(p);
            // Beer 定律 + 多重散射近似(防止云底死黑)
            let light = max(exp(-tau), exp(-tau * 0.25) * 0.25);
            let h = saturate((p.y - CLOUD_BASE) / (CLOUD_TOP - CLOUD_BASE));
            let ambient = mix(vec3<f32>(0.34, 0.42, 0.58), vec3<f32>(0.72, 0.80, 0.95), h);
            var lum = sun_col * light * phase * 32.0 + ambient * 0.85;

            // 远处的云逐渐融入大气
            let atmos = exp(-t * 0.00006);
            lum = mix(bg, lum, atmos);

            // 能量守恒的前向积分
            let step_trans = exp(-den * SIGMA * dt);
            col += lum * (1.0 - step_trans) * trans;
            trans *= step_trans;
        }
        t += dt;
    }
    return vec4<f32>(col, trans);
}

// ---------- 入口 ----------

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    // 覆盖全屏的大三角形: (-1,-1) (-1,3) (3,-1)
    let x = f32(vi / 2u) * 4.0 - 1.0;
    let y = f32(vi % 2u) * 4.0 - 1.0;
    return vec4<f32>(x, y, 0.0, 1.0);
}

@fragment
fn fs_main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    var uv = pos.xy / u.resolution * 2.0 - 1.0;
    uv.y = -uv.y;
    let aspect = u.resolution.x / u.resolution.y;

    let ro = u.cam_pos;
    let rd = normalize(u.forward * 1.4 + u.right * uv.x * aspect + u.up * uv.y);

    var bg: vec3<f32>;
    if (rd.y < 0.0) {
        bg = ground_color(ro, rd);
    } else {
        bg = sky_color(rd);
    }

    // 抖动起步位置消除步进条带
    let jitter = hash13(vec3<f32>(pos.x, pos.y, fract(u.time) * 61.7));
    let clouds = march_clouds(ro, rd, jitter, bg);
    var col = bg * clouds.a + clouds.rgb;

    // 简单的曝光色调映射(交换链是 sRGB 格式，伽马由硬件处理)
    col = vec3<f32>(1.0) - exp(-col * 1.1);
    return vec4<f32>(col, 1.0);
}
