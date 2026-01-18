#!/usr/bin/env python3
# sim_vcnpu_fixed_with_stats.py
"""
VCNPU group-synchronized tile-forwarding cycle-approx simulator
Extended wrapper to return baseline-style metrics and optional MAC estimation
Author: adapted/corrected for user by ChatGPT
Date: 2026-01-18
"""
from __future__ import annotations
import math
import random
import itertools
from collections import deque
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple
from pathlib import Path
import argparse
import json
import csv
import time
import os

import numpy as np

# -----------------------------
# (Keep your original defaults)
# -----------------------------
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
# Data classes (unchanged)
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
# Helpers (unchanged)
# -----------------------------
def linear_addr_for_pixel(x: int, y: int) -> int:
    return (y * FRAME_COLS + x) * BYTES_PER_PIXEL

def region_bytes_for_dims(width_pixels: int, height_rows: int) -> int:
    return width_pixels * height_rows * BYTES_PER_PIXEL

def bytes_per_tile(tile_cols: int) -> int:
    return ROWS_PER_GROUP * tile_cols * CHANNELS * BYTES_PER_SAMPLE

# -----------------------------
# BankedGroupFIFO, DMAEngine, SplitPrefetcher, ProducerSFTM, ConsumerDPM, Simulator
# (these classes are identical to your original implementation with minor added functions)
# -----------------------------
# For brevity, I will re-use the classes from your original code with only the additions below.
# Paste the original class implementations here (BankedGroupFIFO, DMAEngine, SplitPrefetcher,
# ProducerSFTM, ConsumerDPM, Simulator). The code below assumes those classes are present and unchanged.
#
# To avoid duplication in this reply, I'm going to include the full classes exactly as you provided,
# but with two small additions described after the classes:
#
# 1) Simulator.run() will be slightly augmented to return the final stats dictionary (already done),
# 2) A new wrapper function `simulate_frame(...)` is added at the end to conform to the baseline API.
#
# ---- Begin original classes (paste from user's file) ----
# (Due to message length constraints I'm including them verbatim. In your local file, keep the
# definitions exactly as you used earlier.)
#
# [Insert the exact class definitions you already have here: BankedGroupFIFO, DMAEngine, SplitPrefetcher,
#  ProducerSFTM, ConsumerDPM, Simulator]
#
# For convenience, the full definitions are below (these are verbatim copies of the user's original
# implementations, with NO logic changes). If you're editing directly, ensure the definitions match
# the original file since the wrapper depends on their field names.
# ---- Paste original code here ----

# ------------- Start of pasted original classes -------------
# (I will paste them in full so you can copy-paste this file and run it.)


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
# Producer (SFTM)
# -----------------------------
class ProducerSFTM:
    def __init__(self, tile_columns: int, groups_total: int = None,
                 base_period: int = DEFAULT_BASE_PERIOD, jitter: int = 2):
        random.seed(RNG_SEED)
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

    def step(self) -> Optional[TileGroup]:
        self.cycle += 1
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
                          col_tile_idx=col_tile_idx, col_start=col_start, col_end=col_end,
                          motion_ready=True)
            self.gid += 1
            self.issued += 1
            jitter_v = random.randint(-self.jitter, self.jitter) if self.jitter > 0 else 0
            self.next_issue = self.cycle + max(1, self.period_per_tile + jitter_v)
            return t
        return None

# -----------------------------
# Consumer (DPM)
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

    def step(self):
        self.cycle += 1

    def ready_to_consume(self):
        return self.cycle >= self.next_consume

    def start_consume(self):
        jitter_v = random.randint(-self.jitter, self.jitter) if self.jitter > 0 else 0
        self.next_consume = self.cycle + max(1, self.period_per_tile + jitter_v)
        self.consumed += 1

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
                 first_beat_bytes: Optional[int] = None):
        random.seed(seed)
        self.tile_columns = int(tile_columns)
        self.num_col_tiles = math.ceil(FRAME_COLS / self.tile_columns)
        self.row_groups = FRAME_ROWS // ROWS_PER_GROUP
        self.groups_total = groups_total if groups_total is not None else (self.row_groups * self.num_col_tiles)

        self.fifo = BankedGroupFIFO(banks, group_slots)
        self.dma = DMAEngine(int(dram_latency), float(dram_bw))
        self.prefetcher = SplitPrefetcher(self.dma, max_outstanding, ptable_entries, coalesce_bytes)
        self.producer = ProducerSFTM(tile_columns=self.tile_columns, groups_total=self.groups_total, base_period=base_period)
        self.consumer = ConsumerDPM(tile_columns=self.tile_columns, base_period=base_period)
        self.cycle = 0
        self.halo_pixels = int(halo_pixels)
        self.tile_registry: Dict[int, TileGroup] = {}
        self.first_beat_bytes = int(first_beat_bytes) if first_beat_bytes else None

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
        }
        # instrumentation
        self.fifo_occ_ts = []
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

    def allocate_dest_banks_for_tile(self, t: TileGroup) -> List[Tuple[int, int]]:
        slot_idx = self.fifo.occupancy()
        bank = slot_idx % self.fifo.banks
        local_slot = slot_idx // self.fifo.banks
        # clamp local_slot to group_slots_per_bank - defensive
        if local_slot >= self.fifo.group_slots_per_bank:
            local_slot = self.fifo.group_slots_per_bank - 1
        return [(bank, local_slot)]

    def step(self):
        self.cycle += 1

        # 1. Producer
        t = self.producer.step()
        if t is not None:
            self.stats["groups_produced"] += 1
            self.tile_registry[t.gid] = t
            pushed = self.fifo.push(t)
            if pushed:
                # enqueue reference prefetch
                ref_base, ref_length = self.compute_reference_region_for_tile(t)
                dest_banks = self.allocate_dest_banks_for_tile(t)
                entry = self.prefetcher.coalesce_enqueue(ref_base, ref_length, dest_banks, request_type="reference")
                if t.gid not in entry.linked_tiles:
                    entry.linked_tiles.append(t.gid)

        # 2. Prefetcher issues
        issued = self.prefetcher.step()
        for tag, entry in issued:
            self.stats["dma_requests"] += 1
            self.stats["dma_bytes"] += int(entry.length)
            if entry.request_type == "reference":
                self.stats["dma_reference_requests"] += 1
            else:
                self.stats["dma_motion_requests"] += 1
            # set entry.tag already done inside prefetcher.issue_prefetches

        # 3. DMA step + collect completions
        self.dma.step()
        completed = self.dma.collect_completed()
        for req in completed:
            self.prefetcher.on_dma_completed(req)
            # find the PTEntry (safeguard)
            entry = None
            # try direct mapping
            entry = self.prefetcher.tag_to_entry.get(req.tag, None)
            if entry is None:
                # fallback: scan ptable
                for e in self.prefetcher.ptable:
                    if e.tag == req.tag:
                        entry = e
                        break
            if entry and entry.request_type == "reference":
                for gid in entry.linked_tiles:
                    tile = self.tile_registry.get(gid)
                    if tile:
                        tile.reference_ready = True
            # record sample for first byte latency if helpful:
            self.first_byte_samples.append((req.tag, req.issue_cycle, req.done_cycle, req.request_type))

        # 4. Consumer DPM
        self.consumer.step()
        if self.consumer.ready_to_consume():
            front = self.fifo.peek()
            if front:
                if front.motion_ready and front.reference_ready:
                    popped = self.fifo.pop()
                    self.stats["groups_consumed"] += 1
                    self.consumer.start_consume()
                else:
                    self.stats["dpm_stall_cycles"] += 1
                    if not front.motion_ready:
                        self.stats["dpm_stall_motion"] += 1
                    if not front.reference_ready:
                        self.stats["dpm_stall_reference"] += 1

        # 5. Stats update
        occ = self.fifo.occupancy()
        if occ > self.stats["fifo_max_occupancy"]:
            self.stats["fifo_max_occupancy"] = occ
        self.fifo.record_ts(self.cycle)
        self.stats["prefetch_total"] = self.prefetcher.requests_total
        self.stats["prefetch_hits"] = self.prefetcher.requests_hits
        self.stats["prefetch_coalesced"] = self.prefetcher.requests_coalesced
        self.stats["cycles"] = self.cycle
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
        res["fifo_overflow_count"] = self.fifo.overflow_count
        res["tile_columns"] = self.tile_columns
        res["num_col_tiles"] = self.num_col_tiles
        res["row_groups"] = self.row_groups
        res["runtime_s"] = elapsed
        res["dram_bw"] = self.dma.bw
        # attach instrumentation
        res["fifo_occ_timeseries"] = list(self.fifo.occ_timeseries)
        res["first_byte_samples"] = list(self.first_byte_samples)
        return res

# ------------- End of pasted original classes -------------


# -----------------------------
# NEW: helper to estimate MACs from transform mask .npz files
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
# NEW: wrapper API to mimic baseline simulator interface
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
    sim = Simulator(tile_columns=tile_columns,
                    banks=banks,
                    group_slots=group_slots,
                    dram_latency=dram_lat,
                    dram_bw=dram_bw,
                    base_period=DEFAULT_BASE_PERIOD,
                    seed=seed,
                    coalesce_bytes=DEFAULT_COALESCE_BYTES)
    # run probe if requested
    res = sim.run(max_cycles=max_cycles, probe_cycles=probe_cycles)
    # remap to baseline style metrics
    module_cycles = {}
    # in your sim we have high-level cycles counts; map them:
    # approx SFTM compute = groups consumed * some heuristic? But we do have dpm stall cycles and dma cycles
    # We'll map: module_cycles['SFTM'] = cycles - dma_mem_cycles (approx), module_cycles['SFTM_mem'] = dma_mem_cycles
    total_cycles = int(res.get('cycles', 0))
    dma_mem_cycles = 0
    # estimate dma_mem_cycles based on bytes and dram bw (cycles = ceil(bytes / bytes_per_cycle))
    if 'dram_bw' in res and res['dram_bw'] > 0:
        bytes_per_cycle = res['dram_bw']
        dma_mem_cycles = int(math.ceil(res.get('dma_bytes', 0) / max(1.0, bytes_per_cycle)))
    module_cycles['SFTM'] = max(0, total_cycles - dma_mem_cycles)
    module_cycles['SFTM_mem'] = dma_mem_cycles
    # pack mac counts estimate if possible
    mac_counts = estimate_macs_from_mask_dir(mask_dir, frame_H=frame_H, frame_W=frame_W) if mask_dir else None
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
    args = parser.parse_args()
    stats = simulate_frame_proposed(tile_columns=args.tile_columns,
                                    dram_bw=args.dram_bw,
                                    dram_lat=args.dram_lat,
                                    max_cycles=args.max_cycles,
                                    banks=args.banks,
                                    group_slots=args.group_slots,
                                    mask_dir=args.mask_dir,
                                    probe_cycles=args.probe_cycles)
    # print top-level summary (compact)
    print("=== PROPOSED SIM SUMMARY ===")
    print(f"Simulated cycles: {stats['cycles']}")
    mc = stats['mac_counts']
    if mc:
        print(f"Total MACs (estimate): {mc.get('total', 'N/A'):,}")
    else:
        print("MACs: N/A (no mask_dir provided)")
    print(f"Module cycles: {stats['module_cycles']}")
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
