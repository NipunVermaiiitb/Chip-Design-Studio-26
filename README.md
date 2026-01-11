## Project Idea

Neural Video Compression (NVC) achieves superior coding efficiency but places heavy
bandwidth demands on hardware accelerators. The baseline **VCNPU** architecture
uses a *scatter–gather* dataflow, where intermediate Motion Synthesis outputs
(Ôₜ) are written to off-chip DRAM and immediately read back by the Deformable
Prediction Module (DPM). This redundant memory round-trip consumes approximately
**18 GB/s** for 1080p video at 60 FPS, creating a memory bottleneck and limiting
parallel execution.

This project introduces a micro-architectural enhancement called the
**Group-Synchronized Tile Forwarding Engine**. By exploiting the accelerator’s
4-row *group-based* processing granularity, the design replaces the DRAM
round-trip with an on-chip, multi-banked SRAM FIFO. This allows the DPM to
consume motion vectors immediately as they are generated, enabling true
cross-engine pipelining.

To further decouple execution, the design incorporates a **Split-Prefetcher**
that separates motion vector availability from reference frame (Fₜ₋₁) fetches.
Analytical modeling shows that this approach reduces off-chip traffic by
approximately **300 MB per frame** and enables deterministic overlap between
the SFTM and DPM engines.

### Objectives

- **Energy Efficiency**  
  DRAM access consumes orders of magnitude more energy per bit than on-chip SRAM.
  Eliminating approximately **17.9 GB/s** of off-chip traffic significantly reduces
  system energy consumption and thermal design power (TDP).

- **Performance**  
  Pipeline overlap enables total frame latency to approach  
  `max(T_SFTM, T_DPM)` instead of `T_SFTM + T_DPM`, potentially delivering a
  **10–20% throughput improvement**.

- **Reliability & Debuggability**  
  A *bypass mode* is supported to route data through the original scatter–gather
  path in case of FIFO overflow or for functional verification and debugging.
