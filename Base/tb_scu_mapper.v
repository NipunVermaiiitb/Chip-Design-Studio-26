`timescale 1ns/1ps

module tb_scu_mapper;

    localparam POF = 4;
    localparam PIF = 12;
    localparam IDX_WIDTH = 16;

    reg  [IDX_WIDTH-1:0] out_idx;
    reg  [IDX_WIDTH-1:0] in_idx;
    reg  [IDX_WIDTH-1:0] out_ch;
    reg  [IDX_WIDTH-1:0] in_ch;

    wire [$clog2(POF)-1:0] scu_row;
    wire [$clog2(PIF)-1:0] scu_col;
    wire [$clog2(POF*PIF)-1:0] scu_linear;

    integer error_count;
    integer exp_row, exp_col;

    scu_mapper #(
        .POF(POF),
        .PIF(PIF),
        .IDX_WIDTH(IDX_WIDTH)
    ) dut (
        .out_idx(out_idx),
        .in_idx(in_idx),
        .out_ch(out_ch),
        .in_ch(in_ch),
        .scu_row(scu_row),
        .scu_col(scu_col),
        .scu_linear(scu_linear)
    );

    // golden model
    function integer ceil_div;
        input integer a, b;
        begin
            ceil_div = (a + b - 1) / b;
        end
    endfunction

    task check;
        input integer o, i, oc, ic;
        integer out_per_row, in_per_col;
        begin
            out_idx = o;
            in_idx  = i;
            out_ch  = oc;
            in_ch   = ic;
            #1;

            out_per_row = ceil_div(oc, POF);
            in_per_col  = ceil_div(ic, PIF);

            exp_row = o / out_per_row;
            exp_col = i / in_per_col;

            if (exp_row >= POF) exp_row = POF - 1;
            if (exp_col >= PIF) exp_col = PIF - 1;

            if (scu_row !== exp_row || scu_col !== exp_col) begin
                $display("ERROR: o=%0d i=%0d -> exp(%0d,%0d) got(%0d,%0d)",
                         o, i, exp_row, exp_col, scu_row, scu_col);
                error_count = error_count + 1;
            end
        end
    endtask

    initial begin
        error_count = 0;

        // Typical RepVCN case
        check(0, 0, 36, 36);
        check(5, 10, 36, 36);
        check(17, 20, 36, 36);
        check(35, 35, 36, 36);

        // Edge cases
        check(0, 0, 1, 1);
        check(10, 10, 11, 11);
        check(100, 50, 36, 36);

        if (error_count == 0)
            $display("PASS: scu_mapper works as intended");
        else
            $display("FAIL: scu_mapper has %0d errors", error_count);

        $finish;
    end

endmodule
