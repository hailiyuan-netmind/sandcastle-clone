#[compute]
#version 450

// MPM active zone over the beach heightfield.
// World-space particles; heightfield is the collision boundary; settled sand
// deposits back into the field via an atomic image consumed by sim.glsl.
// modes: 0 clear grid | 1 consume spawn queue | 2 P2G | 3 grid+collide | 4 G2P

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Particles { vec4 d[]; } PB;
layout(set = 0, binding = 1, std430) restrict buffer Grid { int g[]; } GB;
layout(set = 0, binding = 2, std430) restrict buffer Spawn { int count; int cursor; int pad2; int pad3; vec4 q[]; } SQ;
layout(r32i, set = 0, binding = 3) uniform restrict iimage2D dep_img;
layout(rgba32f, set = 0, binding = 4) uniform restrict readonly image2D field_a;
layout(rgba32f, set = 0, binding = 5) uniform restrict readonly image2D field_b;
layout(rgba32f, set = 0, binding = 6) uniform restrict writeonly image2D pos_tex;

layout(push_constant) uniform Params {
	float dt; float grav; float mode; float pool;
	float gx; float gy; float gz; float cell;
	float ox; float oy; float oz; float cur;
	float e_sand; float e_water; float maxq; float fieldn;
} P;

const float FIX = 65536.0;
const int STRIDE = 8;
const float PV_H = 0.030; // 单粒子沉积回高度场的高度增量(格面积0.25 → 体积0.0075)

int lidx(ivec3 c) { return ((c.z * int(P.gy) + c.y) * int(P.gx) + c.x) * 4; }

vec4 fieldAt(ivec2 c) {
	c = clamp(c, ivec2(0), ivec2(int(P.fieldn) - 1));
	return P.cur < 0.5 ? imageLoad(field_a, c) : imageLoad(field_b, c);
}

float sandH(float wx, float wz) { // 世界坐标→高度场双线性
	float gxf = (wx + 96.0) * 2.0;
	float gzf = (wz + 96.0) * 2.0;
	ivec2 c = ivec2(floor(vec2(gxf, gzf)));
	vec2 fr = vec2(gxf, gzf) - vec2(c);
	float a = fieldAt(c).r;
	float b = fieldAt(c + ivec2(1, 0)).r;
	float cc = fieldAt(c + ivec2(0, 1)).r;
	float dd = fieldAt(c + ivec2(1, 1)).r;
	return mix(mix(a, b, fr.x), mix(cc, dd, fr.x), fr.y);
}

void jacobi_rot(inout mat3 S, inout mat3 V, int p, int q) {
	float apq = S[q][p];
	if (abs(apq) < 1e-9) { return; }
	float tau = (S[q][q] - S[p][p]) / (2.0 * apq);
	float t = sign(tau) / (abs(tau) + sqrt(1.0 + tau * tau));
	if (tau == 0.0) { t = 1.0; }
	float c = inversesqrt(1.0 + t * t);
	float s = t * c;
	mat3 J = mat3(1.0);
	J[p][p] = c; J[q][q] = c; J[q][p] = s; J[p][q] = -s;
	S = transpose(J) * S * J;
	V = V * J;
}

void svd3(mat3 A, out mat3 U, out vec3 sig, out mat3 V) {
	mat3 S = transpose(A) * A;
	V = mat3(1.0);
	for (int sweep = 0; sweep < 5; sweep++) {
		jacobi_rot(S, V, 0, 1);
		jacobi_rot(S, V, 0, 2);
		jacobi_rot(S, V, 1, 2);
	}
	sig = vec3(sqrt(max(S[0][0], 1e-12)), sqrt(max(S[1][1], 1e-12)), sqrt(max(S[2][2], 1e-12)));
	U = mat3(A * V[0] / sig.x, A * V[1] / sig.y, A * V[2] / sig.z);
	U[0] = normalize(U[0]);
	U[1] = normalize(U[1] - U[0] * dot(U[0], U[1]));
	U[2] = cross(U[0], U[1]);
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	int mode = int(P.mode);
	ivec3 gd = ivec3(int(P.gx), int(P.gy), int(P.gz));
	int ncells = gd.x * gd.y * gd.z;
	int pool = int(P.pool);
	vec3 origin = vec3(P.ox, P.oy, P.oz);
	float inv_cell = 1.0 / P.cell;

	if (mode == 0) {
		if (int(i) >= ncells) { return; }
		GB.g[i * 4u] = 0; GB.g[i * 4u + 1u] = 0; GB.g[i * 4u + 2u] = 0; GB.g[i * 4u + 3u] = 0;

	} else if (mode == 1) {
		// ---- 消费生成队列:环形覆盖最旧粒子 ----
		int n = min(SQ.count, int(P.maxq));
		if (int(i) >= n) { return; }
		int slot = atomicAdd(SQ.cursor, 1) % pool;
		uint b = uint(slot) * uint(STRIDE);
		vec4 pm = SQ.q[i * 2u];
		vec4 vl = SQ.q[i * 2u + 1u];
		PB.d[b] = pm;                                   // pos + mat
		PB.d[b + 1u] = vec4(vl.xyz, 1.0);               // vel + Jp
		PB.d[b + 2u] = vec4(0.0);                       // C0 + age
		PB.d[b + 3u] = vec4(0.0);
		PB.d[b + 4u] = vec4(0.0);
		PB.d[b + 5u] = vec4(1.0, 0.0, 0.0, 0.0);        // F = I
		PB.d[b + 6u] = vec4(0.0, 1.0, 0.0, 0.0);
		PB.d[b + 7u] = vec4(0.0, 0.0, 1.0, 0.0);

	} else if (mode == 2) {
		// ---- P2G ----
		if (int(i) >= pool) { return; }
		uint b = i * uint(STRIDE);
		vec4 pm = PB.d[b];
		if (pm.w < -0.5) { return; }
		vec3 v = PB.d[b + 1u].xyz;
		float jp = PB.d[b + 1u].w;
		mat3 C = mat3(PB.d[b + 2u].xyz, PB.d[b + 3u].xyz, PB.d[b + 4u].xyz);
		mat3 F = mat3(PB.d[b + 5u].xyz, PB.d[b + 6u].xyz, PB.d[b + 7u].xyz);

		mat3 stress_a;
		if (pm.w < 0.5) {
			jp *= 1.0 + P.dt * (C[0][0] + C[1][1] + C[2][2]);
			jp = clamp(jp, 0.3, 1.8);
			stress_a = mat3(1.0) * (-P.dt * 4.0 * inv_cell * inv_cell * (P.e_water * (jp - 1.0)));
		} else {
			F = (mat3(1.0) + P.dt * C) * F;
			mat3 U; vec3 sig; mat3 V;
			svd3(F, U, sig, V);
			for (int k = 0; k < 3; k++) {
				float s_old = sig[k];
				sig[k] = clamp(sig[k], 1.0 - 2.5e-2, 1.0 + 4.5e-3);
				jp = clamp(jp * s_old / sig[k], 0.5, 4.0);
			}
			mat3 Sig = mat3(1.0);
			Sig[0][0] = sig.x; Sig[1][1] = sig.y; Sig[2][2] = sig.z;
			F = U * Sig * transpose(V);
			float h = clamp(exp(8.0 * (1.0 - jp)), 0.1, 5.0);
			float mu = P.e_sand * h;
			float la = P.e_sand * 0.4 * h;
			float J = sig.x * sig.y * sig.z;
			mat3 PF = 2.0 * mu * (F - U * transpose(V)) * transpose(F) + mat3(1.0) * (la * J * (J - 1.0));
			stress_a = (-P.dt * 4.0 * inv_cell * inv_cell) * PF;
			PB.d[b + 5u] = vec4(F[0], 0.0);
			PB.d[b + 6u] = vec4(F[1], 0.0);
			PB.d[b + 7u] = vec4(F[2], 0.0);
		}
		PB.d[b + 1u].w = jp;
		mat3 affine = stress_a + C;

		vec3 local = (pm.xyz - origin) * inv_cell;
		ivec3 base = ivec3(local - 0.5);
		vec3 fx = local - vec3(base);
		vec3 w0 = 0.5 * (1.5 - fx) * (1.5 - fx);
		vec3 w1 = 0.75 - (fx - 1.0) * (fx - 1.0);
		vec3 w2 = 0.5 * (fx - 0.5) * (fx - 0.5);
		for (int dz = 0; dz < 3; dz++)
		for (int dy = 0; dy < 3; dy++)
		for (int dx = 0; dx < 3; dx++) {
			ivec3 c = base + ivec3(dx, dy, dz);
			if (any(lessThan(c, ivec3(0))) || any(greaterThanEqual(c, gd))) { continue; }
			float w = (dx == 0 ? w0.x : (dx == 1 ? w1.x : w2.x))
				* (dy == 0 ? w0.y : (dy == 1 ? w1.y : w2.y))
				* (dz == 0 ? w0.z : (dz == 1 ? w1.z : w2.z));
			vec3 dpos = (vec3(dx, dy, dz) - fx) * P.cell;
			vec3 mv = w * (v + affine * dpos);
			int gi = lidx(c);
			atomicAdd(GB.g[gi], int(mv.x * FIX));
			atomicAdd(GB.g[gi + 1], int(mv.y * FIX));
			atomicAdd(GB.g[gi + 2], int(mv.z * FIX));
			atomicAdd(GB.g[gi + 3], int(w * FIX));
		}

	} else if (mode == 3) {
		// ---- 网格更新 + 高度场碰撞 ----
		if (int(i) >= ncells) { return; }
		int m = GB.g[i * 4u + 3u];
		if (m <= 0) { return; }
		vec3 v = vec3(GB.g[i * 4u], GB.g[i * 4u + 1u], GB.g[i * 4u + 2u]) / float(m);
		v.y -= P.dt * P.grav;
		int x = int(i) % gd.x;
		int y = (int(i) / gd.x) % gd.y;
		int z = int(i) / (gd.x * gd.y);
		vec3 wp = origin + vec3(x, y, z) * P.cell;
		float h = sandH(wp.x, wp.z);
		if (wp.y < h + 0.4) {
			float hx = sandH(wp.x + P.cell, wp.z) - sandH(wp.x - P.cell, wp.z);
			float hz = sandH(wp.x, wp.z + P.cell) - sandH(wp.x, wp.z - P.cell);
			vec3 nrm = normalize(vec3(-hx, 2.0 * P.cell, -hz));
			float vn = dot(v, nrm);
			if (vn < 0.0) { v -= vn * nrm; }
			v *= 0.94;
			if (wp.y < h - 0.9) { v = vec3(0.0); }
		}
		if (x < 2 && v.x < 0.0) { v.x = 0.0; }
		if (x > gd.x - 3 && v.x > 0.0) { v.x = 0.0; }
		if (z < 2 && v.z < 0.0) { v.z = 0.0; }
		if (z > gd.z - 3 && v.z > 0.0) { v.z = 0.0; }
		if (y > gd.y - 3 && v.y > 0.0) { v.y = 0.0; }
		GB.g[i * 4u] = int(v.x * FIX);
		GB.g[i * 4u + 1u] = int(v.y * FIX);
		GB.g[i * 4u + 2u] = int(v.z * FIX);

	} else {
		// ---- G2P + 沉降回写 ----
		if (int(i) >= pool) { return; }
		uint b = i * uint(STRIDE);
		vec4 pm = PB.d[b];
		if (pm.w < -0.5) {
			imageStore(pos_tex, ivec2(int(i) % 256, int(i) / 256), vec4(0.0, -1000.0, 0.0, 0.0));
			return;
		}
		vec3 local = (pm.xyz - origin) * inv_cell;
		ivec3 base = ivec3(local - 0.5);
		vec3 fx = local - vec3(base);
		vec3 w0 = 0.5 * (1.5 - fx) * (1.5 - fx);
		vec3 w1 = 0.75 - (fx - 1.0) * (fx - 1.0);
		vec3 w2 = 0.5 * (fx - 0.5) * (fx - 0.5);
		vec3 nv = vec3(0.0);
		mat3 nC = mat3(0.0);
		for (int dz = 0; dz < 3; dz++)
		for (int dy = 0; dy < 3; dy++)
		for (int dx = 0; dx < 3; dx++) {
			ivec3 c = base + ivec3(dx, dy, dz);
			if (any(lessThan(c, ivec3(0))) || any(greaterThanEqual(c, gd))) { continue; }
			float w = (dx == 0 ? w0.x : (dx == 1 ? w1.x : w2.x))
				* (dy == 0 ? w0.y : (dy == 1 ? w1.y : w2.y))
				* (dz == 0 ? w0.z : (dz == 1 ? w1.z : w2.z));
			int gi = lidx(c);
			vec3 gv = vec3(GB.g[gi], GB.g[gi + 1], GB.g[gi + 2]) / FIX;
			nv += w * gv;
			nC += (4.0 * inv_cell * w) * outerProduct(gv, vec3(dx, dy, dz) - fx);
		}
		vec3 x = pm.xyz + P.dt * nv;
		float age = PB.d[b + 2u].w + 1.0;
		float h = sandH(x.x, x.z);
		if (x.y < h - 0.2) { x.y = h - 0.1; }  // 别穿进沙里太深

		bool kill = false;
		bool in_zone = x.x > P.ox + 1.0 && x.x < P.ox + P.gx * P.cell - 1.0
			&& x.z > P.oz + 1.0 && x.z < P.oz + P.gz * P.cell - 1.0 && x.y < P.oy + P.gy * P.cell - 1.0;
		if (!in_zone || age > 900.0) { kill = true; }
		float spd = length(nv);
		if (pm.w > 0.5) {
			// 沙:慢 + 贴地 → 沉积回高度场
			if (age > 40.0 && spd < 0.55 && x.y < h + 0.8) {
				ivec2 fc = clamp(ivec2((x.xz + 96.0) * 2.0), ivec2(0), ivec2(int(P.fieldn) - 1));
				imageAtomicAdd(dep_img, fc, int(PV_H * 1000.0));
				kill = true;
			}
		} else {
			// 水沫:慢 + 贴近水面/沙面 → 回归大海
			if (age > 30.0 && spd < 0.8 && x.y < h + 1.0) { kill = true; }
		}

		if (kill) {
			PB.d[b] = vec4(0.0, -1000.0, 0.0, -1.0);
			imageStore(pos_tex, ivec2(int(i) % 256, int(i) / 256), vec4(0.0, -1000.0, 0.0, 0.0));
			return;
		}
		PB.d[b] = vec4(x, pm.w);
		PB.d[b + 1u] = vec4(nv, PB.d[b + 1u].w);
		PB.d[b + 2u] = vec4(nC[0], age);
		PB.d[b + 3u] = vec4(nC[1], 0.0);
		PB.d[b + 4u] = vec4(nC[2], 0.0);
		imageStore(pos_tex, ivec2(int(i) % 256, int(i) / 256),
			vec4(x, pm.w + clamp(spd * 0.12, 0.0, 0.9)));
	}
}
