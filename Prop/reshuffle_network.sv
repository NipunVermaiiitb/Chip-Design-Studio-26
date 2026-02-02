// reshuffle_network.sv
// Lightweight reshuffle network between PosT array and output buffer.
//
// In the VCNPU paper (Fig. 3(b)), a reshuffle network helps align / reorder
// overlapped output tiles produced by the tile-matching rule.
//
// This implementation provides a parameterizable row-rotation reshuffle that:
// - Does NOT change throughput or interface widths
// - Provides deterministic remapping controlled by a small step counter
//
// NOTE: The exact banking/scheduling in Fig. 7 depends on multi-bank buffers and
// runtime scheduling across layers. In this repo's simplified streaming SFTM,
// we model the reshuffle as a configurable permutation stage.

`timescale 1ns/1ps
module reshuffle_network #(
    parameter int N = 4,
    parameter int WIDTH = 32
) (
    input  wire [$clog2(N)-1:0] step,
    input  wire signed [WIDTH-1:0]   in_patch  [0:N-1][0:N-1],
    output wire signed [WIDTH-1:0]   out_patch [0:N-1][0:N-1]
);

genvar r, c;
generate
    for (r = 0; r < N; r = r + 1) begin : gen_r
        for (c = 0; c < N; c = c + 1) begin : gen_c
            // Row-rotation: out[r][c] = in[(r + step) % N][c]
            // This matches the idea of shifting overlapped rows across successive tiles.
            localparam int unsigned RU = r;
            wire [$clog2(N)-1:0] src_r = (RU + step) % N;
            assign out_patch[r][c] = in_patch[src_r][c];
        end
    end
endgenerate

endmodule

