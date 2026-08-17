#[compute]
#version 450

// 3D MLS-MPM: water (EOS fluid) + sand (fixed corotated + snow-style plasticity).
// Fixed-point atomic P2G scatter. Unit-cube domain.
// modes: 0 clear grid | 1 P2G | 2 grid update | 3 G2P + position texture

layout(local_size_x = 64) in;

// particle: pos(xyz)+material(w) | vel(xyz)+J_or_Jp(w) | C rows | F rows
layout(set = 0, binding = 0, std430) restrict buffer Particles { vec4 d[]; } PB;
layout(set = 0, binding = 1, std430) restrict buffer Grid { int g[]; } GB; // 4 ints/cell: mvx mvy mvz mass
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2D pos_tex;

layout(push_constant) uniform Params {
	float dt; float dx; float inv_dx; float gravity;
	float mode; float n_particles; float n_grid; float e_water;
	float e_sand; float time; float pad0; float pad1;
} P;

const float FIX = 65536.0;
const int STRIDE = 8; // vec4s per particle

int gidx(ivec3 c, int n) { return ((c.z * n + c.y) * n + c.x) * 4; }

// ---- 3x3 SVD via Jacobi on F^T F ----
void jacobi_rot(inout mat3 S, inout mat3 V, int p, int q) {
	float apq = S[q][p];
	if (abs(apq) < 1e-9) { return; }
	float app = S[p][p];
	float aqq = S[q][q];
	float tau = (aqq - app) / (2.0 * apq);
	float t = sign(tau) / (abs(tau) + sqrt(1.0 + tau * tau));
	if (tau == 0.0) { t = 1.0; }
	float c = inversesqrt(1.0 + t * t);
	float s = t * c;
	mat3 J = mat3(1.0);
	J[p][p] = c; J[q][q] = c;
	J[q][p] = s; J[p][q] = -s;
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
	// re-orthonormalize U against numerical drift
	U[0] = normalize(U[0]);
	U[1] = normalize(U[1] - U[0] * dot(U[0], U[1]));
	U[2] = cross(U[0], U[1]);
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	int mode = int(P.mode);
	int n = int(P.n_grid);
	int np = int(P.n_particles);

	if (mode == 0) {
		int ncells = n * n * n;
		if (int(i) >= ncells) { return; }
		GB.g[i * 4u] = 0; GB.g[i * 4u + 1u] = 0; GB.g[i * 4u + 2u] = 0; GB.g[i * 4u + 3u] = 0;

	} else if (mode == 1) {
		// ---------- P2G ----------
		if (int(i) >= np) { return; }
		uint b = i * uint(STRIDE);
		vec3 x = PB.d[b].xyz;
		float mat_id = PB.d[b].w;
		vec3 v = PB.d[b + 1u].xyz;
		float jp = PB.d[b + 1u].w;
		mat3 C = mat3(PB.d[b + 2u].xyz, PB.d[b + 3u].xyz, PB.d[b + 4u].xyz); // columns
		mat3 F = mat3(PB.d[b + 5u].xyz, PB.d[b + 6u].xyz, PB.d[b + 7u].xyz);

		mat3 stress_a; // affine = stress term + C
		if (mat_id < 0.5) {
			// water: track J, pressure EOS
			jp *= 1.0 + P.dt * (C[0][0] + C[1][1] + C[2][2]);
			jp = clamp(jp, 0.25, 2.0);
			float pr = P.e_water * (jp - 1.0);
			stress_a = mat3(1.0) * (-P.dt * 4.0 * P.inv_dx * P.inv_dx * pr);
		} else {
			// sand: F update, plasticity clamp, fixed corotated stress
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
			mat3 R = U * transpose(V);
			mat3 PF = 2.0 * mu * (F - R) * transpose(F) + mat3(1.0) * (la * J * (J - 1.0));
			stress_a = (-P.dt * 4.0 * P.inv_dx * P.inv_dx) * PF;
		}
		mat3 affine = stress_a + C;

		vec3 xg = x * P.inv_dx;
		ivec3 base = ivec3(xg - 0.5);
		vec3 fx = xg - vec3(base);
		vec3 w0 = 0.5 * (1.5 - fx) * (1.5 - fx);
		vec3 w1 = 0.75 - (fx - 1.0) * (fx - 1.0);
		vec3 w2 = 0.5 * (fx - 0.5) * (fx - 0.5);
		for (int dz = 0; dz < 3; dz++)
		for (int dy = 0; dy < 3; dy++)
		for (int dx_ = 0; dx_ < 3; dx_++) {
			ivec3 c = base + ivec3(dx_, dy, dz);
			if (any(lessThan(c, ivec3(0))) || any(greaterThanEqual(c, ivec3(n)))) { continue; }
			vec3 wv = vec3(dx_ == 0 ? w0.x : (dx_ == 1 ? w1.x : w2.x),
					dy == 0 ? w0.y : (dy == 1 ? w1.y : w2.y),
					dz == 0 ? w0.z : (dz == 1 ? w1.z : w2.z));
			float w = wv.x * wv.y * wv.z;
			vec3 dpos = (vec3(dx_, dy, dz) - fx) * P.dx;
			vec3 mv = w * (v + affine * dpos);
			int gi = gidx(c, n);
			atomicAdd(GB.g[gi], int(mv.x * FIX));
			atomicAdd(GB.g[gi + 1], int(mv.y * FIX));
			atomicAdd(GB.g[gi + 2], int(mv.z * FIX));
			atomicAdd(GB.g[gi + 3], int(w * FIX));
		}
		PB.d[b + 1u].w = jp;
		PB.d[b + 5u] = vec4(F[0], 0.0);
		PB.d[b + 6u] = vec4(F[1], 0.0);
		PB.d[b + 7u] = vec4(F[2], 0.0);

	} else if (mode == 2) {
		// ---------- grid update ----------
		int ncells = n * n * n;
		if (int(i) >= ncells) { return; }
		int m = GB.g[i * 4u + 3u];
		if (m <= 0) { return; }
		vec3 v = vec3(GB.g[i * 4u], GB.g[i * 4u + 1u], GB.g[i * 4u + 2u]) / float(m);
		v.y -= P.dt * P.gravity;
		int x = int(i) % n;
		int y = (int(i) / n) % n;
		int z = int(i) / (n * n);
		if (y < 3 && v.y < 0.0) { v.y = 0.0; v.xz *= 0.85; }
		if (y > n - 4 && v.y > 0.0) { v.y = 0.0; }
		if (x < 3 && v.x < 0.0) { v.x = 0.0; }
		if (x > n - 4 && v.x > 0.0) { v.x = 0.0; }
		if (z < 3 && v.z < 0.0) { v.z = 0.0; }
		if (z > n - 4 && v.z > 0.0) { v.z = 0.0; }
		GB.g[i * 4u] = int(v.x * FIX);
		GB.g[i * 4u + 1u] = int(v.y * FIX);
		GB.g[i * 4u + 2u] = int(v.z * FIX);

	} else {
		// ---------- G2P + advect + render texture ----------
		if (int(i) >= np) { return; }
		uint b = i * uint(STRIDE);
		vec3 x = PB.d[b].xyz;
		float mat_id = PB.d[b].w;

		vec3 xg = x * P.inv_dx;
		ivec3 base = ivec3(xg - 0.5);
		vec3 fx = xg - vec3(base);
		vec3 w0 = 0.5 * (1.5 - fx) * (1.5 - fx);
		vec3 w1 = 0.75 - (fx - 1.0) * (fx - 1.0);
		vec3 w2 = 0.5 * (fx - 0.5) * (fx - 0.5);
		vec3 nv = vec3(0.0);
		mat3 nC = mat3(0.0);
		for (int dz = 0; dz < 3; dz++)
		for (int dy = 0; dy < 3; dy++)
		for (int dx_ = 0; dx_ < 3; dx_++) {
			ivec3 c = base + ivec3(dx_, dy, dz);
			if (any(lessThan(c, ivec3(0))) || any(greaterThanEqual(c, ivec3(n)))) { continue; }
			vec3 wv = vec3(dx_ == 0 ? w0.x : (dx_ == 1 ? w1.x : w2.x),
					dy == 0 ? w0.y : (dy == 1 ? w1.y : w2.y),
					dz == 0 ? w0.z : (dz == 1 ? w1.z : w2.z));
			float w = wv.x * wv.y * wv.z;
			int gi = gidx(c, n);
			vec3 gv = vec3(GB.g[gi], GB.g[gi + 1], GB.g[gi + 2]) / FIX;
			vec3 dpos = vec3(dx_, dy, dz) - fx;
			nv += w * gv;
			nC += (4.0 * P.inv_dx * w) * outerProduct(gv, dpos);
		}
		x += P.dt * nv;
		x = clamp(x, vec3(P.dx * 2.5), vec3(1.0 - P.dx * 2.5));
		PB.d[b] = vec4(x, mat_id);
		PB.d[b + 1u] = vec4(nv, PB.d[b + 1u].w);
		PB.d[b + 2u] = vec4(nC[0], 0.0);
		PB.d[b + 3u] = vec4(nC[1], 0.0);
		PB.d[b + 4u] = vec4(nC[2], 0.0);

		ivec2 tc = ivec2(int(i) % 512, int(i) / 512);
		float spd = clamp(length(nv) * 0.10, 0.0, 0.95);
		imageStore(pos_tex, tc, vec4(x, mat_id + spd));
	}
}
