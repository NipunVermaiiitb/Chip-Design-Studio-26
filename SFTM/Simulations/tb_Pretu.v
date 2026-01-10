`timescale 1ns/1ps

module tb_PreTu;

    parameter DW = 16;

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

    // DUT
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

    // -------------------------
    // Test sequence
    // -------------------------
    initial begin
        $display("==== PreTu Golden Check ====");

        // Test 1
        X00=1;  X01=2;  X02=3;  X03=4;
        X10=5;  X11=6;  X12=7;  X13=8;
        X20=9;  X21=10; X22=11; X23=12;
        X30=13; X31=14; X32=15; X33=16;
        #10;
        compute_golden;
        check("Test 1");

        // Test 2 (signed)
        X00=-1;  X01=2;   X02=-3;  X03=4;
        X10=5;   X11=-6;  X12=7;   X13=-8;
        X20=-9;  X21=10;  X22=-11; X23=12;
        X30=13;  X31=-14; X32=15;  X33=-16;
        #10;
        compute_golden;
        check("Test 2");

        // Test 3 (zeros)
        X00=0; X01=0; X02=0; X03=0;
        X10=0; X11=0; X12=0; X13=0;
        X20=0; X21=0; X22=0; X23=0;
        X30=0; X31=0; X32=0; X33=0;
        #10;
        compute_golden;
        check("Test 3");

        $display("==== DONE ====");
        $finish;
    end

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
            // ---- Row stage ----
            row(X00,X01,X02,X03, r00,r01,r02,r03);
            row(X10,X11,X12,X13, r10,r11,r12,r13);
            row(X20,X21,X22,X23, r20,r21,r22,r23);
            row(X30,X31,X32,X33, r30,r31,r32,r33);

            // ---- Column stage ----
            row(r00,r10,r20,r30, G00,G10,G20,G30);
            row(r01,r11,r21,r31, G01,G11,G21,G31);
            row(r02,r12,r22,r32, G02,G12,G22,G32);
            row(r03,r13,r23,r33, G03,G13,G23,G33);
        end
    endtask

    // 1D transform (golden)
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
        input [64*8:1] name;
        integer errors;
        begin
            errors = 0;
            if (Y00!==G00) errors=errors+1;
            if (Y01!==G01) errors=errors+1;
            if (Y02!==G02) errors=errors+1;
            if (Y03!==G03) errors=errors+1;
            if (Y10!==G10) errors=errors+1;
            if (Y11!==G11) errors=errors+1;
            if (Y12!==G12) errors=errors+1;
            if (Y13!==G13) errors=errors+1;
            if (Y20!==G20) errors=errors+1;
            if (Y21!==G21) errors=errors+1;
            if (Y22!==G22) errors=errors+1;
            if (Y23!==G23) errors=errors+1;
            if (Y30!==G30) errors=errors+1;
            if (Y31!==G31) errors=errors+1;
            if (Y32!==G32) errors=errors+1;
            if (Y33!==G33) errors=errors+1;

            $display("\n%s", name);
            $display("Errors: %0d", errors);
            if (errors == 0)
                $display("STATUS: PASS ✅");
            else
                $display("STATUS: FAIL ❌");
        end
    endtask

endmodule
