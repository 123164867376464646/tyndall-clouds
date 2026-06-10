// 体积云渲染 v2：光线步进 + 丁达尔效应(云隙光) + 动态演化
//
// 管线结构：本着色器渲染到离屏 HDR 纹理(可降分辨率)，再由 blit.wgsl 放大到交换链
//
// 光路合成模型(沿视线从近到远)：
//   [段A 大气] -> [云层] -> [段B 大气(仅向下视线)] -> [背景(天空/地面)]
//   result = Sa + Ta * ( Scloud + Tcloud * ( Sb + Tb * bg ) )
//   其中 S 为内散射、T 为透射率。
//   段A/B 的内散射在每个采样点计算"向太阳穿过云层的透射率"，
//   被云遮挡处暗、云隙处亮 —— 即丁达尔光柱(crepuscular rays)。

struct Uniforms {
    resolution: vec2<f32>,
    time: f32,
    sun_intensity: f32,

    cam_pos: vec3<f32>,
    coverage: f32,
    sun_dir: vec3<f32>,
    density: f32,
    forward: vec3<f32>,
    sigma: f32,
    right: vec3<f32>,
    ambient: f32,
    up: vec3<f32>,
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
    shadow_strength: f32,
    shadow_softness: f32,
}

@group(0) @binding(0) var<uniform> u: Uniforms;

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

fn fbm(p: vec3<f32>, octaves: i32) -> f32 {
    var v = 0.0;
    var a = 0.5;
    var q = p;
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

fn wind_offset() -> vec3<f32> {
    let a = u.wind_angle;
    return vec3<f32>(cos(a), 0.0, sin(a)) * u.wind_speed * u.time;
}

fn cloud_density(p: vec3<f32>, cheap: bool) -> f32 {
    let h = (p.y - u.cloud_base) / (u.cloud_top - u.cloud_base);
    if (h < 0.0 || h > 1.0) {
        return 0.0;
    }

    let wind = wind_offset();
    // 形状域：随风平移 + evolution 驱动的缓慢垂直推进(云体翻腾感)
    let q = (p + wind + vec3<f32>(0.0, -u.time * u.evolution * 22.0, 0.0)) * 0.00042;

    var octaves = 5;
    if (cheap) {
        octaves = 3;
    }
    var shape = fbm(q, octaves);
    // 对比度锐化:把中间值推向两端,云块更分明、间隙更通透
    shape = mix(shape, smoothstep(0.22, 0.78, shape), 0.45);

    // 高度造型：底部收紧、顶部渐薄
    let profile = saturate(remap(h, 0.0, 0.08, 0.0, 1.0))
                * saturate(remap(h, 0.25, 1.0, 1.0, 0.0));
    shape = shape * profile;

    var d = shape - (1.0 - u.coverage);
    if (d <= 0.0) {
        return 0.0;
    }

    if (!cheap) {
        // 细节域：风速 2.5 倍视差 + 独立时间相位 -> 边缘持续翻滚
        let dq = (p + wind * 2.5
                  + vec3<f32>(u.time * u.evolution * 35.0, u.time * u.evolution * 14.0, 0.0)) * 0.0031;
        let detail = fbm(dq, 3);
        // 边缘侵蚀(d 小处)，云顶更碎更飘逸
        d = d - detail * u.detail_strength * (1.0 - saturate(d * 6.0)) * mix(1.0, 1.6, h);
    }
    return max(d, 0.0) * u.density;
}

// ---------- 光照 ----------

fn henyey_greenstein(cos_theta: f32, g: f32) -> f32 {
    let g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5));
}

// 太阳颜色随高度角变暖(低角度 -> 橙红)
fn sun_color() -> vec3<f32> {
    let e = saturate(u.sun_dir.y * 2.2);
    return mix(vec3<f32>(1.0, 0.45, 0.18), vec3<f32>(1.0, 0.96, 0.90), pow(e, 0.6));
}

// 从 p 点向太阳穿过整个云层的透射率(用于丁达尔光柱与地面云影)
fn sun_visibility(p: vec3<f32>) -> f32 {
    let sd = u.sun_dir;
    if (sd.y < 0.02) {
        return 1.0;
    }
    let t0 = max((u.cloud_base - p.y) / sd.y, 0.0);
    let t1 = (u.cloud_top - p.y) / sd.y;
    if (t1 <= t0) {
        return 1.0;
    }
    let dt = (t1 - t0) / 5.0;
    var tau = 0.0;
    for (var i = 0; i < 5; i++) {
        let lp = p + sd * (t0 + (f32(i) + 0.5) * dt);
        tau += cloud_density(lp, true) * dt * u.sigma;
    }
    return exp(-tau);
}

// 云内部向太阳的光照步进(指数间距，自阴影)
fn light_march(p: vec3<f32>) -> f32 {
    var tau = 0.0;
    var marched = 0.0;
    let n = i32(u.light_steps);
    for (var j = 0; j < n; j++) {
        let seg = 60.0 * exp2(f32(j));
        let lp = p + u.sun_dir * (marched + seg * 0.5);
        tau += cloud_density(lp, true) * seg * u.sigma;
        marched += seg;
    }
    return tau;
}

// ---------- 地面云影(柔和版) ----------

// 羽化阈值的云密度:把硬边界(阶跃)展宽成 smoothstep 过渡,
// 相当于对阴影做空间模糊;柔和度越大,半影越宽
fn cloud_density_soft(p: vec3<f32>) -> f32 {
    let h = (p.y - u.cloud_base) / (u.cloud_top - u.cloud_base);
    if (h < 0.0 || h > 1.0) {
        return 0.0;
    }
    let wind = wind_offset();
    let q = (p + wind + vec3<f32>(0.0, -u.time * u.evolution * 22.0, 0.0)) * 0.00042;
    var shape = fbm(q, 3);
    shape = mix(shape, smoothstep(0.22, 0.78, shape), 0.45);
    let profile = saturate(remap(h, 0.0, 0.08, 0.0, 1.0))
                * saturate(remap(h, 0.25, 1.0, 1.0, 0.0));
    shape = shape * profile;

    let edge = mix(0.02, 0.30, saturate(u.shadow_softness));
    let x = shape - (1.0 - u.coverage);
    return smoothstep(-edge, edge, x) * 0.12 * u.density;
}

// 地面接收的云投影:柔和密度 + 强度混合
fn ground_shadow(p: vec3<f32>) -> f32 {
    let sd = u.sun_dir;
    if (sd.y < 0.02) {
        return 1.0;
    }
    let t0 = max((u.cloud_base - p.y) / sd.y, 0.0);
    let t1 = (u.cloud_top - p.y) / sd.y;
    if (t1 <= t0) {
        return 1.0;
    }
    let dt = (t1 - t0) / 5.0;
    var tau = 0.0;
    for (var i = 0; i < 5; i++) {
        let lp = p + sd * (t0 + (f32(i) + 0.5) * dt);
        tau += cloud_density_soft(lp) * dt * u.sigma;
    }
    let vis = exp(-tau);
    return mix(1.0, vis, saturate(u.shadow_strength));
}

// ---------- 丁达尔效应：大气内散射 ----------
// 在 [t_start, t_end] 区间步进，每点用 sun_visibility 调制太阳光,
// 云的遮挡在雾中投射出明暗交替的光柱。
// 返回 x = 太阳内散射积分, y = 累计光学厚度
fn god_rays(ro: vec3<f32>, rd: vec3<f32>, t_start: f32, t_end: f32, steps: i32, jitter: f32) -> vec2<f32> {
    if (steps <= 0 || t_end - t_start < 1.0 || u.haze < 0.001) {
        return vec2<f32>(0.0, 0.0);
    }
    let dt = (t_end - t_start) / f32(steps);
    var t = t_start + dt * jitter;
    var sun_acc = 0.0;
    var od = 0.0;
    for (var i = 0; i < steps; i++) {
        let p = ro + rd * t;
        // 雾密度随海拔指数衰减
        let hfall = exp(-max(p.y, 0.0) * 0.00035);
        let step_od = u.haze * hfall * dt * 0.0001;
        // 平方增强云影对比 -> 光柱明暗更分明
        let vis = sun_visibility(p);
        sun_acc += vis * vis * exp(-od) * step_od;
        od += step_od;
        t += dt;
    }
    return vec2<f32>(sun_acc, od);
}

// ---------- 背景 ----------

fn sky_color(rd: vec3<f32>) -> vec3<f32> {
    let sd = u.sun_dir;
    let t = saturate(rd.y);

    // 低太阳时地平线朝太阳方向染暖色
    let warm_amount = saturate(1.0 - sd.y * 3.0);
    let sun_az = normalize(vec3<f32>(sd.x, 0.0, sd.z) + vec3<f32>(1e-5, 0.0, 0.0));
    let rd_az = normalize(vec3<f32>(rd.x, 0.0, rd.z) + vec3<f32>(1e-5, 0.0, 0.0));
    let toward = pow(saturate(dot(rd_az, sun_az) * 0.5 + 0.5), 3.0);

    let horizon = mix(vec3<f32>(0.50, 0.60, 0.75), vec3<f32>(1.0, 0.62, 0.36), warm_amount * toward);
    let zenith = vec3<f32>(0.10, 0.28, 0.62);
    var col = mix(horizon, zenith, pow(t, 0.45));

    let s = saturate(dot(rd, sd));
    col += sun_color() * pow(s, 6.0) * 0.30;
    col += sun_color() * smoothstep(0.9993, 0.9999, s) * 24.0;
    return col;
}

fn ground_color(ro: vec3<f32>, rd: vec3<f32>) -> vec3<f32> {
    let t = -ro.y / rd.y;
    let p = ro + rd * t;
    // 低频多八度底纹 + 缓和的对比度，避免生硬色块
    let n = fbm(vec3<f32>(p.x * 0.0008, 0.0, p.z * 0.0008), 3);
    var albedo = mix(vec3<f32>(0.20, 0.24, 0.15), vec3<f32>(0.14, 0.17, 0.12), smoothstep(0.20, 0.70, n));

    // 云影:柔和密度场 + 强度可调
    let shadow = ground_shadow(p);
    let direct = sun_color() * saturate(u.sun_dir.y) * shadow * 1.4;
    let ambient = vec3<f32>(0.35, 0.42, 0.55) * 0.5;
    var col = albedo * (direct + ambient);

    // 远处轻微融入地平线色(主要雾效由 god_rays 的光学厚度承担)
    let fog = 1.0 - exp(-t * 0.00005);
    return mix(col, vec3<f32>(0.66, 0.72, 0.84), fog);
}

// ---------- 体积云步进 ----------

fn march_clouds(ro: vec3<f32>, rd: vec3<f32>, jitter: f32, bg: vec3<f32>) -> vec4<f32> {
    var rdy = rd.y;
    if (abs(rdy) < 1e-4) {
        rdy = 1e-4;
    }
    let t_bot = (u.cloud_base - ro.y) / rdy;
    let t_top = (u.cloud_top - ro.y) / rdy;
    var t0 = max(min(t_bot, t_top), 0.0);
    var t1 = max(t_bot, t_top);
    if (t1 <= 0.0 || t0 > 30000.0) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    t1 = min(t1, t0 + 18000.0);

    let steps = clamp(i32(u.steps), 16, 256);
    let dt = (t1 - t0) / f32(steps);
    var t = t0 + dt * jitter;

    let cos_theta = dot(rd, u.sun_dir);
    let phase = mix(
        henyey_greenstein(cos_theta, u.phase_g),
        henyey_greenstein(cos_theta, -abs(u.phase_back)),
        u.phase_mix,
    );
    let sun_c = sun_color();

    var trans = 1.0;
    var col = vec3<f32>(0.0);

    for (var i = 0; i < steps; i++) {
        if (trans < 0.015) {
            break;
        }
        let p = ro + rd * t;
        let den = cloud_density(p, false);
        if (den > 0.004) {
            let tau = light_march(p);
            // Beer 定律 + 多重散射近似
            let light = max(exp(-tau), exp(-tau * 0.25) * 0.25);
            let h = saturate((p.y - u.cloud_base) / (u.cloud_top - u.cloud_base));
            let amb = mix(vec3<f32>(0.26, 0.33, 0.46), vec3<f32>(0.80, 0.87, 1.0), h);
            var lum = sun_c * light * phase * u.sun_intensity + amb * u.ambient;

            // 远处云融入大气
            let atmos = exp(-t * 0.00005 * max(u.haze, 0.15));
            lum = mix(bg, lum, atmos);

            let step_trans = exp(-den * u.sigma * dt);
            col += lum * (1.0 - step_trans) * trans;
            trans *= step_trans;
        }
        t += dt;
    }
    return vec4<f32>(col, trans);
}

// ---------- 色调映射 ----------

fn aces(x: vec3<f32>) -> vec3<f32> {
    let a = 2.51;
    let b = 0.03;
    let c = 2.43;
    let d = 0.59;
    let e = 0.14;
    return saturate(x * (a * x + b) / (x * (c * x + d) + e));
}

// ---------- 入口 ----------

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
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

    let j1 = hash13(vec3<f32>(pos.x, pos.y, fract(u.time) * 61.7));
    let j2 = hash13(vec3<f32>(pos.y, pos.x, fract(u.time) * 47.3));

    let clouds = march_clouds(ro, rd, j1, bg);

    // ---- 丁达尔效应的两段大气 ----
    var rdy = rd.y;
    if (abs(rdy) < 1e-4) {
        rdy = 1e-4;
    }
    let cap = 16000.0;
    var ground_t = cap;
    if (rd.y < -0.0005) {
        ground_t = max(-ro.y / rd.y, 0.0);
    }
    let t_bot = (u.cloud_base - ro.y) / rdy;
    let t_top = (u.cloud_top - ro.y) / rdy;
    let s0 = max(min(t_bot, t_top), 0.0);
    let s1 = max(t_bot, t_top);

    // 段A: 相机 -> 云层入口(或地面/上限)
    var a1 = min(ground_t, cap);
    if (s1 > 0.0 && s0 < a1) {
        a1 = s0;
    }
    // 段B: 云层底部出口 -> 地面(仅向下视线，相机在云上/云中时)
    var b0 = 0.0;
    var b1 = -1.0;
    if (rd.y < -0.0005 && t_bot > 0.0) {
        b0 = t_bot;
        b1 = min(ground_t, b0 + 16000.0);
    }

    let n_gr = clamp(i32(u.godray_steps), 4, 96);
    let gr_a = god_rays(ro, rd, 0.0, a1, n_gr, j2);
    var gr_b = vec2<f32>(0.0, 0.0);
    if (b1 > b0 + 1.0) {
        gr_b = god_rays(ro, rd, b0, b1, max(n_gr / 2, 4), j2);
    }

    let cos_theta = dot(rd, u.sun_dir);
    // 紧凑前向 Mie 瓣(光晕集中在太阳附近) + 少量宽瓣(远处隐约可见)
    let mie = henyey_greenstein(cos_theta, 0.80) * 0.88 + henyey_greenstein(cos_theta, 0.30) * 0.12;
    let sun_c = sun_color();
    let amb_air = vec3<f32>(0.50, 0.60, 0.75);
    // 0.02: 把"太阳强度"(为云层光照标定)折算到大气内散射的能量尺度,
    // 峰值控制在 ACES 肩部以下,保留光柱明暗对比(不剪裁成纯白)
    let s_gain = u.sun_intensity * u.godray_intensity * mie * 0.02;

    let scatter_a = sun_c * s_gain * gr_a.x + amb_air * gr_a.y * 0.10;
    let scatter_b = sun_c * s_gain * gr_b.x + amb_air * gr_b.y * 0.10;
    let trans_a = exp(-gr_a.y);
    let trans_b = exp(-gr_b.y);

    // 近到远合成: 段A -> 云 -> 段B -> 背景
    var col = scatter_a + trans_a * (clouds.rgb + clouds.a * (scatter_b + trans_b * bg));

    col = aces(col * u.exposure);
    return vec4<f32>(col, 1.0);
}
