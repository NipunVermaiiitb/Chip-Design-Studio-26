# VCNPU Complete Integration Map

## System Overview
```
╔══════════════════════════════════════════════════════════════════════════╗
║                         VCNPU_TOP (Integrated System)                    ║
╚══════════════════════════════════════════════════════════════════════════╝

   External Inputs                                          External Outputs
   ┌──────────────┐                                        ┌──────────────┐
   │ input_data   │                                        │ output_data  │
   │ input_valid  │                                        │ output_valid │
   │ frame_width  │                                        │ busy         │
   │ frame_height │                                        │ error        │
   │ conv_mode    │                                        │ system_state │
   │ quality_mode │                                        └──────────────┘
   │ start        │
   └──────┬───────┘
          │
┌─────────▼─────────────────────────────────────────────────────────────┐
│                          WEIGHT MEMORY (4KB)                          │
│  [Loadable via weight_load_en, weight_load_addr, weight_load_data]   │
└───────────────────────────┬───────────────────────────────────────────┘
                            │ weight_data[4][4]
                            │
        ┌───────────────────▼───────────────────────┐
        │             SFTM (Full Pipeline)          │
        │  ┌────────────────────────────────────┐   │
        │  │ Input Buffer (4×4 patch)           │◄──┼─── input_data/valid
        │  └──────────┬─────────────────────────┘   │
        │             │                              │
        │  ┌──────────▼─────────────────────────┐   │
        │  │ PreTA (preta_conv / preta_deconv)  │   │
        │  │   B^T × Input × B                  │   │
        │  └──────────┬─────────────────────────┘   │
        │             │ y_in[4][4]                   │
        │  ┌──────────▼─────────────────────────┐   │
        │  │ SCA (Sparse Computing Array)       │   │
        │  │  ┌───┬───┬───┬───┐                 │   │
        │  │  │SCU│SCU│SCU│SCU│  Element-wise   │   │
        │  │  ├───┼───┼───┼───┤  multiply       │   │
        │  │  │SCU│SCU│SCU│SCU│  Y ⊙ G          │   │
        │  │  ├───┼───┼───┼───┤                 │   │
        │  │  │SCU│SCU│SCU│SCU│                 │   │
        │  │  ├───┼───┼───┼───┤                 │   │
        │  │  │SCU│SCU│SCU│SCU│                 │   │
        │  │  └───┴───┴───┴───┘                 │   │
        │  └──────────┬─────────────────────────┘   │
        │             │ u_out[4][4]                  │
        │  ┌──────────▼─────────────────────────┐   │
        │  │ PosTA (posta_conv / posta_deconv)  │   │
        │  │   A^T × U × A                      │   │
        │  └──────────┬─────────────────────────┘   │
        │             │                              │
        │  ┌──────────▼─────────────────────────┐   │
        │  │ QMU (Quality Modulation Unit)      │   │
        │  │   Scale by quality_mode            │   │
        │  └──────────┬─────────────────────────┘   │
        │             │                              │
        └─────────────┼──────────────────────────────┘
                      │ sftm_data
                      │ sftm_data_valid
                      │ sftm_group_done
                      │
        ┌─────────────▼──────────────────────────────┐
        │       GROUP_SYNC_FIFO (Credit-Based)       │
        │  ┌────────────────────────────────────┐    │
        │  │  Memory: 8 groups × 4 rows         │    │
        │  │  Depth: GROUP_ROWS × DEPTH_GROUPS  │    │
        │  │  Flow Control: Credit-based        │    │
        │  └────────────────────────────────────┘    │
        │  Status: fifo_full, fifo_empty, count      │
        └─────────────┬──────────────────────────────┘
                      │ fifo_dout
                      │ fifo_dout_valid
                      │
        ┌─────────────▼──────────────┐     ┌──────────────────────────┐
        │  DPM (Deformable Module)    │     │  SPLIT_PREFETCHER        │
        │  ┌──────────────────────┐   │     │  ┌────────────────────┐  │
        │  │ Feature Buffer 4×4   │   │     │  │ Address Generator  │  │
        │  └──────────────────────┘   │     │  │  Inputs:           │  │
        │  ┌──────────────────────┐   │     │  │  • group_x, y      │  │
        │  │ Offset Buffers 3×3   │   │     │  │  • frame_width/h   │  │
        │  │   (Δx, Δy)           │   │     │  │  • base_addr       │  │
        │  └──────────────────────┘   │     │  │                    │  │
        │  ┌──────────────────────┐   │◄────┤  │ Calculation:       │  │
        │  │ Reference Buf 16×16  │   │ ref │  │  addr = base +     │  │
        │  │ (from prefetcher)    │   │ data│  │    (y*W+x)*2       │  │
        │  └──────────────────────┘   │     │  └────────┬───────────┘  │
        │  ┌──────────────────────┐   │     │           │              │
        │  │ Bilinear Interp      │   │     │           │              │
        │  │ • Sub-pixel sample   │   │     └───────────┼──────────────┘
        │  │ • 4-neighbor blend   │   │                 │
        │  └──────────────────────┘   │                 │ dram_req
        │  ┌──────────────────────┐   │                 │ dram_addr
        │  │ MAC Accumulation     │   │                 │ dram_len
        │  │  Σ(f[i][j]*ref[i][j])│   │                 │
        │  └──────────┬───────────┘   │                 │
        └─────────────┼─────────────────┘                 │
                      │ dpm_out                           │
                      │ dpm_out_valid                     │
                      │                                   │
                      └───────► output_data               │
                                output_valid               │
                                                           │
                    ┌──────────────────────────────────────▼──┐
                    │        DRAM INTERFACE                   │
                    │  • Request: dram_req, addr, len         │
                    │  • Response: dram_ack, data_valid       │
                    │  • Data: dram_data_in                   │
                    └─────────────────────────────────────────┘

    ┌───────────────────────────────────────────────────────────────┐
    │               GLOBAL_CONTROLLER (Orchestrator)                │
    │  ┌─────────────────────────────────────────────────────────┐  │
    │  │  Monitors:                                              │  │
    │  │   • sftm_group_done, dpm_processing                    │  │
    │  │   • fifo_full, fifo_empty, fifo_count                  │  │
    │  │   • credit_available, prefetch_busy                     │  │
    │  └─────────────────────────────────────────────────────────┘  │
    │  ┌─────────────────────────────────────────────────────────┐  │
    │  │  Controls:                                              │  │
    │  │   • sftm_enable (when credits available)               │  │
    │  │   • dpm_enable (when FIFO has data)                    │  │
    │  │   • bypass_mode (adaptive on stalls)                   │  │
    │  │   • prefetch_enable (on group completion)              │  │
    │  └─────────────────────────────────────────────────────────┘  │
    │  ┌─────────────────────────────────────────────────────────┐  │
    │  │  States: IDLE → INIT → NORMAL_OP ⇄ BYPASS_OP           │  │
    │  │          → WAIT_DRAIN → DONE                           │  │
    │  └─────────────────────────────────────────────────────────┘  │
    │  Outputs: busy, error, system_state                          │
    └───────────────────────────────────────────────────────────────┘

    ┌───────────────────────────────────────────────────────────────┐
    │         GROUP POSITION TRACKER (Internal Logic)               │
    │  • Tracks current_group_x, current_group_y                    │
    │  • Raster scan order: (0,0) → (max_x,0) → (0,1) → ...        │
    │  • Wraps at frame boundaries                                  │
    │  • Used by prefetcher for address calculation                 │
    └───────────────────────────────────────────────────────────────┘
```

## Data Flow Diagram
```
Frame Start
    │
    ├─► Load weights into Weight Memory
    │
    ├─► Configure: frame_width, frame_height, ref_frame_base_addr
    │
    ├─► Set mode: conv_mode, quality_mode
    │
    ▼
┌───────────┐
│   START   │ Assert start signal
└─────┬─────┘
      │
      ▼
┌─────────────────────────────────────────┐
│  Input Stream Processing                │
│  ┌─────────────────────────────────┐    │
│  │ For each 4×4 patch:             │    │
│  │   1. Feed 16 pixels via         │    │
│  │      input_data/input_valid     │    │
│  │   2. SFTM buffers patch         │    │
│  │   3. PreTA transforms           │    │
│  │   4. SCA computes with weights  │    │
│  │   5. PosTA inverse transform    │    │
│  │   6. QMU scales by quality      │    │
│  │   7. Output to FIFO            │    │
│  └─────────────────────────────────┘    │
└─────────────┬───────────────────────────┘
              │
              ▼ (parallel with input)
┌─────────────────────────────────────────┐
│  Group Processing                        │
│  ┌─────────────────────────────────┐    │
│  │ On sftm_group_done:             │    │
│  │   1. Prefetcher calculates addr │    │
│  │   2. Issues DRAM request        │    │
│  │   3. Reference data arrives     │    │
│  │   4. DPM reads from FIFO        │    │
│  │   5. Deformable conv with ref   │    │
│  │   6. Output to stream           │    │
│  └─────────────────────────────────┘    │
└─────────────┬───────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────┐
│  Flow Control (by Global Controller)    │
│  ┌─────────────────────────────────┐    │
│  │ Continuous monitoring:          │    │
│  │   • FIFO > 75% → throttle SFTM  │    │
│  │   • FIFO < 25% → speed up SFTM  │    │
│  │   • Stall > 10 → enter bypass   │    │
│  │   • Credits exhausted → stall   │    │
│  └─────────────────────────────────┘    │
└─────────────┬───────────────────────────┘
              │
              ▼
        ┌───────────┐
        │  OUTPUT   │ output_data/output_valid stream
        └───────────┘
              │
              ▼
        Frame Complete
```

## Signal Timing Example
```
Cycle:  0    1    2    3    4    5    6    7    8    9   10   11   12
        │    │    │    │    │    │    │    │    │    │    │    │    │
start   ─┐   ┌────────────────────────────────────────────────────────
         └───┘

input_  ─────┐    ┌────┐    ┌────┐    ┌────┐    ┌────┐    ┌────┐    ┌─
valid        └────┘    └────┘    └────┘    └────┘    └────┘    └────┘

input_  ─────<D0 ><D1 ><D2 ><D3 ><D4 ><D5 ><D6 ><D7 ><D8 ><D9 ><D10><D11>
data

sftm_   ────────────────────────┐                                   ┌──
group_                          └───────────────────────────────────┘
done                           (after 16 values = 1 group)

fifo_   ─────────────────────────┐    ┌────┐    ┌────┐    ┌────┐    ┌─
dout_                            └────┘    └────┘    └────┘    └────┘
valid                            (DPM consuming)

output_ ────────────────────────────────────┐    ┌────┐    ┌────┐    ┌─
valid                                       └────┘    └────┘    └────┘
                                           (processed results)

system_ <IDLE><─INIT─><────────NORMAL_OP──────────────────────────────>
state   (00)   (01)          (01)

busy    ─────┐                                                       ┌──
             └───────────────────────────────────────────────────────┘
```

## Module Hierarchy
```
vcnpu_top
├── weight_memory (logic array)
├── current_group_x/y (registers)
├── u_sftm (sftm)
│   ├── input_buffer (registers)
│   ├── u_preta_conv (preta_conv)
│   │   └── matrix multiply logic
│   ├── u_preta_deconv (preta_deconv)
│   │   └── matrix multiply logic  
│   ├── u_sca (sca)
│   │   └── u_scu[16] (scu instances)
│   │       └── MAC units
│   ├── u_posta_conv (posta_conv)
│   │   └── matrix multiply logic
│   └── u_qmu (qmu)
│       └── quality scaling
├── u_gsfifo (group_sync_fifo)
│   ├── mem (memory array)
│   └── pointers/counters
├── u_credit_fsm (credit_fsm)
│   └── credit counter
├── u_prefetch (split_prefetcher)
│   └── address calculator
├── u_dpm (dpm)
│   ├── feature_buffer
│   ├── offset_buffers
│   ├── ref_buffer
│   └── bilinear_interp (function)
└── u_glob (global_controller)
    └── FSM + monitors
```

## Complete Port Mapping Summary

### vcnpu_top → SFTM
```
input_data       → sftm.input_data
input_valid      → sftm.input_valid
conv_mode        → sftm.conv_mode
quality_mode     → sftm.quality_mode
weight_data[4][4]→ sftm.weight_data
sftm_enable      → sftm.start
bypass_mode_en   → sftm.bypass_mode
```

### vcnpu_top → DPM
```
fifo_dout        → dpm.fifo_data
fifo_dout_valid  → dpm.fifo_data_valid
dram_data_in     → dpm.ref_data
dram_data_valid  → dpm.ref_data_valid
dpm_enable       → dpm.start
bypass_mode_en   → dpm.bypass_mode
```

### vcnpu_top → Split Prefetcher
```
frame_width      → prefetch.frame_width
frame_height     → prefetch.frame_height
ref_frame_base_addr → prefetch.ref_frame_base_addr
current_group_x  → prefetch.group_x
current_group_y  → prefetch.group_y
sftm_group_done  → prefetch.group_done
```

### vcnpu_top → Global Controller
```
start            → controller.start
sftm_group_done  → controller.sftm_group_done
dpm_processing   → controller.dpm_processing
fifo_full        → controller.fifo_full
fifo_empty       → controller.fifo_empty
credit_available → controller.credit_available
prefetch_busy    → controller.prefetch_busy
fifo_count       → controller.fifo_count
```

---

**✅ Integration Complete**  
**✅ All Modules Connected**  
**✅ Ready for Simulation**
