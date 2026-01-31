// coeff_generator_paper.sv
`timescale 1ns/1ps

module coeff_generator_paper #(
    parameter int FRAC_BITS = 8,
    parameter int OUT_W = FRAC_BITS+1
)(
    input  logic [FRAC_BITS-1:0] frac_x,
    input  logic [FRAC_BITS-1:0] frac_y,
    output logic [OUT_W-1:0] c00,
    output logic [OUT_W-1:0] c01,
    output logic [OUT_W-1:0] c10,
    output logic [OUT_W-1:0] c11
);
    // Coeffs in unsigned Q(FRAC_BITS): range 0..(2^FRAC_BITS)
    logic [FRAC_BITS-1:0] ax;
    logic [FRAC_BITS-1:0] by;
    logic [2*FRAC_BITS-1:0] t00, t01, t10, t11;

    always_comb begin
        ax = frac_x;
        by = frac_y;

        t00 = (((1<<FRAC_BITS) - ax) * ((1<<FRAC_BITS) - by));
        t01 = (ax * ((1<<FRAC_BITS) - by));
        t10 = (((1<<FRAC_BITS) - ax) * by);
        t11 = (ax * by);

        c00 = t00[2*FRAC_BITS-1:FRAC_BITS];
        c01 = t01[2*FRAC_BITS-1:FRAC_BITS];
        c10 = t10[2*FRAC_BITS-1:FRAC_BITS];
        c11 = t11[2*FRAC_BITS-1:FRAC_BITS];
    end
endmodule
