module timestamp_insert(
    input logic clk,
    input logic rst_n,

    // axi4-stream input
    input logic [511:0] axis_input_tdata, // data
    input logic axis_input_tvalid,
    input logic axis_input_tlast, // last beat of the packet
    input logic [63:0] axis_input_tkeep, // which tdata bytes are valid

    // timestamp insertion control
    input logic [63:0] timestamp, // timestamp value to insert
    input logic udp_valid, // valid udp frame to insert into if 1
    input logic [15:0] payload_offset, // byte offset to where to insert (udp payload)
    input logic enable, // enable for timestamp insert

    //axi-4 stream output
    output logic [511:0] output_tdata,
    output logic output_tvalid,
    output logic output_tlast,
    output logic [63:0] output_tkeep,
    input logic output_tready, // backpressure from downstream

    output logic timestamp_span_beat // 1 if timestamp crosses beat boundary
);

    // fsm
    typedef enum logic [0:0] {
        IDLE = 1'd0, // wait for start of packet (could insert timestamp on first beat)
        PASSTHROUGH = 1'd1 // just forward rest of the beats
    } state_t;

    state_t state; // curr state

    // s0 = stage 0: just received from input
    // s1 = stage 1: about to send to output
    logic [511:0] s0_data, s1_data; // data regs
    logic s0_valid, s1_valid;
    logic s0_last, s1_last; // last beat flags
    logic [63:0] s0_keep, s1_keep; // valid bytes

    // position timestamp at correct byte offset
    // overwrite the first 8 bytes of udp payload
    // payload_offset = where udp payload starts in bytes
    // then multiply by 8 for bits
    wire [511:0] timestamp_placed = ({448'd0, timestamp}) << (payload_offset * 8);

    // mask to clear the 64 bits the timestamp will go in
    wire [511:0] timestamp_mask = ({448'd0, 64'hFFFF_FFFF_FFFF_FFFF}) << (payload_offset * 8);

    // preserve data while inserting timestamp by clearing target bits with the above mask then OR in the timestamp
    wire [511:0] inserted = (axis_input_tdata & ~timestamp_mask) | timestamp_placed;


    // detect if timestamp passes a boundary
    // payload_offset + 8 > 64 bytes: span two beats
    assign timestamp_span_beat = (payload_offset + 16'd8 > 16'd64);

    // conditions for insert:
    // enable is high
    // udp_valid high
    // timestamp does not span beat boundary
    wire ok_insert = enable & udp_valid & ~timestamp_span_beat;

    // handshake to go when input valid and downstream ready   
    wire go = axis_input_tvalid & output_tready;

    // fsm datapath
    always_ff @(posedge clk or negedge rst_n) begin
        // reset everything
        if (!rst_n) begin
            state <= IDLE;
            s0_data <= '0;
            s0_valid <= 0;
            s0_last <= 0;
            s0_keep <= '0;
            s1_data <= '0;
            s1_valid <= 0;
            s1_last <= 0;
            s1_keep <= '0;
        end else begin
            // 2 stage pipeline
            // only advance once the output is consumed
            if (output_tready) begin
                // stage 1 gets stage 0
                s1_data <= s0_data;
                s1_valid <= s0_valid;
                s1_last <= s0_last;
                s1_keep <= s0_keep;

                // stage 0 gets new input data
                // if idle and we should insert, use modified 'inserted' data instead of raw input
                if (state == IDLE && ok_insert)
                    s0_data <= inserted;
                else
                    s0_data <= axis_input_tdata;

                s0_valid <= axis_input_tvalid;
                s0_last <= axis_input_tlast;
                s0_keep <= axis_input_tkeep;
            end

            // fsm behavior
            case (state)
                IDLE: begin
                    // wait for start of packet
                    // if go, transition
                    // if last beat go back to idle, otherwise go to passthrough                    
                    if (go) state <= axis_input_tlast ? IDLE : PASSTHROUGH;
                end
                PASSTHROUGH: begin
                    // just forward the rest of the beats
                    if (go) state <= axis_input_tlast ? IDLE : PASSTHROUGH;
                end
                default: state <= IDLE;
            endcase
        end
    end

    // output stuff
    // datapath outputs from stage 1 (just forwarding stuff)
    assign output_tdata = s1_data;
    assign output_tvalid = s1_valid;
    assign output_tlast = s1_last;
    assign output_tkeep = s1_keep;
endmodule