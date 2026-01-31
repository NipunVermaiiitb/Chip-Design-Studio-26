# VCNPU + Group-Synchronized Forwarding: RTL Implementation Notes

This repository contains a specialized RTL implementation of the VCNPU, co-optimized with a **Group-Synchronized Forwarding** dataflow. This design prioritizes the elimination of the "Memory Wall" between motion synthesis and deformable compensation.

---

## 1. Divergence from the Original Paper

While the core mathematical principles (Winograd/FTA-based transforms and sparse computing) remain intact, the hardware dataflow has been significantly modified to support the **IIIT Bangalore** research proposal.

### A. Dataflow: Forwarding vs. Scatter-Gather

* 
**Paper:** Uses a "Scatter-Gather" dataflow where the SFTM writes full motion feature maps () to off-chip DRAM before the DPM reads them back.


* 
**Implementation:** Replaces this round-trip with an **on-chip Group-Alignment FIFO**. The SFTM "forwards" processed row-groups directly to the DPM, reducing DRAM traffic by approximately **298.6 MB/frame** for 1080p video.



### B. IQML: Scalar vs. Parallel Array

* 
**Paper:** Describes a "Quality Modulating Array" (QMA) composed of multiple QMUs processing data in parallel ().


* **Implementation:** Implements a **Scalar IQMU** (1 sample/cycle). This matches the scalar input stream interface of this specific codebase, preventing hardware waste by avoiding a throughput mismatch between the input pins and the compute array.

### C. Control: Handshake vs. Serialized

* 
**Paper:** Relies on a global controller managing intricate data dependencies across complex topologies.


* 
**Implementation:** Introduces a **Credit-Based Flow Control FSM**. This enables deterministic pipeline overlap where the DPM is triggered immediately when motion vector "Credits" are available in the FIFO.



---

## 2. Strategic Simplifications (Left Out for Now)

To focus on the micro-architectural impact of the **Split-Prefetcher** and **Group-Forwarding**, the following items from the paper are currently omitted:

* 
**Window Attention Modules (WAMs):** The analysis transform's attention mechanism is excluded to focus on the synthesis (decoding) hardware path.


* 
**Mask-Sharing Pruning Strategy:** While the SCA supports indexed sparse weights, the offline "mask-sharing" generation logic is handled as a pre-processed weight-loading step rather than an on-chip dynamic process.


* **Layer Fusion for Heterogeneous Ops:** The current logic focuses on the fusion of `RFConv` and `RFDeConv`. The complex interleaved fusion of hybrid layers (Residual + Motion) described in Fig. 7 is simplified to a deterministic group-forwarding model.



---

## 3. Key Implementation Details

### The Reshuffle Network

Integrated between the Post-Transform (PosT) array and the FIFO, the **Reshuffle Network** handles the overlapping row tiles produced by the tile-matching rule ( rows). It ensures that the 4-row "Groups" stored in the 1.1 MB SRAM FIFO are spatially aligned for the DPM's variable-offset reads.

### The Split-Prefetcher

Unlike standard DMA, this unit monitors the "Group Done" signals from the SFTM. It issues DRAM read requests for the **Reference Frame** spatial regions in parallel with motion vector generation, effectively masking DRAM latency.
