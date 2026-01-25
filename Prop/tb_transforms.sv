// tb_transforms.sv
`timescale 1ns/1ps

module tb_transforms;

  // Parameters (match defaults used in wrappers)
  localparam int DATA_W = 16;
  localparam int ACC_W_CONV = DATA_W + 6;  // 22
  localparam int ACC_W_DECONV = DATA_W + 6; // 22 for preta_deconv
  localparam int ACC_W_POST_DECONV = DATA_W + 8; // 24 for posta_deconv
  localparam int ACC_W_GW = DATA_W + 8; // 24 for gdeconv

  // Clock / reset
  reg clk = 0;
  reg rst_n = 0;
  always #5 clk = ~clk; // 100MHz sim clock (10ns period)

  // Utility: sign-extend and mask helper
  function automatic logic signed [ACC_W_GW-1:0] mask_acc;
    input longint signed val;
    input int wid;
    longint signed tmp;
    begin
      tmp = val;
      // mask to wid bits signed (two's complement)
      mask_acc = tmp & ((1 << wid) - 1);
      // careful: for >32 bits use bit-slicing approach - but test values are safe
    end
  endfunction

  // -------------------------------
  // Instantiate modules (flat wrappers)
  // -------------------------------

  // Signals for preta_conv_flat (4x4 -> 4x4)
  reg                         pc_valid_in;
  reg  [DATA_W*16-1:0]        pc_in_flat;
  wire                        pc_valid_out;
  wire [ACC_W_CONV*16-1:0]    pc_out_flat;

  preta_conv_flat #(
    .DATA_W(DATA_W), .ACC_W(ACC_W_CONV)
  ) U_PRETA_FLAT (
    .clk(clk), .rst_n(rst_n),
    .valid_in(pc_valid_in), .patch_in_flat(pc_in_flat),
    .valid_out(pc_valid_out), .patch_out_flat(pc_out_flat)
  );

  // posta_conv_flat (4x4 -> 2x2)
  reg                         posta_valid_in;
  reg  [DATA_W*16-1:0]        posta_in_flat;
  wire                        posta_valid_out;
  wire [ACC_W_CONV*4-1:0]     posta_out_flat;

  posta_conv_flat #(
    .DATA_W(DATA_W), .ACC_W(ACC_W_CONV)
  ) U_POSTA_FLAT (
    .clk(clk), .rst_n(rst_n),
    .valid_in(posta_valid_in), .patch_in_flat(posta_in_flat),
    .valid_out(posta_valid_out), .patch_out_flat(posta_out_flat)
  );

  // preta_deconv_flat (4x4 -> 6x6)
  reg                         pdeconv_valid_in;
  reg  [DATA_W*16-1:0]        pdeconv_in_flat;
  wire                        pdeconv_valid_out;
  wire [ACC_W_DECONV*36-1:0]  pdeconv_out_flat;

  preta_deconv_flat #(
    .DATA_W(DATA_W), .ACC_W(ACC_W_DECONV)
  ) U_PRETA_D_FLAT (
    .clk(clk), .rst_n(rst_n),
    .valid_in(pdeconv_valid_in), .patch_in_flat(pdeconv_in_flat),
    .valid_out(pdeconv_valid_out), .patch_out_flat(pdeconv_out_flat)
  );

  // posta_deconv_flat (6x6 -> 4x4)
  reg                         postd_valid_in;
  reg  [DATA_W*36-1:0]        postd_in_flat;
  wire                        postd_valid_out;
  wire [ACC_W_POST_DECONV*16-1:0] postd_out_flat;

  posta_deconv_flat #(
    .DATA_W(DATA_W), .ACC_W(ACC_W_POST_DECONV)
  ) U_POSTA_D_FLAT (
    .clk(clk), .rst_n(rst_n),
    .valid_in(postd_valid_in), .patch_in_flat(postd_in_flat),
    .valid_out(postd_valid_out), .patch_out_flat(postd_out_flat)
  );

  // gdeconv_weight_transform_flat (4x4 -> 6x6)
  reg                         gwt_valid_in;
  reg  [DATA_W*16-1:0]        gwt_in_flat;
  wire                        gwt_valid_out;
  wire [ACC_W_GW*36-1:0]      gwt_out_flat;

  gdeconv_weight_transform_flat #(
    .DATA_W(DATA_W), .ACC_W(ACC_W_GW)
  ) U_GWT_FLAT (
    .clk(clk), .rst_n(rst_n),
    .valid_in(gwt_valid_in), .w_in_flat(gwt_in_flat),
    .valid_out(gwt_valid_out), .w_out_flat(gwt_out_flat)
  );

  // -------------------------------
  // Golden-reference compute functions
  // All computations are done with signed 64-bit localints to avoid overflow in TB.
  // -------------------------------

  // Preta Conv: B^T (4x4) * X (4x4) * B (4x4)
  function automatic void golden_preta_conv(
    input  logic signed [DATA_W-1:0] Xin [0:3][0:3],
    output logic signed [ACC_W_CONV-1:0] Yout [0:3][0:3]
  );
    // B^T as in paper
    int BT [0:3][0:3];
    longint signed tmp [0:3][0:3];
    int i,j,k;
    begin
      BT = '{'{1,0,-1,0}, '{0,1,1,0}, '{0,-1,1,0}, '{0,1,0,-1}};
      for (i=0;i<4;i=i+1) for (j=0;j<4;j=j+1) tmp[i][j] = 0;
      // tmp = BT * X
      for (i=0;i<4;i=i+1) begin
        for (j=0;j<4;j=j+1) begin
          longint signed acc = 0;
          for (k=0;k<4;k=k+1) begin
            acc = acc + (BT[i][k] * longint'(Xin[k][j]));
          end
          tmp[i][j] = acc;
        end
      end
      // Y = tmp * B; B is BT^T
      for (i=0;i<4;i=i+1) begin
        for (j=0;j<4;j=j+1) begin
          longint signed acc2 = 0;
          for (k=0;k<4;k=k+1) acc2 = acc2 + ( (BT[j][k]) * tmp[i][k] );
          // truncate to ACC_W_CONV bits (two's complement)
          Yout[i][j] = acc2[ACC_W_CONV-1:0];
        end
      end
    end
  endfunction

  // Posta Conv: A^T (2x4) * U (4x4) * A (4x2) -> V (2x2)
  function automatic void golden_posta_conv(
    input logic signed [DATA_W-1:0] Uin [0:3][0:3],
    output logic signed [ACC_W_CONV-1:0] Vout [0:1][0:1]
  );
    int AT [0:1][0:3];
    longint signed tmp [0:1][0:3];
    int i,j,k;
    begin
      AT = '{'{1,1,1,0}, '{0,1,-1,-1}};
      for (i=0;i<2;i=i+1) for (j=0;j<4;j=j+1) tmp[i][j] = 0;
      // tmp = AT * U
      for (i=0;i<2;i=i+1) begin
        for (j=0;j<4;j=j+1) begin
          longint signed acc = 0;
          for (k=0;k<4;k=k+1) acc = acc + AT[i][k] * longint'(Uin[k][j]);
          tmp[i][j] = acc;
        end
      end
      // V = tmp * A  where A = AT^T, so multiply with columns of AT
      for (i=0;i<2;i=i+1) begin
        for (j=0;j<2;j=j+1) begin
          longint signed acc2 = 0;
          for (k=0;k<4;k=k+1) acc2 = acc2 + tmp[i][k] * AT[j][k];
          Vout[i][j] = acc2[ACC_W_CONV-1:0];
        end
      end
    end
  endfunction

  // Preta DeConv: B^T_DeConv (6x4) * X(4x4) * B_DeConv(4x6) => 6x6
  function automatic void golden_preta_deconv(
    input logic signed [DATA_W-1:0] Xin [0:3][0:3],
    output logic signed [ACC_W_DECONV-1:0] Yout [0:5][0:5]
  );
    int BT [0:5][0:3];
    longint signed Ttmp [0:5][0:3];
    int i,j,k;
    begin
      BT = '{'{1,-1,0,0}, '{0,1,0,0}, '{0,-1,1,0}, '{0,1,-1,0}, '{0,0,1,0}, '{0,0,-1,1}};
      // Ttmp = BT * X
      for (i=0;i<6;i=i+1) for (j=0;j<4;j=j+1) Ttmp[i][j] = 0;
      for (i=0;i<6;i=i+1) begin
        for (j=0;j<4;j=j+1) begin
          longint signed acc = 0;
          for (k=0;k<4;k=k+1) acc = acc + BT[i][k] * longint'(Xin[k][j]);
          Ttmp[i][j] = acc;
        end
      end
      // Y = Ttmp * B (B is BT^T)
      for (i=0;i<6;i=i+1) begin
        for (j=0;j<6;j=j+1) begin
          longint signed acc2 = 0;
          for (k=0;k<4;k=k+1) acc2 = acc2 + Ttmp[i][k] * BT[j][k];
          Yout[i][j] = acc2[ACC_W_DECONV-1:0];
        end
      end
    end
  endfunction

  // Posta DeConv: AT (4x6) * U(6x6) * A (6x4) => 4x4
  function automatic void golden_posta_deconv(
    input logic signed [DATA_W-1:0] Uin [0:5][0:5],
    output logic signed [ACC_W_POST_DECONV-1:0] Vout [0:3][0:3]
  );
    int AT[0:3][0:5];
    longint signed tmp [0:3][0:5];
    int i,j,k;
    begin
      AT = '{'{1,1,0,0,0,0}, '{0,0,0,1,1,0}, '{0,1,1,0,0,0}, '{0,0,0,0,1,1}};
      // tmp = AT * U
      for (i=0;i<4;i=i+1) for (j=0;j<6;j=j+1) tmp[i][j] = 0;
      for (i=0;i<4;i=i+1) begin
        for (j=0;j<6;j=j+1) begin
          longint signed acc = 0;
          for (k=0;k<6;k=k+1) acc = acc + AT[i][k] * longint'(Uin[k][j]);
          tmp[i][j] = acc;
        end
      end
      // V = tmp * A  (A = AT^T)
      for (i=0;i<4;i=i+1) begin
        for (j=0;j<4;j=j+1) begin
          longint signed acc2 = 0;
          for (k=0;k<6;k=k+1) acc2 = acc2 + tmp[i][k] * AT[j][k];
          Vout[i][j] = acc2[ACC_W_POST_DECONV-1:0];
        end
      end
    end
  endfunction

  // G_DeConv weight transform: Wt = G (6x4) * W(4x4) * G^T (4x6)
  function automatic void golden_gdeconv_weight(
    input logic signed [DATA_W-1:0] Win [0:3][0:3],
    output logic signed [ACC_W_GW-1:0] Wout [0:5][0:5]
  );
    int G [0:5][0:3];
    longint signed Ttmp [0:5][0:3];
    int i,j,k;
    begin
      G = '{'{0,0,0,1},{0,1,0,1},{0,1,0,0},{0,0,1,0},{1,0,1,0},{1,0,0,0}};
      // Ttmp = G * W
      for (i=0;i<6;i=i+1) for (j=0;j<4;j=j+1) Ttmp[i][j] = 0;
      for (i=0;i<6;i=i+1) begin
        for (j=0;j<4;j=j+1) begin
          longint signed acc = 0;
          for (k=0;k<4;k=k+1) acc = acc + G[i][k] * longint'(Win[k][j]);
          Ttmp[i][j] = acc;
        end
      end
      // Wt = Ttmp * G^T
      for (i=0;i<6;i=i+1) begin
        for (j=0;j<6;j=j+1) begin
          longint signed acc2 = 0;
          for (k=0;k<4;k=k+1) acc2 = acc2 + Ttmp[i][k] * G[j][k];
          Wout[i][j] = acc2[ACC_W_GW-1:0];
        end
      end
    end
  endfunction

  // -------------------------------
  // Helpers: pack/unpack flat buses to local arrays
  // -------------------------------
  function automatic void unpack_4x4_flat_to_arr(
    input  logic [DATA_W*16-1:0] flat,
    output logic signed [DATA_W-1:0] arr [0:3][0:3]
  );
    int r,c;
    begin
      for (r=0;r<4;r=r+1) begin
        for (c=0;c<4;c=c+1) begin
          arr[r][c] = flat[(r*4+c)*DATA_W +: DATA_W];
        end
      end
    end
  endfunction

  function automatic void unpack_6x6_flat_to_arr(
    input logic [DATA_W*36-1:0] flat,
    output logic signed [DATA_W-1:0] arr [0:5][0:5]
  );
    int r,c;
    begin
      for (r=0;r<6;r=r+1) for (c=0;c<6;c=c+1)
        arr[r][c] = flat[(r*6+c)*DATA_W +: DATA_W];
    end
  endfunction

  // -------------------------------
  // Test procedure
  // -------------------------------
  integer i, testnum;
  initial begin
    // reset
    rst_n = 0;
    pc_valid_in = 0; posta_valid_in = 0;
    pdeconv_valid_in = 0; postd_valid_in = 0;
    gwt_valid_in = 0;
    pc_in_flat = '0; posta_in_flat = '0;
    pdeconv_in_flat = '0; postd_in_flat = '0;
    gwt_in_flat = '0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // tests per module
    int tests_per_module = 10;
    int failures = 0;

    // ---- preta_conv_flat tests ----
    $display("=== Testing preta_conv_flat (4x4 -> 4x4) ===");
    for (testnum=0; testnum<tests_per_module; testnum++) begin
      // generate deterministic pseudo-random inputs
      logic signed [DATA_W-1:0] Xin [0:3][0:3];
      for (i=0;i<16;i=i+1) begin
        // create varied signed test vectors (range -1024..1023)
        int val = $urandom_range(-1024,1023);
        Xin[i/4][i%4] = val;
        pc_in_flat[(i)*DATA_W +: DATA_W] = Xin[i/4][i%4];
      end
      // compute golden
      logic signed [ACC_W_CONV-1:0] Ygold [0:3][0:3];
      golden_preta_conv(Xin, Ygold);

      // drive module
      pc_valid_in <= 1;
      @(posedge clk);
      pc_valid_in <= 0;

      // wait one cycle for registered output
      @(posedge clk);
      if (pc_valid_out !== 1) begin
        $display("WARNING: pc_valid_out not asserted as expected.");
      end

      // read module output into local array
      logic signed [ACC_W_CONV-1:0] Ymod [0:3][0:3];
      for (i=0;i<16;i=i+1) begin
        Ymod[i/4][i%4] = pc_out_flat[(i)*ACC_W_CONV +: ACC_W_CONV];
      end

      // compare
      int local_fail = 0;
      for (i=0;i<4;i=i+1) begin
        for (int j=0;j<4;j=j+1) begin
          if (Ymod[i][j] !== Ygold[i][j]) begin
            $display("preta_conv mismatch at test %0d pos[%0d,%0d] : got %0d expected %0d",
                      testnum, i, j, Ymod[i][j], Ygold[i][j]);
            local_fail++;
          end
        end
      end
      if (local_fail==0) $display("preta_conv test %0d PASS", testnum);
      else begin
        $display("preta_conv test %0d FAIL (%0d mismatches)", testnum, local_fail);
        failures += local_fail;
      end
      repeat(1) @(posedge clk);
    end

    // ---- posta_conv_flat tests ----
    $display("=== Testing posta_conv_flat (4x4 -> 2x2) ===");
    for (testnum=0; testnum<tests_per_module; testnum++) begin
      logic signed [DATA_W-1:0] Uin [0:3][0:3];
      for (i=0;i<16;i=i+1) begin
        int val = $urandom_range(-1024,1023);
        Uin[i/4][i%4] = val;
        posta_in_flat[i*DATA_W +: DATA_W] = Uin[i/4][i%4];
      end
      logic signed [ACC_W_CONV-1:0] Vgold [0:1][0:1];
      golden_posta_conv(Uin, Vgold);
      posta_valid_in <= 1;
      @(posedge clk);
      posta_valid_in <= 0;
      @(posedge clk);
      if (posta_valid_out !== 1) $display("WARNING: posta_valid_out not asserted");
      logic signed [ACC_W_CONV-1:0] Vmod [0:1][0:1];
      for (i=0;i<4;i=i+1) Vmod[i/2][i%2] = posta_out_flat[i*ACC_W_CONV +: ACC_W_CONV];
      int local_fail = 0;
      for (i=0;i<2;i=i+1) for (int j=0;j<2;j=j+1) if (Vmod[i][j] !== Vgold[i][j]) begin
        $display("posta_conv mismatch test %0d pos[%0d,%0d]: got %0d exp %0d", testnum, i, j, Vmod[i][j], Vgold[i][j]);
        local_fail++;
      end
      if (local_fail==0) $display("posta_conv test %0d PASS", testnum);
      else begin $display("posta_conv test %0d FAIL (%0d)", testnum, local_fail); failures+=local_fail; end
      repeat(1) @(posedge clk);
    end

    // ---- preta_deconv_flat tests ----
    $display("=== Testing preta_deconv_flat (4x4 -> 6x6) ===");
    for (testnum=0; testnum<tests_per_module; testnum++) begin
      logic signed [DATA_W-1:0] Xin [0:3][0:3];
      for (i=0;i<16;i=i+1) begin
        int val = $urandom_range(-512,511); // smaller range
        Xin[i/4][i%4] = val;
        pdeconv_in_flat[i*DATA_W +: DATA_W] = Xin[i/4][i%4];
      end
      logic signed [ACC_W_DECONV-1:0] Ygold [0:5][0:5];
      golden_preta_deconv(Xin, Ygold);
      pdeconv_valid_in <= 1;
      @(posedge clk);
      pdeconv_valid_in <= 0;
      @(posedge clk);
      logic signed [ACC_W_DECONV-1:0] Ymod [0:5][0:5];
      for (i=0;i<36;i=i+1) Ymod[i/6][i%6] = pdeconv_out_flat[i*ACC_W_DECONV +: ACC_W_DECONV];
      int local_fail = 0;
      for (i=0;i<6;i=i+1) for (int j=0;j<6;j=j+1) if (Ymod[i][j] !== Ygold[i][j]) begin
        $display("preta_deconv mismatch test %0d pos[%0d,%0d]: got %0d exp %0d", testnum, i, j, Ymod[i][j], Ygold[i][j]);
        local_fail++;
      end
      if (local_fail==0) $display("preta_deconv test %0d PASS", testnum);
      else begin $display("preta_deconv test %0d FAIL (%0d)", testnum, local_fail); failures+=local_fail; end
      repeat(1) @(posedge clk);
    end

    // ---- posta_deconv_flat tests ----
    $display("=== Testing posta_deconv_flat (6x6 -> 4x4) ===");
    for (testnum=0; testnum<tests_per_module; testnum++) begin
      logic signed [DATA_W-1:0] Uin [0:5][0:5];
      for (i=0;i<36;i=i+1) begin
        int val = $urandom_range(-256,255);
        Uin[i/6][i%6] = val;
        postd_in_flat[i*DATA_W +: DATA_W] = Uin[i/6][i%6];
      end
      logic signed [ACC_W_POST_DECONV-1:0] Vgold [0:3][0:3];
      golden_posta_deconv(Uin, Vgold);
      postd_valid_in <= 1;
      @(posedge clk);
      postd_valid_in <= 0;
      @(posedge clk);
      logic signed [ACC_W_POST_DECONV-1:0] Vmod [0:3][0:3];
      for (i=0;i<16;i=i+1) Vmod[i/4][i%4] = postd_out_flat[i*ACC_W_POST_DECONV +: ACC_W_POST_DECONV];
      int local_fail = 0;
      for (i=0;i<4;i=i+1) for (int j=0;j<4;j=j+1) if (Vmod[i][j] !== Vgold[i][j]) begin
        $display("posta_deconv mismatch test %0d pos[%0d,%0d]: got %0d exp %0d", testnum, i, j, Vmod[i][j], Vgold[i][j]);
        local_fail++;
      end
      if (local_fail==0) $display("posta_deconv test %0d PASS", testnum);
      else begin $display("posta_deconv test %0d FAIL (%0d)", testnum, local_fail); failures+=local_fail; end
      repeat(1) @(posedge clk);
    end

    // ---- gdeconv_weight_transform_flat tests ----
    $display("=== Testing gdeconv_weight_transform_flat (4x4 -> 6x6) ===");
    for (testnum=0; testnum<tests_per_module; testnum++) begin
      logic signed [DATA_W-1:0] Win [0:3][0:3];
      for (i=0;i<16;i=i+1) begin
        int val = $urandom_range(-128,127);
        Win[i/4][i%4] = val;
        gwt_in_flat[i*DATA_W +: DATA_W] = Win[i/4][i%4];
      end
      logic signed [ACC_W_GW-1:0] Wgold [0:5][0:5];
      golden_gdeconv_weight(Win, Wgold);
      gwt_valid_in <= 1;
      @(posedge clk);
      gwt_valid_in <= 0;
      @(posedge clk);
      logic signed [ACC_W_GW-1:0] Wmod [0:5][0:5];
      for (i=0;i<36;i=i+1) Wmod[i/6][i%6] = gwt_out_flat[i*ACC_W_GW +: ACC_W_GW];
      int local_fail = 0;
      for (i=0;i<6;i=i+1) for (int j=0;j<6;j=j+1) if (Wmod[i][j] !== Wgold[i][j]) begin
        $display("gwt mismatch test %0d pos[%0d,%0d]: got %0d exp %0d", testnum, i, j, Wmod[i][j], Wgold[i][j]);
        local_fail++;
      end
      if (local_fail==0) $display("gwt test %0d PASS", testnum);
      else begin $display("gwt test %0d FAIL (%0d)", testnum, local_fail); failures+=local_fail; end
      repeat(1) @(posedge clk);
    end

    // Summary
    if (failures == 0) $display("ALL TRANSFORM TESTS PASSED");
    else $display("TRANSFORM TESTS FAILED: total mismatches = %0d", failures);

    $finish;
  end

endmodule
