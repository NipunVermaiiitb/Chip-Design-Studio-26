from __future__ import annotations
import math
import random
import itertools
from collections import deque, namedtuple
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple
from pathlib import Path
import argparse
import json
import csv
import time
import os

import numpy as np

# -------------------------
# Config for SCU/SFTM/DPM
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
    ACTIVATION_BYTES = 2
    WEIGHT_BYTES = 2
    PRETU_LATENCY = 4
    POSTTU_LATENCY = 4
    SCU_PIPELINE_LATENCY = 2
    DFCONV_INTERP_COST_PER_SAMPLE = 2
    DFCONV_PE_COUNT = 64

FRAME_COLS = 1920
FRAME_ROWS = 1080
CHANNELS = 36
ACT_WIDTH = 16
BYTES_PER_SAMPLE = ACT_WIDTH // 8
BYTES_PER_PIXEL = CHANNELS * BYTES_PER_SAMPLE
ROWS_PER_GROUP = 4

DEFAULT_BASE_PERIOD = 140
DEFAULT_DRAM_LATENCY = 800
DEFAULT_DRAM_BW_BYTES_PER_CYCLE = 1024.0
DEFAULT_MAX_OUTSTANDING = 8
DEFAULT_PTABLE_ENTRIES = 64
DEFAULT_COALESCE_BYTES = 16 * 1024
DEFAULT_BANKS = 4
DEFAULT_GROUP_SLOTS = 2
RNG_SEED = 42

OUT_DIR = Path("sim_instrument_outputs")
OUT_DIR.mkdir(exist_ok=True, parents=True)

# -----------------------------
# SCU and TileJob
# -----------------------------
TileJob = namedtuple('TileJob', ['layer', 'tile_idx', 'rows', 'cols', 'in_ch', 'out_ch', 'type'])

class SCU:
    def __init__(self, core_id, r, c, multipliers=Config.SCU_MULTIPLIERS):
        self.core = core_id
        self.r = r
        self.c = c
        self.multipliers = multipliers
        self.assigned_mults = 0
    def assign(self, n):
        self.assigned_mults += n
    def reset(self):
        self.assigned_mults = 0
    def cycles_needed(self):
        return math.ceil(self.assigned_mults / self.multipliers) if self.assigned_mults > 0 else 0

# -----------------------------
# Data classes
# -----------------------------
@dataclass
class TileGroup:
    gid: int
    row_group_idx: int
    col_tile_idx: int
    col_start: int
    col_end: int
    motion_ready: bool = False
    reference_ready: bool = False
    sftm_done: bool = False  # SFTM computation complete
    sftm_cycles: int = 0  # Cycles spent in SFTM computation
    bypass_mode: bool = False  # Use DRAM path instead of FIFO

@dataclass
class PTEntry:
    valid: bool = False
    base_addr: int = 0
    length: int = 0
    status: str = "pending"  # pending / inflight / done
    tag: Optional[int] = None
    linked_tiles: List[int] = field(default_factory=list)
    dest_banks: List[Tuple[int, int]] = field(default_factory=list)
    request_type: str = "motion"

@dataclass
class DMARequest:
    tag: int
    base_addr: int
    length: int
    issue_cycle: int
    done_cycle: Optional[int] = None
    dest: Optional[Tuple[int, int, int]] = None
    request_type: str = "motion"

# -----------------------------
# Helpers
# -----------------------------
def linear_addr_for_pixel(x: int, y: int) -> int:
    return (y * FRAME_COLS + x) * BYTES_PER_PIXEL

def region_bytes_for_dims(width_pixels: int, height_rows: int) -> int:
    return width_pixels * height_rows * BYTES_PER_PIXEL

def bytes_per_tile(tile_cols: int) -> int:
    return ROWS_PER_GROUP * tile_cols * CHANNELS * BYTES_PER_SAMPLE


# -----------------------------
# BankedGroupFIFO
# -----------------------------
class BankedGroupFIFO:
    def __init__(self, banks: int, group_slots_per_bank: int):
        self.banks = banks
        self.group_slots_per_bank = group_slots_per_bank
        self.max_groups = banks * group_slots_per_bank
        self.queue = deque()  # holds TileGroup objects
        # bank_slots[bank][slot]
        self.bank_slots: List[List[Optional[int]]] = [[None]*group_slots_per_bank for _ in range(banks)]
        self.valid_bits: List[List[bool]] = [[False]*group_slots_per_bank for _ in range(banks)]
        self.tile_to_slot: Dict[int, Tuple[int, int]] = {}
        self.push_attempts = 0
        self.push_success = 0
        self.pop_attempts = 0
        self.pop_success = 0
        self.overflow_count = 0
        # timeseries for instrumentation
        self.occ_timeseries = []

    @property
    def depth(self) -> int:
        return self.max_groups

    @property
    def max_slots(self) -> int:
        return self.max_groups

    def can_push(self) -> bool:
        return len(self.queue) < self.max_groups

    def push(self, tile: TileGroup) -> bool:
        self.push_attempts += 1
        if not self.can_push():
            self.overflow_count += 1
            return False
        slot_idx = len(self.queue)
        bank = slot_idx % self.banks
        local_slot = slot_idx // self.banks
        # defensive guard
        if bank < 0 or bank >= self.banks or local_slot < 0 or local_slot >= self.group_slots_per_bank:
            # should not happen, but handle gracefully
            self.overflow_count += 1
            return False
        self.bank_slots[bank][local_slot] = tile.gid
        self.valid_bits[bank][local_slot] = True
        self.tile_to_slot[tile.gid] = (bank, local_slot)
        self.queue.append(tile)
        self.push_success += 1
        return True

    def peek(self) -> Optional[TileGroup]:
        if not self.queue:
            return None
        return self.queue[0]

    def pop(self) -> Optional[TileGroup]:
        self.pop_attempts += 1
        if not self.queue:
            return None
        t = self.queue.popleft()
        mapped = self.tile_to_slot.pop(t.gid, None)
        if mapped:
            bank, slot = mapped
            # defensive guard
            if 0 <= bank < self.banks and 0 <= slot < self.group_slots_per_bank:
                self.bank_slots[bank][slot] = None
                self.valid_bits[bank][slot] = False
        self.pop_success += 1
        return t

    def occupancy(self) -> int:
        return len(self.queue)

    def find_tile(self, gid: int) -> Optional[TileGroup]:
        for tile in self.queue:
            if tile.gid == gid:
                return tile
        return None

    def record_ts(self, cycle: int):
        self.occ_timeseries.append((cycle, self.occupancy()))

# -----------------------------
# DMA Engine
# -----------------------------
class DMAEngine:
    def __init__(self, dram_latency: int, bw_bytes_per_cycle: float):
        self.dram_latency = int(dram_latency)
        self.bw = float(bw_bytes_per_cycle)
        self.inflight: Dict[int, DMARequest] = {}
        self.completed: List[DMARequest] = []
        self.next_tag = 1
        self.cycle = 0

    def issue(self, base_addr: int, length: int, dest: Tuple[int, int, int],
              request_type: str = "motion", first_beat_bytes: Optional[int] = None) -> int:
        tag = self.next_tag
        self.next_tag += 1
        # transfer cycles = ceil(length/bw), at least 1
        transfer_cycles = max(1, math.ceil(length / max(1.0, self.bw)))
        done_cycle = self.cycle + self.dram_latency + transfer_cycles
        req = DMARequest(tag=tag, base_addr=base_addr, length=length,
                         issue_cycle=self.cycle, done_cycle=done_cycle,
                         dest=dest, request_type=request_type)
        self.inflight[tag] = req
        return tag

    def step(self):
        self.cycle += 1
        done = [tag for tag, r in self.inflight.items() if r.done_cycle is not None and r.done_cycle <= self.cycle]
        for tag in done:
            req = self.inflight.pop(tag)
            self.completed.append(req)

    def collect_completed(self) -> List[DMARequest]:
        out = list(self.completed)
        self.completed = []
        return out

    def outstanding_count(self) -> int:
        return len(self.inflight)

# -----------------------------
# SplitPrefetcher
# -----------------------------
class SplitPrefetcher:
    def __init__(self, dma: DMAEngine, max_outstanding=DEFAULT_MAX_OUTSTANDING,
                 ptable_entries=DEFAULT_PTABLE_ENTRIES, coalesce_bytes=DEFAULT_COALESCE_BYTES,
                 dram_alignment=4096):
        self.dma = dma
        self.max_outstanding = int(max_outstanding)
        self.ptable_entries = int(ptable_entries)
        self.coalesce_bytes = int(coalesce_bytes)
        self.dram_alignment = int(dram_alignment)
        self.ptable: List[PTEntry] = []
        self.prefetch_queue: deque[PTEntry] = deque()
        self.tag_to_entry: Dict[int, PTEntry] = {}
        self.requests_total = 0
        self.requests_coalesced = 0
        self.requests_hits = 0

    def _align(self, base, length):
        a = self.dram_alignment
        base_aligned = (base // a) * a
        end = base + length
        end_aligned = ((end + a - 1) // a) * a
        return base_aligned, end_aligned - base_aligned

    def lookup_done(self, base, length, request_type):
        for e in self.ptable:
            if not e.valid:
                continue
            if (e.request_type == request_type and e.status == "done"
                    and e.base_addr <= base and (e.base_addr + e.length) >= (base + length)):
                return e
        return None

    def pending_overlap(self, base, length, request_type):
        for e in self.ptable:
            if not e.valid:
                continue
            if (e.request_type == request_type and (e.base_addr < base + length) and (base < e.base_addr + e.length)):
                if e.status in ("pending", "inflight"):
                    return e
        return None

    def allocate_ptable(self, base, length, request_type):
        # Try to find an invalid slot
        for e in self.ptable:
            if not e.valid:
                e.valid = True
                e.base_addr = base
                e.length = length
                e.status = "pending"
                e.tag = None
                e.linked_tiles = []
                e.dest_banks = []
                e.request_type = request_type
                return e
        # If capacity not reached, append new
        if len(self.ptable) < self.ptable_entries:
            e = PTEntry(valid=True, base_addr=base, length=length, request_type=request_type)
            self.ptable.append(e)
            return e
        # Evict the oldest non-inflight entry (FIFO-like)
        for i, e in enumerate(self.ptable):
            if e.status != "inflight":
                self.ptable.pop(i)
                new = PTEntry(valid=True, base_addr=base, length=length, request_type=request_type)
                self.ptable.append(new)
                return new
        # If all are inflight (rare), forcibly evict the first (worst-case)
        e = self.ptable.pop(0)
        new = PTEntry(valid=True, base_addr=base, length=length, request_type=request_type)
        self.ptable.append(new)
        return new

    def coalesce_enqueue(self, base, length, dest_banks, request_type="motion"):
        self.requests_total += 1
        base_a, len_a = self._align(base, length)
        # Already done?
        done = self.lookup_done(base_a, len_a, request_type)
        if done:
            self.requests_hits += 1
            return done
        # pending overlap?
        pend = self.pending_overlap(base_a, len_a, request_type)
        if pend:
            # attach tile to existing pending entry
            pend.dest_banks.extend(dest_banks)
            return pend
        # try coalesce with tail
        if self.prefetch_queue:
            tail = self.prefetch_queue[-1]
            if tail.request_type == request_type:
                tail_end = tail.base_addr + tail.length
                merged_base = min(tail.base_addr, base_a)
                merged_end = max(tail_end, base_a + len_a)
                merged_len = merged_end - merged_base
                if merged_len <= self.coalesce_bytes:
                    tail.base_addr = merged_base
                    tail.length = merged_len
                    tail.dest_banks.extend(dest_banks)
                    self.requests_coalesced += 1
                    return tail
        # create new entry
        e = self.allocate_ptable(base_a, len_a, request_type)
        e.dest_banks = list(dest_banks)
        e.linked_tiles = []
        e.status = "pending"
        self.prefetch_queue.append(e)
        return e

    def issue_prefetches(self):
        issued = []
        # while we can issue more and there are entries queued
        while self.prefetch_queue and self.dma.outstanding_count() < self.max_outstanding:
            e = self.prefetch_queue.popleft()
            # defensive: ensure dest exists
            dest = e.dest_banks[0] if e.dest_banks else (0, 0)
            # issue
            tag = self.dma.issue(e.base_addr, e.length, (dest[0], dest[1], 0), e.request_type)
            e.status = "inflight"
            e.tag = tag
            self.tag_to_entry[tag] = e
            issued.append((tag, e))
        return issued

    def on_dma_completed(self, req: DMARequest):
        e = self.tag_to_entry.pop(req.tag, None)
        if e:
            e.status = "done"

    def step(self):
        return self.issue_prefetches()

# -----------------------------
# Producer (SFTM) with actual computation
# -----------------------------
class ProducerSFTM:
    def __init__(self, tile_columns: int, groups_total: int = None,
                 base_period: int = DEFAULT_BASE_PERIOD, jitter: int = 2, core_id: int = 0):
        random.seed(RNG_SEED)
        self.core_id = core_id
        self.tile_columns = tile_columns
        self.num_col_tiles = math.ceil(FRAME_COLS / tile_columns)
        self.base_period = base_period
        self.period_per_tile = max(1, int(round(self.base_period / max(1, self.num_col_tiles))))
        row_groups = FRAME_ROWS // ROWS_PER_GROUP
        default_total = row_groups * self.num_col_tiles
        self.groups_total = groups_total if groups_total is not None else default_total
        self.jitter = int(jitter)
        self.cycle = 0
        self.issued = 0
        self.next_issue = 1
        self.gid = 1
        # SCU grid for computation
        self.rows = Config.POF
        self.cols = Config.PIF
        self.scu_grid = [[SCU(core_id, r, c) for c in range(self.cols)] for r in range(self.rows)]
        self.scu_counts_cache = {}  # layer_name -> counts array
        self.sparse_maps = {}  # layer_name -> coords
        self.active_tile = None  # Tile being processed
        self.sftm_busy_until = 0  # Cycle when current tile finishes

    def step(self) -> Optional[Tuple[TileGroup, int, int]]:
        """Returns (tile, sftm_cycles, macs) or None"""
        self.cycle += 1
        
        # Check if currently processing a tile
        if self.active_tile and self.cycle < self.sftm_busy_until:
            return None  # Still busy
        
        # Finish active tile
        if self.active_tile:
            finished = self.active_tile
            finished.sftm_done = True
            finished.motion_ready = True
            self.active_tile = None
            return (finished, finished.sftm_cycles, 0)  # Return completed tile
        
        # Issue new tile
        if self.issued >= self.groups_total:
            return None
        if self.cycle >= self.next_issue:
            tile_index = self.issued
            row_groups_per_frame = FRAME_ROWS // ROWS_PER_GROUP
            row_group_idx = (tile_index // self.num_col_tiles) % row_groups_per_frame
            col_tile_idx = tile_index % self.num_col_tiles
            col_start = col_tile_idx * self.tile_columns
            col_end = min(FRAME_COLS - 1, col_start + self.tile_columns - 1)
            t = TileGroup(gid=self.gid, row_group_idx=row_group_idx,
                          col_tile_idx=col_tile_idx, col_start=col_start, col_end=col_end)
            # Compute actual SFTM cycles
            sftm_cycles, macs = self.compute_sftm_cycles(t)
            t.sftm_cycles = sftm_cycles
            self.active_tile = t
            self.sftm_busy_until = self.cycle + sftm_cycles
            self.gid += 1
            self.issued += 1
            jitter_v = random.randint(-self.jitter, self.jitter) if self.jitter > 0 else 0
            self.next_issue = self.cycle + max(1, self.period_per_tile + jitter_v)
            return None  # Will return on completion
        return None
    
    def load_sparse_masks(self, mask_dir: str, layer_names: List[str]):
        """Load sparse transform masks and precompute SCU counts"""
        if not mask_dir or not os.path.isdir(mask_dir):
            return
        for layer_name in layer_names:
            fname = os.path.join(mask_dir, f"{layer_name}.npz")
            if not os.path.exists(fname):
                continue
            try:
                d = np.load(fname)
                idx0 = d['idx0'].astype(int)
                idx1 = d['idx1'].astype(int)
                idx2 = d['idx2'].astype(int)
                idx3 = d['idx3'].astype(int)
                coords = np.stack([idx0, idx1, idx2, idx3], axis=1)
                self.sparse_maps[layer_name] = coords
                # Precompute SCU counts (assume 36 in/out channels)
                out_ch = in_ch = CHANNELS
                out_per_row = max(1, math.ceil(out_ch / self.rows))
                in_per_col = max(1, math.ceil(in_ch / self.cols))
                o_idx = coords[:, 0].astype(np.int64)
                i_idx = coords[:, 1].astype(np.int64)
                r_idx = np.minimum(self.rows - 1, o_idx // out_per_row)
                c_idx = np.minimum(self.cols - 1, i_idx // in_per_col)
                linear = (r_idx * self.cols) + c_idx
                counts = np.bincount(linear, minlength=self.rows * self.cols).astype(np.int64)
                self.scu_counts_cache[layer_name] = counts
            except Exception as e:
                print(f"Warning: failed to load {fname}: {e}")
    
    def compute_sftm_cycles(self, t: TileGroup, layer_name: str = "RFConv0") -> Tuple[int, int]:
        """Compute SFTM processing cycles for a tile"""
        rows = ROWS_PER_GROUP
        cols = t.col_end - t.col_start + 1
        out_patch_rows = max(1, math.ceil(rows / 2))
        out_patch_cols = max(1, math.ceil(cols / 2))
        patches = out_patch_rows * out_patch_cols
        
        # Use cached SCU counts if available
        if layer_name in self.scu_counts_cache:
            counts = self.scu_counts_cache[layer_name]
            assigned_mults = counts * patches
            multipliers = Config.SCU_MULTIPLIERS
            cycles_per_scu = (assigned_mults + multipliers - 1) // multipliers
            scu_cycles = int(cycles_per_scu.max()) if cycles_per_scu.size > 0 else 0
            total_macs = int(assigned_mults.sum())
        else:
            # Fallback: analytic model
            mu2 = Config.MU_C * Config.MU_C
            rho = Config.RHO_C
            total_macs = int(patches * CHANNELS * mu2 * rho)
            mults_per_scu = total_macs // (self.rows * self.cols)
            scu_cycles = math.ceil(mults_per_scu / Config.SCU_MULTIPLIERS)
        
        total_cycles = Config.PRETU_LATENCY + scu_cycles + Config.SCU_PIPELINE_LATENCY + Config.POSTTU_LATENCY
        return total_cycles, total_macs

# -----------------------------
# Consumer (DPM) with actual deformable convolution
# -----------------------------
class ConsumerDPM:
    def __init__(self, tile_columns: int, base_period: int = DEFAULT_BASE_PERIOD, jitter: int = 4):
        self.tile_columns = tile_columns
        self.num_col_tiles = math.ceil(FRAME_COLS / tile_columns)
        self.base_period = base_period
        self.period_per_tile = max(1, int(round(self.base_period / max(1, self.num_col_tiles))))
        self.jitter = int(jitter)
        self.cycle = 0
        self.next_consume = 1
        self.stall_cycles = 0
        self.consumed = 0
        self.active_tile = None
        self.dpm_busy_until = 0

    def compute_dpm_cycles(self, t: TileGroup) -> Tuple[int, int]:
        """Compute DPM (deformable convolution) processing cycles"""
        rows = ROWS_PER_GROUP
        cols = t.col_end - t.col_start + 1
        out_pixels = rows * cols
        # DfConv: interpolation + MAC operations
        interp_cycles = out_pixels * Config.DFCONV_INTERP_COST_PER_SAMPLE
        macs = out_pixels * CHANNELS * 9 * CHANNELS // 4  # 3x3 kernel, 1/4 subsampling
        mac_cycles = math.ceil(macs / Config.DFCONV_PE_COUNT)
        total_cycles = interp_cycles + mac_cycles
        return total_cycles, macs

    def step(self):
        self.cycle += 1

    def ready_to_consume(self):
        # Ready if not busy and past the next consume cycle
        return self.cycle >= self.next_consume and self.cycle >= self.dpm_busy_until

    def start_consume(self, t: TileGroup) -> Tuple[int, int]:
        """Start consuming a tile, returns (dpm_cycles, macs)"""
        dpm_cycles, macs = self.compute_dpm_cycles(t)
        self.active_tile = t
        self.dpm_busy_until = self.cycle + dpm_cycles
        jitter_v = random.randint(-self.jitter, self.jitter) if self.jitter > 0 else 0
        self.next_consume = self.cycle + max(1, self.period_per_tile + jitter_v)
        self.consumed += 1
        return dpm_cycles, macs

# -----------------------------
# Simulator (unchanged behavior, returns res dict)
# -----------------------------
class Simulator:
    def __init__(self, tile_columns: int = 120,
                 banks: int = DEFAULT_BANKS,
                 group_slots: int = DEFAULT_GROUP_SLOTS,
                 dram_latency: int = DEFAULT_DRAM_LATENCY,
                 dram_bw: float = DEFAULT_DRAM_BW_BYTES_PER_CYCLE,
                 max_outstanding: int = DEFAULT_MAX_OUTSTANDING,
                 groups_total: Optional[int] = None,
                 halo_pixels: int = 4,
                 ptable_entries: int = DEFAULT_PTABLE_ENTRIES,
                 coalesce_bytes: int = DEFAULT_COALESCE_BYTES,
                 base_period: int = DEFAULT_BASE_PERIOD,
                 seed: int = RNG_SEED,
                 first_beat_bytes: Optional[int] = None,
                 num_parallel_units: int = 4,
                 bypass_mode: bool = False,
                 mask_dir: Optional[str] = None):
        random.seed(seed)
        self.tile_columns = int(tile_columns)
        self.num_col_tiles = math.ceil(FRAME_COLS / self.tile_columns)
        self.row_groups = FRAME_ROWS // ROWS_PER_GROUP
        self.groups_total = groups_total if groups_total is not None else (self.row_groups * self.num_col_tiles)
        self.num_parallel_units = int(num_parallel_units)
        self.bypass_mode = bypass_mode

        # OPTIMIZATION: Create multiple parallel processing units
        # Each unit has its own FIFO, producer, and consumer for parallel execution
        groups_per_unit = math.ceil(self.groups_total / self.num_parallel_units)
        self.fifos = [BankedGroupFIFO(banks, group_slots) for _ in range(self.num_parallel_units)]
        self.dma = DMAEngine(int(dram_latency), float(dram_bw))
        self.prefetcher = SplitPrefetcher(self.dma, max_outstanding, ptable_entries, coalesce_bytes)
        self.producers = [ProducerSFTM(tile_columns=self.tile_columns, groups_total=groups_per_unit, 
                                       base_period=base_period, core_id=i) 
                         for i in range(self.num_parallel_units)]
        self.consumers = [ConsumerDPM(tile_columns=self.tile_columns, base_period=base_period) 
                         for _ in range(self.num_parallel_units)]
        self.cycle = 0
        self.unit_cycles = [0] * self.num_parallel_units  # Track per-unit cycles for parallel execution
        self.halo_pixels = int(halo_pixels)
        self.tile_registry: Dict[int, TileGroup] = {}
        self.first_beat_bytes = int(first_beat_bytes) if first_beat_bytes else None
        
        # Load sparse masks if provided
        if mask_dir:
            layer_names = ["RFConv0", "RFConv1", "RFDeConv0", "RFConv2", "RFConv3", "RFDeConv1"]
            for producer in self.producers:
                producer.load_sparse_masks(mask_dir, layer_names)

        self.stats = {
            "cycles": 0,
            "groups_produced": 0,
            "groups_consumed": 0,
            "fifo_max_occupancy": 0,
            "dma_bytes": 0,
            "dma_requests": 0,
            "dma_motion_requests": 0,
            "dma_reference_requests": 0,
            "dpm_stall_cycles": 0,
            "dpm_stall_motion": 0,
            "dpm_stall_reference": 0,
            "prefetch_hits": 0,
            "prefetch_coalesced": 0,
            "prefetch_total": 0,
            "sftm_compute_cycles": 0,
            "dpm_compute_cycles": 0,
            "sftm_macs": 0,
            "dpm_macs": 0,
            "bypass_mode_used": 0,
        }
        # instrumentation
        self.fifo_occ_ts = [[] for _ in range(self.num_parallel_units)]
        self.first_byte_samples = []

    def compute_motion_region_for_tile(self, t: TileGroup) -> Tuple[int, int]:
        x0 = t.col_start
        x1 = t.col_end
        y0 = t.row_group_idx * ROWS_PER_GROUP
        y1 = (t.row_group_idx + 1) * ROWS_PER_GROUP - 1
        width = x1 - x0 + 1
        height = y1 - y0 + 1
        base = linear_addr_for_pixel(x0, y0)
        length = region_bytes_for_dims(width, height)
        return base, length

    def compute_reference_region_for_tile(self, t: TileGroup) -> Tuple[int, int]:
        x0 = t.col_start
        x1 = t.col_end
        y0 = max(0, t.row_group_idx * ROWS_PER_GROUP - self.halo_pixels)
        y1 = min(FRAME_ROWS - 1, (t.row_group_idx + 1) * ROWS_PER_GROUP - 1 + self.halo_pixels)
        width = x1 - x0 + 1
        height = y1 - y0 + 1
        base = linear_addr_for_pixel(x0, y0)
        length = region_bytes_for_dims(width, height)
        return base, length

    def allocate_dest_banks_for_tile(self, t: TileGroup, fifo: BankedGroupFIFO) -> List[Tuple[int, int]]:
        slot_idx = fifo.occupancy()
        bank = slot_idx % fifo.banks
        local_slot = slot_idx // fifo.banks
        # clamp local_slot to group_slots_per_bank - defensive
        if local_slot >= fifo.group_slots_per_bank:
            local_slot = fifo.group_slots_per_bank - 1
        return [(bank, local_slot)]

    def step(self):
        self.cycle += 1

        # OPTIMIZATION: Process all parallel units simultaneously
        # Each unit has its own producer, FIFO, and consumer
        for unit_idx in range(self.num_parallel_units):
            fifo = self.fifos[unit_idx]
            producer = self.producers[unit_idx]
            consumer = self.consumers[unit_idx]
            
            # 1. Producer SFTM for this unit (with actual computation)
            result = producer.step()
            if result is not None:
                t, sftm_cycles, macs = result
                self.stats["groups_produced"] += 1
                self.stats["sftm_compute_cycles"] += sftm_cycles
                self.stats["sftm_macs"] += macs
                self.tile_registry[t.gid] = t
                
                # Bypass mode check
                if self.bypass_mode or not fifo.can_push():
                    # Use DRAM scatter-gather path (baseline behavior)
                    t.bypass_mode = True
                    self.stats["bypass_mode_used"] += 1
                else:
                    pushed = fifo.push(t)
                    if pushed:
                        # enqueue reference prefetch
                        ref_base, ref_length = self.compute_reference_region_for_tile(t)
                        dest_banks = self.allocate_dest_banks_for_tile(t, fifo)
                        entry = self.prefetcher.coalesce_enqueue(ref_base, ref_length, dest_banks, request_type="reference")
                        if t.gid not in entry.linked_tiles:
                            entry.linked_tiles.append(t.gid)

            # 4. Consumer DPM for this unit (with actual computation)
            consumer.step()
            if consumer.ready_to_consume():
                front = fifo.peek()
                if front:
                    if front.motion_ready and front.reference_ready:
                        popped = fifo.pop()
                        self.stats["groups_consumed"] += 1
                        # Compute actual DPM cycles
                        dpm_cycles, dpm_macs = consumer.start_consume(popped)
                        self.stats["dpm_compute_cycles"] += dpm_cycles
                        self.stats["dpm_macs"] += dpm_macs
                    else:
                        self.stats["dpm_stall_cycles"] += 1
                        if not front.motion_ready:
                            self.stats["dpm_stall_motion"] += 1
                        if not front.reference_ready:
                            self.stats["dpm_stall_reference"] += 1

            # 5. Stats update per unit
            occ = fifo.occupancy()
            if occ > self.stats["fifo_max_occupancy"]:
                self.stats["fifo_max_occupancy"] = occ
            fifo.record_ts(self.cycle)
            self.fifo_occ_ts[unit_idx] = list(fifo.occ_timeseries)
            
            # Track this unit's cycle count
            self.unit_cycles[unit_idx] = self.cycle

        # 2. Prefetcher issues (shared across units)
        issued = self.prefetcher.step()
        for tag, entry in issued:
            self.stats["dma_requests"] += 1
            self.stats["dma_bytes"] += int(entry.length)
            if entry.request_type == "reference":
                self.stats["dma_reference_requests"] += 1
            else:
                self.stats["dma_motion_requests"] += 1

        # 3. DMA step + collect completions (shared)
        self.dma.step()
        completed = self.dma.collect_completed()
        for req in completed:
            self.prefetcher.on_dma_completed(req)
            entry = self.prefetcher.tag_to_entry.get(req.tag, None)
            if entry is None:
                for e in self.prefetcher.ptable:
                    if e.tag == req.tag:
                        entry = e
                        break
            if entry and entry.request_type == "reference":
                for gid in entry.linked_tiles:
                    tile = self.tile_registry.get(gid)
                    if tile:
                        tile.reference_ready = True
            self.first_byte_samples.append((req.tag, req.issue_cycle, req.done_cycle, req.request_type))

        self.stats["prefetch_total"] = self.prefetcher.requests_total
        self.stats["prefetch_hits"] = self.prefetcher.requests_hits
        self.stats["prefetch_coalesced"] = self.prefetcher.requests_coalesced
        
        # CRITICAL OPTIMIZATION: Use max of unit cycles for parallel execution
        # Units run in parallel, so total time is the longest unit, not the sum!
        self.stats["cycles"] = max(self.unit_cycles) if self.unit_cycles else self.cycle
        
        done = (self.stats["groups_consumed"] >= self.groups_total)
        return done

    def run(self, max_cycles: int = 10_000_000, probe_cycles: Optional[int] = None):
        start_time = time.time()
        if probe_cycles:
            # quick probe run to collect early behavior
            for _ in range(probe_cycles):
                self.step()
        while self.cycle < max_cycles:
            finished = self.step()
            if finished:
                break
        elapsed = time.time() - start_time
        res = dict(self.stats)
        res["dma_outstanding_at_end"] = self.dma.outstanding_count()
        # Sum overflow counts from all FIFOs
        res["fifo_overflow_count"] = sum(fifo.overflow_count for fifo in self.fifos)
        res["tile_columns"] = self.tile_columns
        res["num_col_tiles"] = self.num_col_tiles
        res["row_groups"] = self.row_groups
        res["runtime_s"] = elapsed
        res["dram_bw"] = self.dma.bw
        res["num_parallel_units"] = self.num_parallel_units
        res["unit_cycles"] = list(self.unit_cycles)
        # attach instrumentation (aggregate from all units)
        all_fifo_ts = []
        for unit_ts in self.fifo_occ_ts:
            all_fifo_ts.extend(unit_ts)
        res["fifo_occ_timeseries"] = all_fifo_ts
        res["first_byte_samples"] = list(self.first_byte_samples)
        return res


# -----------------------------
# helper to estimate MACs from transform mask .npz files
# -----------------------------
def estimate_macs_from_mask_dir(mask_dir: str, frame_H: int = FRAME_ROWS, frame_W: int = FRAME_COLS) -> Dict[str, int]:
    """
    Estimate MACs from .npz transform masks in mask_dir.
    For each layer file (e.g., RFConv0.npz), we compute:
      total_output_patches = ceil(frame_H/2) * ceil(frame_W/2)
      macs_layer = num_nonzeros_in_mask * total_output_patches

    This is an approximation consistent with our baseline simulator's transform-domain counting.
    Returns dict: {layer_name: macs, ..., 'total': total_macs}
    """
    if not mask_dir or not os.path.isdir(mask_dir):
        return None
    total_patches = math.ceil(frame_H / 2) * math.ceil(frame_W / 2)
    macs_by_layer = {}
    total = 0
    for fname in os.listdir(mask_dir):
        if not fname.endswith(".npz"):
            continue
        path = os.path.join(mask_dir, fname)
        try:
            d = np.load(path)
            idx0 = d['idx0']
            # number of transform-domain nonzeros (each corresponds to one multiply per output patch)
            nonzeros = idx0.size
            macs = int(nonzeros) * int(total_patches)
            layer_name = fname[:-4]  # strip .npz
            macs_by_layer[layer_name] = macs
            total += macs
        except Exception as e:
            # skip corrupt files
            print(f"Warning: failed to read {path}: {e}")
    macs_by_layer['total'] = total
    return macs_by_layer

# -----------------------------
# wrapper API to mimic baseline simulator interface
# -----------------------------
def simulate_frame_proposed(tile_columns: int = 120,
                            dram_bw: float = DEFAULT_DRAM_BW_BYTES_PER_CYCLE,
                            dram_lat: int = DEFAULT_DRAM_LATENCY,
                            max_cycles: int = 10_000_000,
                            banks: int = DEFAULT_BANKS,
                            group_slots: int = DEFAULT_GROUP_SLOTS,
                            mask_dir: Optional[str] = None,
                            frame_H: int = FRAME_ROWS,
                            frame_W: int = FRAME_COLS,
                            seed: int = RNG_SEED,
                            probe_cycles: Optional[int] = None,
                            num_parallel_units: int = 4,
                            **kwargs) -> Dict:
    """
    Run the proposed (group-synchronized) simulator and return a stats dict
    matching the baseline simulator's keys.

    Returned dict keys:
      - 'cycles' (int)
      - 'mac_counts' (dict per-layer + 'total') or None if mask_dir not provided
      - 'module_cycles' (dict with approximate mapping)
      - 'bytes_written_offchip' (int)  -- mapped to dma_bytes in your sim
      - 'bytes_read_offchip'  (int) -- currently 0 (no writes back)
      - 'scu_assigned' (dict) -- empty (not modeled in this sim)
      - 'fifo_stats' (dict: max_occ, avg_occ, overflow_count, occ_timeseries)
      - 'runtime_s' (float)
      - plus raw sim stats returned under 'raw'
    """
    bypass = kwargs.get('bypass_mode', False)
    sim = Simulator(tile_columns=tile_columns,
                    banks=banks,
                    group_slots=group_slots,
                    dram_latency=dram_lat,
                    dram_bw=dram_bw,
                    base_period=DEFAULT_BASE_PERIOD,
                    seed=seed,
                    coalesce_bytes=DEFAULT_COALESCE_BYTES,
                    num_parallel_units=num_parallel_units,
                    bypass_mode=bypass,
                    mask_dir=mask_dir)
    # run probe if requested
    res = sim.run(max_cycles=max_cycles, probe_cycles=probe_cycles)
    # remap to baseline style metrics
    module_cycles = {}
    total_cycles = int(res.get('cycles', 0))
    # Use actual computed cycles from SFTM and DPM
    module_cycles['SFTM'] = int(res.get('sftm_compute_cycles', 0))
    module_cycles['DPM'] = int(res.get('dpm_compute_cycles', 0))
    # estimate dma_mem_cycles based on bytes and dram bw
    dma_mem_cycles = 0
    if 'dram_bw' in res and res['dram_bw'] > 0:
        bytes_per_cycle = res['dram_bw']
        dma_mem_cycles = int(math.ceil(res.get('dma_bytes', 0) / max(1.0, bytes_per_cycle)))
    module_cycles['SFTM_mem'] = dma_mem_cycles
    # Use actual MAC counts from simulation
    sftm_macs = int(res.get('sftm_macs', 0))
    dpm_macs = int(res.get('dpm_macs', 0))
    mac_counts = {
        'SFTM': sftm_macs,
        'DPM': dpm_macs,
        'total': sftm_macs + dpm_macs
    } if (sftm_macs > 0 or dpm_macs > 0) else estimate_macs_from_mask_dir(mask_dir, frame_H=frame_H, frame_W=frame_W)
    # build fifo stats
    occ_ts = res.get('fifo_occ_timeseries', [])
    occ_vals = [v for (_, v) in occ_ts] if occ_ts else []
    fifo_stats = {
        'max_occ': int(res.get('fifo_max_occupancy', 0)),
        'avg_occ': float(np.mean(occ_vals)) if occ_vals else 0.0,
        'overflow_count': int(res.get('fifo_overflow_count', 0)),
        'occ_timeseries': occ_ts
    }
    standardized = {
        'cycles': total_cycles,
        'mac_counts': mac_counts,
        'module_cycles': module_cycles,
        'bytes_written_offchip': int(res.get('dma_bytes', 0)),
        'bytes_read_offchip': int(res.get('dma_bytes', 0)),  # this sim issues DRAM reads into on-chip buffers -> count as read
        'scu_assigned': {},   # not modeled here
        'fifo_stats': fifo_stats,
        'runtime_s': float(res.get('runtime_s', 0.0)),
        'raw': res
    }
    return standardized

# -----------------------------
# CLI wrapper for convenience
# -----------------------------
def main_cli():
    parser = argparse.ArgumentParser(description="VCNPU proposed-sim wrapper (returns baseline-style metrics)")
    parser.add_argument("--tile_columns", type=int, default=120)
    parser.add_argument("--dram_bw", type=float, default=DEFAULT_DRAM_BW_BYTES_PER_CYCLE)
    parser.add_argument("--dram_lat", type=int, default=DEFAULT_DRAM_LATENCY)
    parser.add_argument("--max_cycles", type=int, default=5_000_000)
    parser.add_argument("--banks", type=int, default=DEFAULT_BANKS)
    parser.add_argument("--group_slots", type=int, default=DEFAULT_GROUP_SLOTS)
    parser.add_argument("--mask_dir", type=str, default=None, help="Directory with transform mask .npz files for MAC estimation")
    parser.add_argument("--probe_cycles", type=int, default=None)
    parser.add_argument("--bypass_mode", action="store_true", help="Use DRAM scatter-gather path instead of FIFO")
    parser.add_argument("--num_parallel_units", type=int, default=4, help="Number of parallel processing units")
    args = parser.parse_args()
    stats = simulate_frame_proposed(tile_columns=args.tile_columns,
                                    dram_bw=args.dram_bw,
                                    dram_lat=args.dram_lat,
                                    max_cycles=args.max_cycles,
                                    banks=args.banks,
                                    group_slots=args.group_slots,
                                    mask_dir=args.mask_dir,
                                    probe_cycles=args.probe_cycles,
                                    num_parallel_units=args.num_parallel_units,
                                    bypass_mode=args.bypass_mode)
    # print top-level summary (compact)
    print("=== PROPOSED SIM SUMMARY ===")
    print(f"Simulated cycles: {stats['cycles']}")
    mc = stats['mac_counts']
    if mc:
        print(f"Total MACs: {mc.get('total', 'N/A'):,}")
        if 'SFTM' in mc and 'DPM' in mc:
            print(f"  SFTM MACs: {mc['SFTM']:,}")
            print(f"  DPM MACs: {mc['DPM']:,}")
    else:
        print("MACs: N/A (no mask_dir provided)")
    print(f"Module cycles: {stats['module_cycles']}")
    raw = stats.get('raw', {})
    if 'bypass_mode_used' in raw and raw['bypass_mode_used'] > 0:
        print(f"Bypass mode: Used for {raw['bypass_mode_used']} tiles (FIFO full)")
    print(f"Off-chip bytes (DRAM reads): {stats['bytes_read_offchip']}")
    print(f"FIFO stats: max_occ={stats['fifo_stats']['max_occ']} overflow={stats['fifo_stats']['overflow_count']}")
    # save json summary
    outpath = OUT_DIR / f"proposed_summary_tiles{args.tile_columns}_bw{int(args.dram_bw)}.json"
    with open(outpath, 'w') as f:
        json.dump(stats, f, indent=2)
    print("Saved summary to", outpath)
    return stats

if __name__ == "__main__":
    main_cli()
