#include <metal_stdlib>
using namespace metal;

struct GrayScottParams {
    float F;
    float K;
    float Du;
    float Dv;
};

static float hash(float2 uv) {
    return fract(sin(dot(uv, float2(12.9898f, 4.1414f))) * 43758.5453f);
}

// Based on Morgan McGuire @morgan3d
// https://www.shadertoy.com/view/4dS3Wd
static float noise(float2 x) {
    float2 i = floor(x);
    float2 f = fract(x);
    float a = hash(i);
    float b = hash(i + float2(1.0, 0.0));
    float c = hash(i + float2(0.0, 1.0));
    float d = hash(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

static float2 laplacian(texture2d<float, access::read> image, int2 coords) {
    const float3x3 kern {{
        { 0.05,  0.20, 0.05 },
        { 0.20, -1.00, 0.20 },
        { 0.05,  0.20, 0.05 },
    }};
    int W = image.get_width();
    int H = image.get_height();

    float2 L { 0.0, 0.0 };
    for (int i = -1; i <= 1; ++i) {
        for (int j = -1; j <= 1; ++j) {
            float coeff = kern[j + 1][i + 1];
            int x = (coords.x + W + j) % W;
            int y = (coords.y + H + i) % H;
            L += image.read(uint2(x, y)).rg * coeff;
        }
    }
    return L;
}

static float2 simulate(float2 previous, float2 laplacian, constant GrayScottParams &params, float dT)
{
    float u = previous.r;
    float v = previous.g;
    float uvv = u * v * v;
    float F = params.F;
    float K = params.K;
    float Du = params.Du;
    float Dv = params.Dv;
    float Lu = laplacian.r;
    float Lv = laplacian.g;
    float2 reaction {
        -uvv + F * (1.0 - u),
        uvv - (F + K) * v,
    };
    float2 diffusion {
        Du * Lu,
        Dv * Lv
    };
    return previous + (reaction + diffusion) * dT;
}

[[kernel]]
void gray_scott(texture2d<float, access::read> sourceTexture [[texture(0)]],
                texture2d<float, access::write> destTexture  [[texture(1)]],
                constant GrayScottParams &params             [[buffer(0)]],
                constant float &dT                           [[buffer(1)]],
                uint2 threadIndex                            [[thread_position_in_grid]],
                uint2 gridSize                               [[threads_per_grid]])
{
    float2 simSize { (float)destTexture.get_width(), (float)destTexture.get_height() };
    if (threadIndex.x > simSize.x || threadIndex.y > simSize.y) {
        return; // Kill out-of-bounds threads
    }

    float2 previous = sourceTexture.read(threadIndex).rg;
    float2 laplace = laplacian(sourceTexture, int2(threadIndex));
    float2 current = simulate(previous, laplace, params, dT);
    destTexture.write(current.rggg, threadIndex);
}

[[kernel]]
void seed(texture2d<float, access::write> destTexture [[texture(0)]],
          constant float &seed                        [[buffer(0)]],
          uint2 threadIndex                           [[thread_position_in_grid]],
          uint2 gridSize                              [[threads_per_grid]])
{
    float2 simSize { (float)destTexture.get_width(), (float)destTexture.get_height() };
    int x = threadIndex.x, y = threadIndex.y;
    if (x > simSize.x || y > simSize.y) {
        return; // Kill out-of-bounds threads
    }
    float2 coords = float2(x, y);

    // "Initially, the entire system was placed in the trivial state (U = 1, V = 0)."
    float2 UV = { 1.0f, 0.0f };

    // "The 20 by 20 mesh point area located symmetrically about the center of the grid..."
    int2 centerMin { (int)(simSize.x / 2) - 10, (int)(simSize.y / 2) - 10 };
    int2 centerMax { (int)(simSize.x / 2) + 10, (int)(simSize.y / 2) + 10 };
    if (x >= centerMin.x && x <= centerMax.x && y >= centerMin.y && y <= centerMax.y) {
        // "...was then perturbed to (U = 1/2, V = 1/4)."
        UV = float2(0.5, 0.25);
    }

    // "These conditions were then perturbed with ±1% random noise
    // in order to break the square symmetry."
    UV += 0.01 * (float2(noise(coords + seed), noise(coords + (seed * 3) + float2(31, 17))) * 2.0 - 1.0);
    UV = saturate(UV);

    destTexture.write(UV.rggg, threadIndex);
}

struct VertexIn {
    float3 position  [[attribute(0)]];
    float2 texCoords [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoords;
};

[[vertex]]
VertexOut vertex_main(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = float4(in.position, 1.0f);
    out.texCoords = in.texCoords;
    return out;
}

static float P(texture2d<float, access::sample> image, float2 coords) {
    constexpr sampler bilinearSampler(coord::normalized, filter::linear, mip_filter::none);
    float2 values = image.sample(bilinearSampler, coords).rg;
    float value = 1.0 - saturate(values.r - values.g);
    return value;
}

static float3 gradient(float v) {
    float3 stop0 = float3(1.0f, 1.0f, 1.0f);
    float3 stop1 = float3(1.0f, 1.0f, 1.0f);
    float3 stop2 = float3(0.0f, 0.204f, 0.780f);
    float3 stop3 = float3(0.0f, 0.0f, 0.04f);
    return mix(mix(mix(stop0, stop1, v * 3.0f),
                   mix(stop1, stop2, (v - 0.333f) * 3.0f),
                   step(0.333f, v)),
               mix(stop2, stop3, (v - 0.667) * 3.0f),
               step(0.667f, v));
}

[[fragment]]
float4 fragment_main(VertexOut in [[stage_in]],
                     texture2d<float, access::sample> image [[texture(0)]])
{
    // texel width in texture coordinate space
    float3 dp = float3(1.0f / float2(image.get_width(), image.get_height()), 0.0f);
    float2 uv = in.texCoords;

    float value = P(image, in.texCoords);
    float3 N {
        P(image, uv + dp.xz) - P(image, uv - dp.xz),
        P(image, uv - dp.zy) - P(image, uv + dp.zy),
        abs(cos(value * M_PI_F)) * 0.5f
    };
    N = normalize(N);

    float3 L = normalize(float3(0.9f, 0.9f, 1.0f));
    float3 V = float3(0, 0, 1);
    float3 H = normalize(L + V);
    float NdotL = saturate(saturate(dot(N, L)));
    float NdotH = saturate(saturate(dot(N, H)));
    float diffuse = saturate(NdotL) * 0.5 + 0.5;
    float specular = powr(NdotH, 50.0f) * step(0.0f, NdotL);

    float3 baseColor = gradient(value + 0.1f);
    float3 color = diffuse * baseColor + float3(specular * 0.25f);
    return float4(color.rgb, 1.0f);
}
