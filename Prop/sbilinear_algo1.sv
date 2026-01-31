// sbilinear_algo1.sv
// Bit-exact (per provided spec) shift-based bilinear interpolation using Algorithm 1.
// N (iterations) = 2, M (codebook size) = 15.
//
// This module:
// 1) Computes bilinear coefficients u_d from frac_x/frac_y
// 2) For each neighbor d in {00,01,10,11}, runs Algorithm-1 (L=2) on u_d
// 3) Accumulates q_d = sum_l +/- (v_d >>> s_l) where s_l is derived from C_l[Omega]
// 4) Outputs o = sum_d q_d

`timescale 1ns/1ps

module sbilinear_algo1 #(
    parameter int DATA_W = 16,
    parameter int FRAC_BITS = 8,
    parameter int ACC_W = 32,
    parameter int N = 2,
    parameter int M = 15
)(
    input  logic clk,
    input  logic rst_n,

    input  logic valid_in,

    input  logic signed [DATA_W-1:0] v00,
    input  logic signed [DATA_W-1:0] v01,
    input  logic signed [DATA_W-1:0] v10,
    input  logic signed [DATA_W-1:0] v11,

    input  logic [FRAC_BITS-1:0] frac_x,
    input  logic [FRAC_BITS-1:0] frac_y,

    output logic signed [DATA_W-1:0] out,
    output logic valid_out
);

    localparam int D = 4;
    localparam int COEFF_W = FRAC_BITS+1; // 0..2^FRAC_BITS

    // Compute bilinear coefficients (unsigned Q(FRAC_BITS))
    logic [FRAC_BITS:0] one;
    logic [FRAC_BITS:0] ax, by;
    logic [2*FRAC_BITS+1:0] t00, t01, t10, t11;
    logic [COEFF_W-1:0] u00, u01, u10, u11;

    always_comb begin
        one = (1<<FRAC_BITS);
        ax = {1'b0, frac_x};
        by = {1'b0, frac_y};

        t00 = (one - ax) * (one - by);
        t01 = ax * (one - by);
        t10 = (one - ax) * by;
        t11 = ax * by;

        u00 = t00[2*FRAC_BITS+1 -: COEFF_W]; // >> FRAC_BITS
        u01 = t01[2*FRAC_BITS+1 -: COEFF_W];
        u10 = t10[2*FRAC_BITS+1 -: COEFF_W];
        u11 = t11[2*FRAC_BITS+1 -: COEFF_W];
    end

    // --- Algorithm 1 helper: compute eta = floor(log2(delta)) for unsigned Q(FRAC_BITS)
    function automatic int eta_floor_log2(input logic [COEFF_W-1:0] delta);
        int p;
        begin
            if (delta == '0) begin
                eta_floor_log2 = -FRAC_BITS; // arbitrary; will be ignored by delta==0 guard
            end else begin
                p = 0;
                for (int b = COEFF_W-1; b >= 0; b--) begin
                    if (delta[b]) begin
                        p = b;
                        break;
                    end
                end
                // delta is scaled by 2^FRAC_BITS
                eta_floor_log2 = p - FRAC_BITS;
            end
        end
    endfunction

    // Convert (l, Omega) -> shift count s_l per the provided codebooks.
    // Codebooks:
    //  l=1: {0, ±1, ±2^-1, ..., ±2^-6} => shifts {0..6}
    //  l=2: {0, ±2^-1, ..., ±2^-7}     => shifts {1..7}
    // We implement s_l as shift count; sign is carried separately.
    function automatic int codebook_shift(input int l, input int omega);
        int mag;
        int s;
        begin
            mag = (omega < 0) ? -omega : omega;
            if (mag == 0) begin
                s = 0;
            end else begin
                // shift = l + mag - 2  (matches the listed shift ranges)
                s = l + mag - 2;
                if (s < 0) s = 0;
            end
            codebook_shift = s;
        end
    endfunction

    // One neighbor: run N=2 iterations, return signed accumulated contribution
    function automatic logic signed [ACC_W-1:0] neighbor_acc(
        input logic signed [DATA_W-1:0] v,
        input logic [COEFF_W-1:0] u_init
    );
        logic [COEFF_W-1:0] u;
        logic [COEFF_W-1:0] delta;
        int eta;
        int omega;
        int s;
        logic signed [ACC_W-1:0] q;
        logic [COEFF_W-1:0] rho;
        int l;
        begin
            q = '0;
            u = u_init;

            for (l = 1; l <= N; l++) begin
                delta = u;

                if (delta == '0) begin
                    omega = 0;
                    rho = '0;
                end else begin
                    eta = eta_floor_log2(delta);

                    // rho = 2^eta in Q(FRAC_BITS)
                    // if eta >= 0 => left shift; else right shift.
                    if (eta >= 0) begin
                        if (eta >= 16) rho = '0; // out of range
                        else rho = (1<<FRAC_BITS) <<< eta;
                    end else begin
                        int sh;
                        sh = -eta;
                        if (sh >= 31) rho = '0;
                        else rho = (1<<FRAC_BITS) >>> sh;
                    end

                    // Round-to-nearest: if delta > 1.5 * 2^eta then eta++ (and recompute rho)
                    // Compare in integer domain: 2*delta > 3*rho
                    if ((delta <<< 1) > (rho * 3)) begin
                        eta = eta + 1;
                        if (eta >= 0) begin
                            if (eta >= 16) rho = '0;
                            else rho = (1<<FRAC_BITS) <<< eta;
                        end else begin
                            int sh2;
                            sh2 = -eta;
                            if (sh2 >= 31) rho = '0;
                            else rho = (1<<FRAC_BITS) >>> sh2;
                        end
                    end

                    // Omega = (-l - eta + 1)  (epsilon is +1 for bilinear coeffs)
                    omega = (-l - eta + 1);

                    // Boundary check: if 2*|Omega| > M-1 => clip to 0
                    if ((2 * ((omega < 0) ? -omega : omega)) > (M - 1)) begin
                        omega = 0;
                        rho = '0;
                    end
                end

                s = codebook_shift(l, omega);

                if (omega != 0) begin
                    if (omega < 0) q = q - ($signed(v) >>> s);
                    else q = q + ($signed(v) >>> s);
                end

                // Update residue: u = u - rho (unsigned coeffs)
                if (u > rho) u = u - rho;
                else u = '0;
            end

            neighbor_acc = q;
        end
    endfunction

    logic signed [ACC_W-1:0] sum_next;

    always_comb begin
        sum_next = '0;
        sum_next += neighbor_acc(v00, u00);
        sum_next += neighbor_acc(v01, u01);
        sum_next += neighbor_acc(v10, u10);
        sum_next += neighbor_acc(v11, u11);
    end

    // 1-cycle pipeline like the prior sbilinear
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out <= '0;
            valid_out <= 1'b0;
        end else begin
            if (valid_in) begin
                out <= sum_next[DATA_W-1:0];
                valid_out <= 1'b1;
            end else begin
                valid_out <= 1'b0;
            end
        end
    end

endmodule
