module PreTa #(
    parameter int A_bits = 12
)(
    input logic mode,
    input logic [A_bits-1:0] tile[0:3][0:3],//[row][col]
    output logic [A_bits-1:0] output_tile_rf[0:3][0:3],
    output logic [A_bits-1:0] output_tile_de[0:5][0:5]
);
logic [A_bits-1:0] layer1_matrix[0:5][0:3];
logic [A_bits-1:0] temporary_rf[0:3][0:3];
logic [A_bits-1:0] temporary_de[0:3][0:5];//Row wise write in temporary then column wise in layer1 tile
    PreTu P0(
        .mode(mode),
        .tile_row(tile[0]),
        .output_row_rf(temporary_rf[0]),
        .output_row_de(temporary_de[0])
    );
    assign layer1_matrix[0][0]=temporary_rf[0][0] | temporary_de[0][0];    //Since depending on the mode either one of them will be 0
    assign layer1_matrix[1][0]=temporary_rf[0][1] | temporary_de[0][1];
    assign layer1_matrix[2][0]=temporary_rf[0][2] | temporary_de[0][2];
    assign layer1_matrix[3][0]=temporary_rf[0][3] | temporary_de[0][3];
    assign layer1_matrix[4][0]=temporary_de[0][4];
    assign layer1_matrix[5][0]=temporary_de[0][5];
    PreTu P1(
        .mode(mode),
        .tile_row(tile[1]),
        .output_row_rf(temporary_rf[1]),
        .output_row_de(temporary_de[1])
    );
    assign layer1_matrix[0][1]=temporary_rf[1][0] | temporary_de[1][0];
    assign layer1_matrix[1][1]=temporary_rf[1][1] | temporary_de[1][1];
    assign layer1_matrix[2][1]=temporary_rf[1][2] | temporary_de[1][2];
    assign layer1_matrix[3][1]=temporary_rf[1][3] | temporary_de[1][3];
    assign layer1_matrix[4][1]=temporary_de[1][4];
    assign layer1_matrix[5][1]=temporary_de[1][5];

    PreTu P2(
        .mode(mode),
        .tile_row(tile[2]),
        .output_row_rf(temporary_rf[2]),
        .output_row_de(temporary_de[2])
    );
    assign layer1_matrix[0][2]=temporary_rf[2][0] | temporary_de[2][0];
    assign layer1_matrix[1][2]=temporary_rf[2][1] | temporary_de[2][1];
    assign layer1_matrix[2][2]=temporary_rf[2][2] | temporary_de[2][2];
    assign layer1_matrix[3][2]=temporary_rf[2][3] | temporary_de[2][3];
    assign layer1_matrix[4][2]=temporary_de[2][4];
    assign layer1_matrix[5][2]=temporary_de[2][5];

    PreTu P3(
        .mode(mode),
        .tile_row(tile[3]),
        .output_row_rf(temporary_rf[3]),
        .output_row_de(temporary_de[3])
    );
    assign layer1_matrix[0][3]=temporary_rf[3][0] | temporary_de[3][0];
    assign layer1_matrix[1][3]=temporary_rf[3][1] | temporary_de[3][1];
    assign layer1_matrix[2][3]=temporary_rf[3][2] | temporary_de[3][2];
    assign layer1_matrix[3][3]=temporary_rf[3][3] | temporary_de[3][3];
    assign layer1_matrix[4][3]=temporary_de[3][4];
    assign layer1_matrix[5][3]=temporary_de[3][5];
        //layer 1 done
PreTu P4(
        .mode(mode),
        .tile_row(layer1_matrix[0]),
        .output_row_rf(output_tile_rf[0]),
        .output_row_de(output_tile_de[0])
    );
PreTu P5(
        .mode(mode),
        .tile_row(layer1_matrix[1]),
        .output_row_rf(output_tile_rf[1]),
        .output_row_de(output_tile_de[1])
    );

PreTu P6(
        .mode(mode),
        .tile_row(layer1_matrix[2]),
        .output_row_rf(output_tile_rf[2]),
        .output_row_de(output_tile_de[2])
    );
    
PreTu P7(
        .mode(mode),
        .tile_row(layer1_matrix[3]),
        .output_row_rf(output_tile_rf[3]),
        .output_row_de(output_tile_de[3])
    );
    
PreTu P8(
        .mode(mode),
        .tile_row(layer1_matrix[4]),
        .output_row_rf(),//Not needed
        .output_row_de(output_tile_de[4])
    );
        
PreTu P9(
        .mode(mode),
        .tile_row(layer1_matrix[5]),
        .output_row_rf(),//Not needed
        .output_row_de(output_tile_de[5])
    );
endmodule