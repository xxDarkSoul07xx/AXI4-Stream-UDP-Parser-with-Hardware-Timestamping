module timestamp_counter (
    input logic clk,
    input logic rst_n,
    input logic enable,
    input logic clear, // clear to zero
    output logic [63:0] timestamp // current counter value
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) timestamp <= 0;
        else if (clear) begin
            timestamp <= 0;
        end
        // make sure not maxed out before incrementing
        else if (enable && timestamp != 64'hFFFF_FFFF_FFFF_FFFF) begin
            timestamp <= timestamp + 1;
        end
    end
endmodule