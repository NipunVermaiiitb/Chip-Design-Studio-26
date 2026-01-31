// shift_quantizer_paper.sv
`timescale 1ns/1ps

module shift_quantizer_paper #(
    parameter int FRAC_BITS = 8,
    parameter int SHW = 6
)(
    input  logic [FRAC_BITS:0] c00,
    input  logic [FRAC_BITS:0] c01,
    input  logic [FRAC_BITS:0] c10,
    input  logic [FRAC_BITS:0] c11,
    output logic [SHW-1:0] s0,
    output logic [SHW-1:0] s1,
    output logic [SHW-1:0] s2,
    output logic [SHW-1:0] s3
);
    // Approximates coefficient magnitude to a right-shift amount.
    // NOTE: This is a hardware-friendly approximation, not an exact paper codebook.
    function automatic logic [SHW-1:0] approx_shift(input logic [FRAC_BITS:0] val);
        int i;
        logic [SHW-1:0] r;
        begin
            if (val == '0) begin
                r = SHW'(FRAC_BITS); // large shift -> ~0 contribution
            end else begin
                r = '0;
                // pick i so that (1 << (FRAC_BITS-i)) is close to val
                for (i = 0; i < SHW; i++) begin
                    if ((FRAC_BITS - i) >= 0 && val >= (1 << (FRAC_BITS - i))) begin
                        r = i[SHW-1:0];
                        break;
                    end
                end
            end
            approx_shift = r;
        end
    endfunction

    always_comb begin
        s0 = approx_shift(c00);
        s1 = approx_shift(c01);
        s2 = approx_shift(c10);
        s3 = approx_shift(c11);
    end
endmodule
