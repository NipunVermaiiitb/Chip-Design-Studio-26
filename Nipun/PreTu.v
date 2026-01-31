module PreTu #(
    parameter int A_bits = 12,
    parameter int W_bits = 16
)(
    input  logic mode, // mode=1 -> Rfconv
    input  logic signed [A_bits-1:0] tile_row [3:0],
    output logic signed [A_bits-1:0] output_row_rf [3:0],
    output logic signed [A_bits-1:0] output_row_de [5:0]
);

    always_comb begin
        // defaults (important!)
        for (int i = 0; i < 4; i++) output_row_rf[i] = '0;
        for (int i = 0; i < 6; i++) output_row_de[i] = '0;

        if (mode) begin
            output_row_rf[0] = tile_row[0] - tile_row[2];
            output_row_rf[1] = tile_row[1] + tile_row[2];
            output_row_rf[2] = tile_row[2] - tile_row[1];
            output_row_rf[3] = tile_row[1] - tile_row[3];
        end
        else begin
            output_row_de[0] = tile_row[0] - tile_row[1];
            output_row_de[1] = tile_row[1];
            output_row_de[2] = tile_row[2] - tile_row[1];
            output_row_de[3] = tile_row[1] - tile_row[2];
            output_row_de[4] = tile_row[2];
            output_row_de[5] = tile_row[3] - tile_row[2];
        end
    end

endmodule
//Make sure that output is A_bits wide only.