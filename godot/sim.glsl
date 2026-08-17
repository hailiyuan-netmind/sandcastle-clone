#[compute]
#version 450

// Shallow-water pipe model, ported from 3d.html's waterStep().
// field: r=sand height, g=water depth, b=moisture, a=foam
// flux:  r=left, g=right, b=top(-z), a=bottom(+z) outflow

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D field_in;
layout(rgba32f, set = 0, binding = 1) uniform restrict writeonly image2D field_out;
layout(rgba32f, set = 0, binding = 2) uniform restrict image2D flux;

layout(push_constant) uniform Params {
	float dt;
	float sea;
	float surge;     // extra water level at the open (far z) boundary
	float damp;
	int mode;        // 0 = flux update, 1 = water integrate
	int n;
	float pad0;
	float pad1;
} P;

float surfaceAt(ivec2 p) {
	p = clamp(p, ivec2(0), ivec2(P.n - 1));
	vec4 f = imageLoad(field_in, p);
	return f.r + f.g;
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= P.n || p.y >= P.n) { return; }
	const float g = 32.0;

	if (P.mode == 0) {
		// accelerate + clamp outflow fluxes
		vec4 f = imageLoad(field_in, p);
		vec4 q = imageLoad(flux, p);
		float h = f.r + f.g;
		float dL = p.x > 0       ? h - surfaceAt(p + ivec2(-1, 0)) : 0.0;
		float dR = p.x < P.n - 1 ? h - surfaceAt(p + ivec2( 1, 0)) : 0.0;
		float dT = p.y > 0       ? h - surfaceAt(p + ivec2(0, -1)) : 0.0;
		float dB = p.y < P.n - 1 ? h - surfaceAt(p + ivec2(0,  1)) : 0.0;
		q = max(vec4(0.0), (q + P.dt * g * vec4(dL, dR, dT, dB)) * P.damp);
		float outv = (q.r + q.g + q.b + q.a) * P.dt;
		if (outv > 1e-9) {
			q *= min(1.0, f.g / outv);
		}
		imageStore(flux, p, q);
	} else {
		// integrate water depth from neighbor fluxes
		vec4 f = imageLoad(field_in, p);
		vec4 q = imageLoad(flux, p);
		float inL = p.x > 0       ? imageLoad(flux, p + ivec2(-1, 0)).g : 0.0;
		float inR = p.x < P.n - 1 ? imageLoad(flux, p + ivec2( 1, 0)).r : 0.0;
		float inT = p.y > 0       ? imageLoad(flux, p + ivec2(0, -1)).a : 0.0;
		float inB = p.y < P.n - 1 ? imageLoad(flux, p + ivec2(0,  1)).b : 0.0;
		float w = max(0.0, f.g + P.dt * ((inL + inR + inT + inB) - (q.r + q.g + q.b + q.a)));
		float fl = (q.r + q.g + q.b + q.a + inL + inR + inT + inB) * 0.5 / max(0.05, w);

		// open sea boundary: force surface toward sea level + surge
		if (p.y >= P.n - 3) {
			float target = max(0.0, P.sea + P.surge - f.r);
			w += (target - w) * 0.5;
			if (P.surge > 0.05) {
				vec4 qq = imageLoad(flux, p);
				qq.b = max(qq.b, P.surge * 4.0);   // shoreward push (-z)
				imageStore(flux, p, qq);
			}
		}

		// moisture: soak fast under water, dry slowly on land
		float m = f.b;
		if (w > 0.02) { m = min(1.0, m + P.dt * 2.5); }
		else { m = max(0.0, m - P.dt * 0.008); }

		// foam from churning water
		float foam = f.a * 0.94;
		if (fl > 1.0 && w > 0.01) { foam = min(1.0, foam + (fl - 1.0) * P.dt * 2.2); }

		imageStore(field_out, p, vec4(f.r, w, m, foam));
	}
}
