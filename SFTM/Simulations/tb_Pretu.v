`timescale 1ns/1ps

module tb_PreTu;

    parameter DW = 16;
    integer i;

    // -------------------------
    // Inputs
    // -------------------------
    reg signed [DW-1:0]
        X00, X01, X02, X03,
        X10, X11, X12, X13,
        X20, X21, X22, X23,
        X30, X31, X32, X33;

    // -------------------------
    // Outputs (DUT)
    // -------------------------
    wire signed [DW+1:0]
        Y00, Y01, Y02, Y03,
        Y10, Y11, Y12, Y13,
        Y20, Y21, Y22, Y23,
        Y30, Y31, Y32, Y33;

    // -------------------------
    // Golden outputs
    // -------------------------
    reg signed [DW+1:0]
        G00, G01, G02, G03,
        G10, G11, G12, G13,
        G20, G21, G22, G23,
        G30, G31, G32, G33;

    // -------------------------
    // DUT
    // -------------------------
    PreTu #(DW) dut (
        X00, X01, X02, X03,
        X10, X11, X12, X13,
        X20, X21, X22, X23,
        X30, X31, X32, X33,
        Y00, Y01, Y02, Y03,
        Y10, Y11, Y12, Y13,
        Y20, Y21, Y22, Y23,
        Y30, Y31, Y32, Y33
    );

    // =========================================================
    // Test sequence
    // =========================================================
    initial begin
        $display("====================================");
        $display("        PreTu Testbench Start");
        $display("====================================");

        // Test 1: Sequential
        set_inputs( 1,  2,  3,  4,
                    5,  6,  7,  8,
                    9, 10, 11, 12,
                   13, 14, 15, 16);
        run_test("Test 1: Sequential");

        // Test 2: Signed mix
        set_inputs(-1,  2, -3,  4,
                    5, -6,  7, -8,
                   -9, 10,-11, 12,
                   13,-14, 15,-16);
        run_test("Test 2: Signed");

        // Test 3: Zeros
        set_inputs(0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0);
        run_test("Test 3: All zeros");

        // Test 4: Max positive
        set_inputs(32767,32767,32767,32767,
                   32767,32767,32767,32767,
                   32767,32767,32767,32767,
                   32767,32767,32767,32767);
        run_test("Test 4: Max positive");

        // Test 5: Max negative
        set_inputs(-32768,-32768,-32768,-32768,
                   -32768,-32768,-32768,-32768,
                   -32768,-32768,-32768,-32768,
                   -32768,-32768,-32768,-32768);
        run_test("Test 5: Max negative");

        // Random tests
        for (i = 0; i < 10; i = i + 1) begin
            set_inputs($random,$random,$random,$random,
                       $random,$random,$random,$random,
                       $random,$random,$random,$random,
                       $random,$random,$random,$random);

            $display("\n--- Random Test %0d ---", i);
            run_test("Random");
        end

        $display("\n====================================");
        $display("        ALL TESTS COMPLETE");
        $display("====================================");
        $finish;
    end

    // =========================================================
    // Helpers
    // =========================================================
    task set_inputs;
        input signed [DW-1:0] a0,a1,a2,a3,a4,a5,a6,a7,
                              a8,a9,a10,a11,a12,a13,a14,a15;
        begin
            X00=a0;  X01=a1;  X02=a2;  X03=a3;
            X10=a4;  X11=a5;  X12=a6;  X13=a7;
            X20=a8;  X21=a9;  X22=a10; X23=a11;
            X30=a12; X31=a13; X32=a14; X33=a15;
        end
    endtask

    task run_test;
        input [8*32:1] name;
        begin
            #10;
            compute_golden;
            print_inputs(name);
            check(name);
            print_outputs;
        end
    endtask

    // =========================================================
    // Printing
    // =========================================================
    task print_inputs;
        input [8*32:1] name;
        begin
            $display("\n=== %s ===", name);
            $display("Inputs:");
            $display("[%6d %6d %6d %6d]", X00,X01,X02,X03);
            $display("[%6d %6d %6d %6d]", X10,X11,X12,X13);
            $display("[%6d %6d %6d %6d]", X20,X21,X22,X23);
            $display("[%6d %6d %6d %6d]", X30,X31,X32,X33);
        end
    endtask

    task print_outputs;
        begin
            $display("DUT Output:");
            $display("[%6d %6d %6d %6d]", Y00,Y01,Y02,Y03);
            $display("[%6d %6d %6d %6d]", Y10,Y11,Y12,Y13);
            $display("[%6d %6d %6d %6d]", Y20,Y21,Y22,Y23);
            $display("[%6d %6d %6d %6d]", Y30,Y31,Y32,Y33);

            $display("Golden:");
            $display("[%6d %6d %6d %6d]", G00,G01,G02,G03);
            $display("[%6d %6d %6d %6d]", G10,G11,G12,G13);
            $display("[%6d %6d %6d %6d]", G20,G21,G22,G23);
            $display("[%6d %6d %6d %6d]", G30,G31,G32,G33);
        end
    endtask

    // =========================================================
    // Golden model
    // =========================================================
    task compute_golden;
        reg signed [DW:0]
            r00,r01,r02,r03,
            r10,r11,r12,r13,
            r20,r21,r22,r23,
            r30,r31,r32,r33;
        begin
            row(X00,X01,X02,X03, r00,r01,r02,r03);
            row(X10,X11,X12,X13, r10,r11,r12,r13);
            row(X20,X21,X22,X23, r20,r21,r22,r23);
            row(X30,X31,X32,X33, r30,r31,r32,r33);

            row(r00,r10,r20,r30, G00,G10,G20,G30);
            row(r01,r11,r21,r31, G01,G11,G21,G31);
            row(r02,r12,r22,r32, G02,G12,G22,G32);
            row(r03,r13,r23,r33, G03,G13,G23,G33);
        end
    endtask

    task row;
        input  signed [DW:0] a,b,c,d;
        output signed [DW+1:0] y0,y1,y2,y3;
        begin
            y0 =  a - c;
            y1 =  b + c;
            y2 = -b + c;
            y3 =  b - d;
        end
    endtask

    // =========================================================
    // Checker
    // =========================================================
    task check;
        input [8*32:1] name;
        integer errors;
        begin
            errors = 0;

            if (Y00!==G00) begin errors=errors+1; $display("Mismatch Y00"); end
            if (Y01!==G01) begin errors=errors+1; $display("Mismatch Y01"); end
            if (Y02!==G02) begin errors=errors+1; $display("Mismatch Y02"); end
            if (Y03!==G03) begin errors=errors+1; $display("Mismatch Y03"); end
            if (Y10!==G10) begin errors=errors+1; $display("Mismatch Y10"); end
            if (Y11!==G11) begin errors=errors+1; $display("Mismatch Y11"); end
            if (Y12!==G12) begin errors=errors+1; $display("Mismatch Y12"); end
            if (Y13!==G13) begin errors=errors+1; $display("Mismatch Y13"); end
            if (Y20!==G20) begin errors=errors+1; $display("Mismatch Y20"); end
            if (Y21!==G21) begin errors=errors+1; $display("Mismatch Y21"); end
            if (Y22!==G22) begin errors=errors+1; $display("Mismatch Y22"); end
            if (Y23!==G23) begin errors=errors+1; $display("Mismatch Y23"); end
            if (Y30!==G30) begin errors=errors+1; $display("Mismatch Y30"); end
            if (Y31!==G31) begin errors=errors+1; $display("Mismatch Y31"); end
            if (Y32!==G32) begin errors=errors+1; $display("Mismatch Y32"); end
            if (Y33!==G33) begin errors=errors+1; $display("Mismatch Y33"); end

            if (errors == 0)
                $display("STATUS: PASS");
            else
                $display("STATUS: FAIL (%0d errors)", errors);
        end
    endtask

endmodule
