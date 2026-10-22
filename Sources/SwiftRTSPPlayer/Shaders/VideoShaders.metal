#include <metal_stdlib>
using namespace metal;

struct VertexOut {
	float4 position [[position]];
	float2 texCoord;
};

struct FisheyeUniforms {
	float k1v;
	float k2v;
	float k3v;
	float k4v;
	float aspect;     // sourceWidth / sourceHeight
	float expansion;  // 1 leaves the corrected picture at its size
};

// Fraction of the source picture hidden from each edge; all zero shows the
// whole frame. A view-anchored mask never gets here — it is a smaller scissor.
struct MaskUniforms {
	float left;
	float right;
	float top;
	float bottom;
};

vertex VertexOut vertex_passthrough(uint vid [[vertex_id]]) {
		const float2 pos[4]  = {{-1,-1},{1,-1},{-1,1},{1,1}};
		const float2 uvs[4]  = {{ 0, 1},{1, 1},{ 0,0},{1,0}};

		VertexOut out;
		out.position = float4(pos[vid], 0, 1);
		out.texCoord = uvs[vid];
		return out;
}

// The same quad, placed by a caller-supplied matrix: an offscreen composition
// has no layer tree to carry the framing.
vertex VertexOut vertex_transformed(
																		uint vid [[vertex_id]],
																		constant float4x4& transform [[buffer(0)]]
																		) {
		const float2 pos[4]  = {{-1,-1},{1,-1},{-1,1},{1,1}};
		const float2 uvs[4]  = {{ 0, 1},{1, 1},{ 0,0},{1,0}};

		VertexOut out;
		out.position = transform * float4(pos[vid], 0, 1);
		out.texCoord = uvs[vid];
		return out;
}

// OpenCV-style fisheye undistortion: polynomial in θ = atan(r), applied as a
// multiplicative factor on r so all coefficients zero leaves uv unchanged.
// Aspect ratio is compensated so the correction is truly radial. The expansion
// zooms the corrected picture out, bringing back the borders it stretched away.
static inline float2 undistortFisheye(float2 uv, constant FisheyeUniforms& p) {
	if (p.k1v == 0.0 && p.k2v == 0.0 && p.k3v == 0.0 && p.k4v == 0.0 && p.expansion == 1.0) {
		return uv;
	}

	float2 centered = (uv - 0.5) * p.expansion;
	centered.x *= p.aspect;

	float r = length(centered);
	if (r < 1e-6) {
		return uv;
	}

	float theta = atan(r);
	float t2 = theta * theta;
	float t4 = t2 * t2;
	float t6 = t4 * t2;
	float t8 = t4 * t4;
	float poly = 1.0 + p.k1v * t2 + p.k2v * t4 + p.k3v * t6 + p.k4v * t8;

	centered *= poly;
	centered.x /= p.aspect;
	return centered + 0.5;
}

// BT.709 limited range (VideoToolbox default for H.264)
fragment float4 fragment_yuv(
														 VertexOut in          [[stage_in]],
														 texture2d<float> yTex [[texture(0)]],
														 texture2d<float> uvTex[[texture(1)]],
														 constant FisheyeUniforms& fisheye [[buffer(0)]],
														 constant MaskUniforms& mask [[buffer(1)]],
														 constant float3x3& perspective [[buffer(2)]]
														 ) {
	constexpr sampler s(filter::linear, address::clamp_to_edge);

	// Into the corrected picture; the identity homography leaves uv exact.
	float3 projected = perspective * float3(in.texCoord, 1.0);
	// Behind the horizon, where the fisheye polynomial could fold it back into the picture.
	if (projected.z <= 0.0) {
		return float4(0.0, 0.0, 0.0, 1.0);
	}
	float2 uv2 = undistortFisheye(projected.xy / projected.z, fisheye);

	// Outside the mask — the source frame's own edges being the mask at its
	// widest, which also keeps the "pinched" fisheye corners from showing
	// smeared edge pixels from clamp_to_edge sampling.
	if (uv2.x < mask.left || uv2.x > 1.0 - mask.right ||
			uv2.y < mask.top || uv2.y > 1.0 - mask.bottom) {
		return float4(0.0, 0.0, 0.0, 1.0);
	}

	float  y  = yTex.sample(s, uv2).r;
	float2 uv = uvTex.sample(s, uv2).rg;

	// Expand limited range [16-235 / 16-240] → [0-1]
	y  = (y  - 16.0/255.0) * (255.0/219.0);
	uv = (uv - 128.0/255.0) * (255.0/224.0);

	// BT.709 matrix
	float r = y + 1.5748 * uv.y;
	float g = y - 0.1873 * uv.x - 0.4681 * uv.y;
	float b = y + 1.8556 * uv.x;

	return float4(clamp(float3(r,g,b), 0.0, 1.0), 1.0);
}
