# 2D MLS-MPM feasibility demo for the Sandcastle 3D roadmap:
# a wet-sand castle vs a dam-break wave, water and sand coupled in one solver.
# Adapted from Taichi's classic mpm99 example (MIT), material params retuned toward sand.
#
# Run:  python -m venv venv && venv/bin/pip install taichi pillow
#       venv/bin/python mpm_sand_demo.py [outdir]
import taichi as ti
import time, os, sys

ti.init(arch=ti.gpu)  # Metal on macOS, CUDA/Vulkan elsewhere; auto-falls back to CPU

OUT = sys.argv[1] if len(sys.argv) > 1 else 'frames'
os.makedirs(OUT, exist_ok=True)

n_particles = 26000
n_grid = 128
dx, inv_dx = 1 / n_grid, float(n_grid)
dt = 1e-4
p_vol, p_rho = (dx * 0.5) ** 2, 1
p_mass = p_vol * p_rho
E, nu = 8e3, 0.2
mu_0 = E / (2 * (1 + nu))
lambda_0 = E * nu / ((1 + nu) * (1 - 2 * nu))

WATER, SAND = 0, 1

x = ti.Vector.field(2, dtype=float, shape=n_particles)
v = ti.Vector.field(2, dtype=float, shape=n_particles)
C = ti.Matrix.field(2, 2, dtype=float, shape=n_particles)
F = ti.Matrix.field(2, 2, dtype=float, shape=n_particles)
material = ti.field(dtype=int, shape=n_particles)
Jp = ti.field(dtype=float, shape=n_particles)
grid_v = ti.Vector.field(2, dtype=float, shape=(n_grid, n_grid))
grid_m = ti.field(dtype=float, shape=(n_grid, n_grid))


@ti.kernel
def substep():
    for i, j in grid_m:
        grid_v[i, j] = [0, 0]
        grid_m[i, j] = 0
    for p in x:  # P2G
        base = (x[p] * inv_dx - 0.5).cast(int)
        fx = x[p] * inv_dx - base.cast(float)
        w = [0.5 * (1.5 - fx) ** 2, 0.75 - (fx - 1) ** 2, 0.5 * (fx - 0.5) ** 2]
        F[p] = (ti.Matrix.identity(float, 2) + dt * C[p]) @ F[p]
        h = ti.max(0.1, ti.min(5.0, ti.exp(8.0 * (1.0 - Jp[p]))))  # hardening
        mu, la = mu_0 * h, lambda_0 * h
        if material[p] == WATER:
            mu = 0.0
        U, sig, V = ti.svd(F[p])
        J = 1.0
        for d in ti.static(range(2)):
            new_sig = sig[d, d]
            if material[p] == SAND:
                # plasticity clamp: wider compression band than snow -> crumbly, sand-like
                new_sig = ti.min(ti.max(sig[d, d], 1 - 3.5e-2), 1 + 4.5e-3)
            Jp[p] *= sig[d, d] / new_sig
            sig[d, d] = new_sig
            J *= new_sig
        if material[p] == WATER:
            F[p] = ti.Matrix.identity(float, 2) * ti.sqrt(J)
        else:
            F[p] = U @ sig @ V.transpose()
        stress = 2 * mu * (F[p] - U @ V.transpose()) @ F[p].transpose() \
                 + ti.Matrix.identity(float, 2) * la * J * (J - 1)
        stress = (-dt * p_vol * 4 * inv_dx * inv_dx) * stress
        affine = stress + p_mass * C[p]
        for i, j in ti.static(ti.ndrange(3, 3)):
            offset = ti.Vector([i, j])
            dpos = (offset.cast(float) - fx) * dx
            weight = w[i][0] * w[j][1]
            grid_v[base + offset] += weight * (p_mass * v[p] + affine @ dpos)
            grid_m[base + offset] += weight * p_mass
    for i, j in grid_m:  # grid ops
        if grid_m[i, j] > 0:
            grid_v[i, j] = (1 / grid_m[i, j]) * grid_v[i, j]
            grid_v[i, j][1] -= dt * 50  # gravity
            if i < 3 and grid_v[i, j][0] < 0: grid_v[i, j][0] = 0
            if i > n_grid - 3 and grid_v[i, j][0] > 0: grid_v[i, j][0] = 0
            if j < 3 and grid_v[i, j][1] < 0: grid_v[i, j][1] = 0
            if j > n_grid - 3 and grid_v[i, j][1] > 0: grid_v[i, j][1] = 0
    for p in x:  # G2P
        base = (x[p] * inv_dx - 0.5).cast(int)
        fx = x[p] * inv_dx - base.cast(float)
        w = [0.5 * (1.5 - fx) ** 2, 0.75 - (fx - 1) ** 2, 0.5 * (fx - 0.5) ** 2]
        new_v = ti.Vector.zero(float, 2)
        new_C = ti.Matrix.zero(float, 2, 2)
        for i, j in ti.static(ti.ndrange(3, 3)):
            dpos = ti.Vector([i, j]).cast(float) - fx
            g_v = grid_v[base + ti.Vector([i, j])]
            weight = w[i][0] * w[j][1]
            new_v += weight * g_v
            new_C += 4 * inv_dx * weight * g_v.outer_product(dpos)
        v[p], C[p] = new_v, new_C
        x[p] += dt * v[p]


@ti.kernel
def init():
    for p in range(n_particles):
        if p < n_particles * 11 // 20:  # 55% water: dam column on the right
            material[p] = WATER
            x[p] = [0.70 + ti.random() * 0.27, 0.02 + ti.random() * 0.40]
            v[p] = [-0.6, 0.0]
        else:  # 45% sand: castle wall + tower on the left, sitting on the floor
            material[p] = SAND
            r = ti.random()
            if r < 0.72:
                x[p] = [0.28 + ti.random() * 0.22, 0.02 + ti.random() * 0.20]  # base
            else:
                x[p] = [0.34 + ti.random() * 0.10, 0.22 + ti.random() * 0.13]  # tower
            v[p] = [0.0, 0.0]
        F[p] = ti.Matrix([[1, 0], [0, 1]])
        Jp[p] = 1.0
        C[p] = ti.Matrix.zero(float, 2, 2)


init()
gui = ti.GUI('mpm-sand', res=(512, 512), show_gui=False, background_color=0xBFE2F0)
FRAMES, SPF = 240, 20            # 240 frames x 20 substeps = 0.48s sim time
t0 = time.time()
for f in range(FRAMES):
    for s in range(SPF):
        substep()
    gui.circles(x.to_numpy(), radius=1.6,
                palette=[0x2E8FBF, 0xE0C080], palette_indices=material.to_numpy())
    gui.show(os.path.join(OUT, f'f{f:03d}.png'))
wall = time.time() - t0
print(f'particles={n_particles} grid={n_grid} substeps={FRAMES*SPF}')
print(f'wall={wall:.1f}s  substeps/s={FRAMES*SPF/wall:.0f}  sim-fps(20 substeps/frame)={FRAMES/wall:.1f}')
