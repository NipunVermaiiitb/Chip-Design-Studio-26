#!/usr/bin/env python3
"""
vcnpu_full_sim_fast.py

Combined tool (fast):
 - mock transform-mask generator
 - optimized mask loader (precomputes per-layer SCU counts)
 - refined, fast cycle-accurate simulator using exact nonzero coords (vectorized)

Usage:
  python vcnpu_full_sim_fast.py --gen-masks --outdir transform_masks
  python vcnpu_full_sim_fast.py --run-sim --mask-dir transform_masks --frame-H 720 --frame-W 1280
"""

import os, math, time, argparse
from collections import deque, namedtuple, defaultdict
import numpy as np

# -------------------------
# Config
# -------------------------
class Config:
    CLOCK_FREQ = 400e6
    NUM_CORES = 2
    PIF = 12
    POF = 4
    SCU_MULTIPLIERS = 18
    MU_C = 4
    MU_D = 6
    RHO_C = 0.375
    RHO_D = 0.50
    SFTM_INPUT_BUFFER_KB = 32
    SFTM_OUTPUT_BUFFER_KB = 32
    SFTM_NUM_BANKS = 4
    ACTIVATION_BYTES = 2
    WEIGHT_BYTES = 2
    PRETU_LATENCY = 4
    POSTTU_LATENCY = 4
    SCU_PIPELINE_LATENCY = 2
    EXTERNAL_BW_GBPS = 12.8
    DEFAULT_TILE_INPUT_ROWS = 8
    DEFAULT_TILE_OUTPUT_ROWS = 4
    DFCONV_INTERP_COST_PER_SAMPLE = 2
    DFCONV_PE_COUNT = 64
    RNG_SEED = 12345

# -------------------------
# External memory model
# -------------------------
class ExternalMemory:
    def __init__(self, ext_bw_gbps=Config.EXTERNAL_BW_GBPS, clk=Config.CLOCK_FREQ):
        self.bytes_per_cycle = (ext_bw_gbps * 1e9)/clk
        self.bytes_read = 0
        self.bytes_written = 0
    def read(self,b):
        cycles = math.ceil(b/self.bytes_per_cycle) if self.bytes_per_cycle>0 else 0
        self.bytes_read += b
        return cycles
    def write(self,b):
        cycles = math.ceil(b/self.bytes_per_cycle) if self.bytes_per_cycle>0 else 0
        self.bytes_written += b
        return cycles

# -------------------------
# Mock mask generator
# -------------------------
def mu_for_k(k):
    return Config.MU_C if k==3 else (Config.MU_D if k==4 else k+1)

def generate_mock_transform_masks(outdir="transform_masks", layers=None, seed=Config.RNG_SEED):
    rng = np.random.default_rng(seed)
    os.makedirs(outdir, exist_ok=True)
    if layers is None:
        layers = [
            ("RFConv0",36,36,3),
            ("RFConv1",36,36,3),
            ("RFDeConv0",36,36,4),
            ("RFConv2",36,36,3),
            ("RFConv3",36,36,3),
            ("RFDeConv1",36,36,4),
        ]
    for (name,out_ch,in_ch,k) in layers:
        mu = mu_for_k(k)
        shape = (out_ch,in_ch,mu,mu)
        full = rng.laplace(loc=0.0,scale=1.0,size=shape).astype(np.float32)
        scales_out = 0.5 + rng.random(out_ch).astype(np.float32)
        scales_in  = 0.5 + rng.random(in_ch).astype(np.float32)
        for o in range(out_ch):
            for i in range(in_ch):
                full[o,i,:,:] *= (scales_out[o]*scales_in[i])
        keep = Config.RHO_C if k==3 else Config.RHO_D
        flat = np.abs(full).ravel()
        total = flat.size
        keep_k = int(math.ceil(total*keep))
        if keep_k <=0:
            mask = np.zeros_like(full, dtype=bool)
        elif keep_k >= total:
            mask = np.ones_like(full, dtype=bool)
        else:
            thr = np.partition(flat, -keep_k)[-keep_k]
            mask = np.abs(full) >= thr
            cur = mask.sum()
            if cur > keep_k:
                locs = np.where(mask & (np.abs(full)==thr))
                rm = cur - keep_k
                for idx in zip(*locs):
                    if rm==0: break
                    mask[idx]=False
                    rm -=1
        idx = np.nonzero(mask)
        values = full[idx].astype(np.float32)
        npz_name = os.path.join(outdir, f"{name}.npz")
        np.savez_compressed(npz_name,
                            shape=np.array(shape,dtype=np.int32),
                            idx0=np.array(idx[0],dtype=np.int32),
                            idx1=np.array(idx[1],dtype=np.int32),
                            idx2=np.array(idx[2],dtype=np.int32),
                            idx3=np.array(idx[3],dtype=np.int32),
                            values=values,
                            mask_fraction=np.array([float(values.size)/total],dtype=np.float32))
        print(f"Wrote {npz_name}: shape={shape}, nonzeros={values.size}, frac={values.size/total:.6f}")
    print("Mock transform masks generation complete.")

# -------------------------
# Load .npz mask (unchanged)
# -------------------------
def load_sparse_npz_for_layer(npz_dir, layer_name):
    fname = os.path.join(npz_dir, f"{layer_name}.npz")
    if not os.path.exists(fname):
        fname2 = os.path.join(npz_dir, f"{layer_name.replace('.', '_')}.npz")
        if os.path.exists(fname2):
            fname = fname2
        else:
            return None
    d = np.load(fname)
    shape = tuple(map(int, d['shape']))
    idx0 = d['idx0'].astype(int)
    idx1 = d['idx1'].astype(int)
    idx2 = d['idx2'].astype(int)
    idx3 = d['idx3'].astype(int)
    coords = np.stack([idx0, idx1, idx2, idx3], axis=1)
    values = d['values'].astype(np.float32) if 'values' in d else None
    mask_frac = float(d['mask_fraction'].ravel()[0]) if 'mask_fraction' in d else float(coords.shape[0]/np.prod(shape))
    return {"shape":shape, "coords":coords, "values":values, "mask_fraction":mask_frac}

# -------------------------
# Simulator building blocks (optimized)
# -------------------------
TileJob = namedtuple('TileJob',['layer','tile_idx','rows','cols','in_ch','out_ch','type'])

class SCU:
    def __init__(self, core_id, r, c, multipliers=Config.SCU_MULTIPLIERS):
        self.core = core_id
        self.r = r
        self.c = c
        self.multipliers = multipliers
        self.assigned_mults = 0
    def assign(self,n):
        self.assigned_mults += n
    def reset(self):
        self.assigned_mults = 0
    def cycles_needed(self):
        return math.ceil(self.assigned_mults/self.multipliers) if self.assigned_mults>0 else 0

class SFTM:
    def __init__(self, core_id, ext, stats, config=Config):
        self.core_id = core_id
        self.ext = ext
        self.stats = stats
        self.config = config
        self.rows = config.POF
        self.cols = config.PIF
        self.scu_grid = [[SCU(core_id,r,c) for c in range(self.cols)] for r in range(self.rows)]
        self.job_queue = deque()
        total_bytes = config.SFTM_INPUT_BUFFER_KB*1024
        self.num_banks = config.SFTM_NUM_BANKS
        self.bank_capacity = total_bytes // self.num_banks
        self.bank_used = [0]*self.num_banks
        self.output_used = 0
        self.output_capacity = config.SFTM_OUTPUT_BUFFER_KB*1024
        self.weight_store = {}
        self.sparse_maps = {}        # raw 'coords'
        self.scu_counts_cache = {}   # key: layer_name -> 1D array length rows*cols with counts per SCU (int)
    def load_weights_bytes(self,layer_name,bytes_w):
        self.weight_store[layer_name] = bytes_w
    def enqueue_job(self,job:TileJob):
        self.job_queue.append(job)
    def try_alloc_bank(self,bytes_needed):
        for i in range(self.num_banks):
            if self.bank_used[i]+bytes_needed <= self.bank_capacity:
                self.bank_used[i] += bytes_needed
                return i
        return None
    def free_bank(self,idx,bytes_free):
        self.bank_used[idx] = max(0,self.bank_used[idx]-bytes_free)
    def precompute_scu_counts_for_layer(self, layer_spec, coords):
        """
        coords: (N,4) array (o,i,mu0,mu1)
        produce counts_per_scu: length rows*cols vector: number of coords mapped to each SCU.
        mapping uses out_per_row = ceil(out_ch / rows), in_per_col = ceil(in_ch / cols)
        """
        if coords is None or coords.size==0:
            return np.zeros(self.rows*self.cols, dtype=np.int64)
        out_ch = layer_spec['C_out']
        in_ch  = layer_spec['C_in']
        out_per_row = max(1, math.ceil(out_ch / self.rows))
        in_per_col  = max(1, math.ceil(in_ch  / self.cols))
        # vectorized mapping
        o_idx = coords[:,0].astype(np.int64)
        i_idx = coords[:,1].astype(np.int64)
        r_idx = np.minimum(self.rows-1, o_idx // out_per_row)
        c_idx = np.minimum(self.cols-1, i_idx // in_per_col)
        linear = (r_idx * self.cols) + c_idx
        # bincount into rows*cols bins
        counts = np.bincount(linear, minlength=self.rows*self.cols).astype(np.int64)
        return counts

    def process_tile(self, job:TileJob, layer_spec):
        """
        Process the head-of-queue job if it matches `job` and bank fits. Returns cycles consumed or 0 if cannot start.
        layer_spec: dict for the layer (used to look up cached scu_counts)
        """
        if not self.job_queue:
            return 0
        queued = self.job_queue[0]
        if queued.layer != job.layer or queued.tile_idx != job.tile_idx:
            # ensure we process queue head
            job = queued
        bytes_in = job.rows * job.cols * job.in_ch * self.config.ACTIVATION_BYTES
        bank_idx = self.try_alloc_bank(bytes_in)
        if bank_idx is None:
            return 0
        # pop job
        self.job_queue.popleft()
        self.stats['onchip_reads'] += bytes_in
        pre = self.config.PRETU_LATENCY
        post = self.config.POSTTU_LATENCY
        # compute patches
        out_patch_rows = max(1, math.ceil(job.rows / 2))
        out_patch_cols = max(1, math.ceil(job.cols / 2))
        patches = out_patch_rows * out_patch_cols
        # check for precomputed scu_counts cache
        if job.layer in self.scu_counts_cache:
            counts = self.scu_counts_cache[job.layer]  # 1D array length rows*cols
            # assigned_mults per SCU = counts * patches
            assigned_mults = counts * patches
            # cycles per SCU = ceil(assigned_mults / multipliers)
            # compute max across SCUs vectorized
            # avoid zeros dividing
            multipliers = Config.SCU_MULTIPLIERS
            cycles_per_scu = (assigned_mults + multipliers - 1) // multipliers
            scu_cycles = int(cycles_per_scu.max()) if cycles_per_scu.size>0 else 0
            total_mults = int(assigned_mults.sum())
            self.stats['mac_counts'][job.layer] = self.stats['mac_counts'].get(job.layer,0) + total_mults
        else:
            # fallback to analytic
            if job.type == 'RFConv':
                mu2 = Config.MU_C * Config.MU_C; rho = Config.RHO_C
            elif job.type == 'RFDeConv':
                mu2 = Config.MU_D * Config.MU_D; rho = Config.RHO_D
            else:
                mu2 = 1; rho = 1
            num_patches = patches
            total_mults = int(num_patches * job.out_ch * mu2 * rho)
            self.stats['mac_counts'][job.layer] = self.stats['mac_counts'].get(job.layer,0) + total_mults
            # analytic assign:
            out_ch = job.out_ch
            out_per_row = max(1, math.ceil(out_ch / self.rows))
            base_mults_per_out = max(1, total_mults // max(1,out_ch))
            # compute assigned mults per SCU (vectorized)
            counts = np.zeros(self.rows*self.cols, dtype=np.int64)
            for r in range(self.rows):
                oc_start = r*out_per_row
                oc_end = min(out_ch,(r+1)*out_per_row)
                oc_count = max(0, oc_end - oc_start)
                counts[r*self.cols:(r+1)*self.cols] = oc_count * base_mults_per_out
            assigned_mults = counts  # already includes base
            multipliers = Config.SCU_MULTIPLIERS
            cycles_per_scu = (assigned_mults + multipliers - 1) // multipliers
            scu_cycles = int(cycles_per_scu.max()) if cycles_per_scu.size>0 else 0
        total_cycles = pre + scu_cycles + self.config.SCU_PIPELINE_LATENCY + post
        self.stats['module_cycles']['SFTM'] = self.stats['module_cycles'].get('SFTM',0) + total_cycles
        self.stats['cycles'] += total_cycles
        # output write (on-chip else off-chip)
        bytes_out = job.rows * job.cols * job.out_ch * self.config.ACTIVATION_BYTES
        if self.output_used + bytes_out <= self.output_capacity:
            self.output_used += bytes_out
            self.stats['onchip_writes'] += bytes_out
        else:
            mem_cycles = self.ext.write(bytes_out)
            self.stats['module_cycles']['SFTM_mem'] = self.stats['module_cycles'].get('SFTM_mem',0) + mem_cycles
            self.stats['cycles'] += mem_cycles
            self.stats['bytes_written_offchip'] = self.stats.get('bytes_written_offchip',0) + bytes_out
        self.free_bank(bank_idx, bytes_in)
        return total_cycles

# -------------------------
# DfConv (same analytic)
# -------------------------
class DfConvModule:
    def __init__(self, ext, stats, config=Config):
        self.queue = deque()
        self.ext = ext
        self.stats = stats
        self.config = config
    def enqueue(self, job):
        self.queue.append(job)
    def process_one(self):
        if not self.queue:
            return 0
        job = self.queue.popleft()
        out_pixels = job.rows * job.cols
        interp = out_pixels * self.config.DFCONV_INTERP_COST_PER_SAMPLE
        macs = out_pixels * job.out_ch * 9 * job.in_ch // 4
        mac_cycles = math.ceil(macs / self.config.DFCONV_PE_COUNT)
        total = interp + mac_cycles
        self.stats['module_cycles']['DfConv'] = self.stats['module_cycles'].get('DfConv',0) + total
        self.stats['cycles'] += total
        self.stats['mac_counts'][job.layer] = self.stats['mac_counts'].get(job.layer,0) + macs
        return total

# -------------------------
# Controller (loads masks + precomputes scu_counts)
# -------------------------
class Controller:
    def __init__(self, config=Config):
        self.config = config
        self.ext = ExternalMemory(ext_bw_gbps=config.EXTERNAL_BW_GBPS, clk=config.CLOCK_FREQ)
        self.stats = {
            'cycles': 0,
            'module_cycles': {},
            'mac_counts': {},
            'onchip_reads': 0,
            'onchip_writes': 0,
            'bytes_written_offchip': 0,
            'scu_assigned': {},
        }
        self.cores = []
        for i in range(config.NUM_CORES):
            sftm = SFTM(i, self.ext, self.stats, config=config)
            dpm = DfConvModule(self.ext, self.stats, config=config)
            self.cores.append({'sftm':sftm,'dpm':dpm})
        self.layers = []
    def load_model(self, layers):
        self.layers = layers
        for lay in layers:
            if lay['type']=='RFConv':
                mu2 = Config.MU_C * Config.MU_C
                approx_nonzeros = int(mu2 * lay['C_in'] * lay['C_out'] * Config.RHO_C)
            elif lay['type']=='RFDeConv':
                mu2 = Config.MU_D * Config.MU_D
                approx_nonzeros = int(mu2 * lay['C_in'] * lay['C_out'] * Config.RHO_D)
            else:
                approx_nonzeros = lay['k'] * lay['k'] * lay['C_in'] * lay['C_out']
            weight_bytes = approx_nonzeros * Config.WEIGHT_BYTES
            for core in self.cores:
                core['sftm'].load_weights_bytes(lay['name'], weight_bytes)
    def load_masks(self, mask_dir):
        # Load each mask and precompute a per-layer SCU counts vector for fast per-tile assignment
        layer_map = {l['name']: l for l in self.layers}
        for lay in self.layers:
            name = lay['name']
            spec = load_sparse_npz_for_layer(mask_dir, name)
            if spec is None:
                continue
            # vectorized precompute: get counts per SCU for core 0 (same for all cores), then copy to all cores
            coords = spec['coords']  # shape (N,4)
            # compute counts for SCU layout using core 0 method (rows x cols)
            core0 = self.cores[0]['sftm']
            counts = core0.precompute_scu_counts_for_layer(lay, coords)
            # store into spec for reuse
            spec['scu_counts'] = counts  # 1D numpy array length rows*cols
            # attach spec & scu_counts into each core sftm.sparse_maps and cache
            for core in self.cores:
                core['sftm'].sparse_maps[name] = {"coords": coords, "values": spec['values'], "mask_fraction": spec['mask_fraction']}
                core['sftm'].scu_counts_cache[name] = counts.copy()  # copy so each core has its own cache array
                core['sftm'].weight_store[name] = int(coords.shape[0] * Config.WEIGHT_BYTES)
        print("Loaded sparse masks and precomputed SCU counts into SFTM(s).")
    def start_frame(self, frame_id, frame_H, frame_W):
        channels = self.layers[0]['C_out'] if self.layers else 36
        rows = min(self.config.DEFAULT_TILE_INPUT_ROWS, frame_H)
        bank_cap = self.cores[0]['sftm'].bank_capacity
        while True:
            max_cols = max(1, bank_cap // (rows * channels * self.config.ACTIVATION_BYTES))
            if max_cols >= 1:
                break
            rows = max(1, rows // 2)
        num_row_tiles = math.ceil(frame_H/rows)
        for rt in range(num_row_tiles):
            row_h = rows if (rt < num_row_tiles-1) else (frame_H - (num_row_tiles-1)*rows)
            max_cols = max(1, bank_cap // (row_h * channels * self.config.ACTIVATION_BYTES))
            num_col_tiles = math.ceil(frame_W / max_cols)
            for ct in range(num_col_tiles):
                col_w = max_cols if (ct < num_col_tiles-1) else (frame_W - (num_col_tiles-1)*max_cols)
                core_idx = (rt*num_col_tiles + ct) % len(self.cores)
                core = self.cores[core_idx]
                names = {l['name']:l for l in self.layers}
                if 'RFConv0' in names and 'RFConv1' in names and 'RFDeConv0' in names:
                    r0 = names['RFConv0']; r1 = names['RFConv1']; rd = names['RFDeConv0']
                    j0 = TileJob(layer=r0['name'], tile_idx=(rt,ct,0), rows=row_h, cols=col_w, in_ch=r0['C_in'], out_ch=r0['C_out'], type='RFConv')
                    j1 = TileJob(layer=r1['name'], tile_idx=(rt,ct,1), rows=row_h, cols=col_w, in_ch=r1['C_in'], out_ch=r1['C_out'], type='RFConv')
                    j2 = TileJob(layer=rd['name'], tile_idx=(rt,ct,2), rows=self.config.DEFAULT_TILE_OUTPUT_ROWS, cols=col_w, in_ch=rd['C_in'], out_ch=rd['C_out'], type='RFDeConv')
                    core['sftm'].enqueue_job(j0); core['sftm'].enqueue_job(j1); core['sftm'].enqueue_job(j2)
                else:
                    for lay in self.layers:
                        j = TileJob(layer=lay['name'], tile_idx=(rt,ct), rows=row_h, cols=col_w, in_ch=lay['C_in'], out_ch=lay['C_out'], type=lay['type'])
                        if lay['type'] in ('RFConv','RFDeConv','Conv','DeConv'):
                            core['sftm'].enqueue_job(j)
                        elif lay['type'] == 'DfConv':
                            core['dpm'].enqueue(j)
    def run(self, cycle_limit=int(1e9)):
        start_time = time.time()
        while True:
            work_done = False
            for core in self.cores:
                sftm = core['sftm']
                if sftm.job_queue:
                    # pass layer spec along for quick lookup (find layer from name)
                    head = sftm.job_queue[0]
                    layer_spec = next((l for l in self.layers if l['name']==head.layer), None)
                    processed = sftm.process_tile(head, layer_spec)
                    if processed > 0:
                        work_done = True
                dpm = core['dpm']
                if dpm.queue:
                    job = dpm.queue.popleft()
                    out_pixels = job.rows * job.cols
                    interp = out_pixels * self.config.DFCONV_INTERP_COST_PER_SAMPLE
                    macs = out_pixels * job.out_ch * 9 * job.in_ch // 4
                    mac_cycles = math.ceil(macs / self.config.DFCONV_PE_COUNT)
                    total = interp + mac_cycles
                    self.stats['module_cycles']['DfConv'] = self.stats['module_cycles'].get('DfConv',0) + total
                    self.stats['cycles'] += total
                    self.stats['mac_counts'][job.layer] = self.stats['mac_counts'].get(job.layer,0) + macs
                    work_done = True
            if not work_done:
                break
            if self.stats['cycles'] > cycle_limit:
                print("Cycle limit reached, abort.")
                break
        elapsed = time.time() - start_time
        final_stats = {
            'cycles': self.stats['cycles'],
            'module_cycles': self.stats['module_cycles'],
            'mac_counts': self.stats['mac_counts'],
            'bytes_written_offchip': self.ext.bytes_written,
            'bytes_read_offchip': self.ext.bytes_read,
            'scu_assigned': self.stats['scu_assigned'],
        }
        return final_stats, elapsed

# -------------------------
# Build layers helper
# -------------------------
def build_repvcn_layers(H,W,N=36):
    layers = []
    layers.append({'name':'FE_Conv1','type':'Conv','H':H//2,'W':W//2,'C_in':3,'C_out':N,'k':3})
    layers.append({'name':'FE_Conv2','type':'Conv','H':H//4,'W':W//4,'C_in':N,'C_out':N,'k':3})
    layers.append({'name':'RFConv0','type':'RFConv','H':H//4,'W':W//4,'C_in':N,'C_out':N,'k':3})
    layers.append({'name':'RFConv1','type':'RFConv','H':H//4,'W':W//4,'C_in':N,'C_out':N,'k':3})
    layers.append({'name':'RFDeConv0','type':'RFDeConv','H':max(1,H//8),'W':max(1,W//8),'C_in':N,'C_out':N,'k':4})
    layers.append({'name':'DfConv_comp','type':'DfConv','H':H//4,'W':W//4,'C_in':N,'C_out':N,'k':3})
    layers.append({'name':'RFConv2','type':'RFConv','H':H//4,'W':W//4,'C_in':N,'C_out':N,'k':3})
    layers.append({'name':'RFConv3','type':'RFConv','H':H//4,'W':W//4,'C_in':N,'C_out':N,'k':3})
    layers.append({'name':'RFDeConv1','type':'RFDeConv','H':max(1,H//8),'W':max(1,W//8),'C_in':N,'C_out':N,'k':4})
    layers.append({'name':'Recon_Conv','type':'Conv','H':H,'W':W,'C_in':N,'C_out':3,'k':3})
    return layers

# -------------------------
# CLI
# -------------------------
def main():
    p = argparse.ArgumentParser()
    p.add_argument("--gen-masks", action="store_true")
    p.add_argument("--outdir", default="transform_masks")
    p.add_argument("--run-sim", action="store_true")
    p.add_argument("--mask-dir", default="transform_masks")
    p.add_argument("--frame-H", type=int, default=720)
    p.add_argument("--frame-W", type=int, default=1280)
    p.add_argument("--seed", type=int, default=Config.RNG_SEED)
    args = p.parse_args()

    if args.gen_masks:
        print(f"--- Generating mock transform masks in {args.outdir} ---")
        generate_mock_transform_masks(outdir=args.outdir, seed=args.seed)

    if args.run_sim:
        print(f"--- Starting simulator run ({args.frame_W}x{args.frame_H}) ---")
        ctrl = Controller()
        layers = build_repvcn_layers(args.frame_H, args.frame_W, N=36)
        ctrl.load_model(layers)
        if os.path.isdir(args.mask_dir):
            ctrl.load_masks(args.mask_dir)
        else:
            print("Mask dir not found; using analytic fallback.")
        ctrl.start_frame(frame_id=0, frame_H=args.frame_H, frame_W=args.frame_W)
        stats, elapsed = ctrl.run()
        cycles = stats['cycles']
        total_macs = sum(stats['mac_counts'].values())
        gops = (total_macs / cycles) * Config.CLOCK_FREQ / 1e9 if cycles>0 else 0.0
        fps = Config.CLOCK_FREQ / cycles if cycles>0 else 0.0
        print("Simulation finished.")
        print(f"Real elapsed time: {elapsed:.3f}s")
        print(f"Simulated cycles: {cycles}")
        print(f"Total MACs: {total_macs:,}")
        print(f"Estimated throughput: {gops:.3f} GOPS")
        print(f"Estimated FPS: {fps:.3f}")
        print("Module cycles:")
        for k,v in stats['module_cycles'].items():
            print(f"  {k}: {v}")
        print(f"Off-chip bytes written: {stats['bytes_written_offchip']}")
        # sample SCU assigned counts (from earliest core) - show up to 12
        sample = []
        for core in ctrl.cores:
            for (key, val) in core['sftm'].scu_counts_cache.items():
                # nothing; show controller stats aggregated
                pass
        print("Done.")

if __name__ == "__main__":
    main()
