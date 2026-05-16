module udp_parser_filter(
    input logic clk,
    input logic rst_n,

    // axi4-stream input
    input logic [511:0] axis_input_tdata, // data
    input logic axis_input_tvalid,
    input logic axis_input_tlast, // last beat of the packet
    input logic [63:0] axis_input_tkeep, // which tdata bytes are valid

    // these will come from upstream parsers (ethernet + ipv4)
    input logic ipv4_valid, // parse udp if this is a 1
    input logic [15:0] udp_offset, // byte offset from packet start to udp header

    // these come from axi4-lite reg file
    input logic [15:0] destination_port_filter, // 0 = pass all the packets
    input logic enable, // enable for filtering

    // parsed udp fields
    output logic udp_valid, // 1 = parsed
    output logic [15:0] udp_source_port, // source port from udp header
    output logic [15:0] udp_destination_port, // destination port from udp header
    output logic [15:0] udp_length, // udp field length including header and payload
    output logic [15:0] payload_offset, // byte offset to udp payload = udp_offset + 8

    // filter decision
    output logic drop_packet, // 1 = drop the packet because of port not matching
    output logic drop_count, // pulse at end of frame when dropped

    //axi-4 stream output
    output logic [511:0] output_tdata,
    output logic output_tvalid,
    output logic output_tlast,
    output logic [63:0] output_tkeep,
    input logic output_tready // backpressure from downstream
);

    // fsm
    typedef enum logic [1:0] {
        IDLE = 2'd0, // wait for start of packet
        PARSE = 2'd1, // parse udp header
        PASS = 2'd2, // forward the rest to the output
        DROP = 2'd3 // consume and drop the remaining beats
    } state_t;

    state_t state; // curr state

    // s0 = stage 0: just received from input
    // s1 = stage 1: about to send to output
    logic [511:0] s0_data, s1_data; // data regs
    logic s0_valid, s1_valid;
    logic s0_last, s1_last; // last beat flags
    logic [63:0] s0_keep, s1_keep; // valid bytes

    // regs to hold udp header info of current packet
    logic r_udp_valid; // 1 if udp header parsed
    logic [15:0] r_source_port; // source port num
    logic [15:0] r_destination_port; // destination port num
    logic [15:0] r_udp_length; // udp length
    logic [15:0] r_payload_offset; // byte offset to udp data
    logic r_drop_packet; // 1 if current packet should be dropped
    logic r_drop_count; // pulse at the end of frame when dropped

    // calculate offset to udp header
    // get max offset within first 64 bytes
    // always safe because ihl = 5: udp_offset=34, 34*8=272 bits, 272+64=336 < 512 
    wire [8:0] udp_bit_base = udp_offset[5:0] * 8;

    // little endian slices from axi-stream
    // udp header bytes format:
    // 0-1: source port
    // 2-3: destination port
    // 4-5: length
    // 6-7: checksum
    wire [15:0] in_source_port_raw = axis_input_tdata[udp_offset * 8 +: 16];
    wire [15:0] in_destination_port_raw = axis_input_tdata[udp_offset * 8 + 16 +: 16];
    wire [15:0] in_udp_length_raw = axis_input_tdata[udp_offset * 8 + 32 +: 16];

    // byte swapped to big endian
    wire [15:0] in_source_port = {in_source_port_raw[7:0], in_source_port_raw[15:8]};
    wire [15:0] in_destination_port = {in_destination_port_raw[7:0], in_destination_port_raw[15:8]};
    wire [15:0] in_udp_length = {in_udp_length_raw[7:0], in_udp_length_raw[15:8]};
    // port filter decision
    // if destination_port_filter is 0: filter disabled and pass everything
    // if in_destination_port == destination_port_filter: pass
    wire port_match = (destination_port_filter == 16'd0) | (in_destination_port == destination_port_filter);

    // handshake
    // only go when valid input and (downstream is ready or dropping or idle)
    wire go = axis_input_tvalid & (output_tready | (state == DROP) | (state == IDLE));

    // fsm datapath
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // reset everything
            state <= IDLE;
            s0_data <= '0;
            s0_valid <= 0;
            s0_last <= 0;
            s0_keep <= '0;
            s1_data <= '0;
            s1_valid <= 0;
            s1_last <= 0;
            s1_keep <= '0;
            r_udp_valid <= 0;
            r_source_port <= '0;
            r_destination_port <= '0;
            r_udp_length <= '0;
            r_payload_offset <= '0;
            r_drop_packet <= '0;
            r_drop_count <= '0;
        end else begin
            // by default just clear the pulse
            r_drop_count <= 1'b0;

            // 2 stage pipeline
            // only advance once the output is consumed
            if (output_tready) begin
                // stage 1 gets stage 0
                s1_data <= s0_data;
                s1_valid <= s0_valid;
                s1_last <= s0_last;
                s1_keep <= s0_keep;

                // stage 0 will only load new input data when not in drop state
                if (state != DROP) begin
                    // normally load the new input
                    s0_data <= axis_input_tdata;
                    s0_valid <= axis_input_tvalid;
                    s0_last <= axis_input_tlast;
                    s0_keep <= axis_input_tkeep;
                end else begin
                    // when dropping, don't forward data
                    s0_data <= '0;
                    s0_valid <= 0;
                    s0_last <= 0;
                    s0_keep <= '0;
                end
            end

            // fsm behavior
            case (state)
                IDLE: begin
                    // wait for the start of a packet
                    if (axis_input_tvalid) begin
                        if (!ipv4_valid) begin
                            // not ipv4 so pass through without udp parsing
                            r_udp_valid <= 1'b0; // there is no udp header to parse
                            r_drop_packet <= 1'b0; // don't drop
                            r_source_port <= '0;
                            r_destination_port <= '0;
                            r_udp_length <= '0;
                            r_payload_offset <= '0;

                            // if there are more beats, go to pass otherwise idle
                            state <= axis_input_tlast ? IDLE : PASS;
                        end else begin
                            // ipv4 so parse the udp header from the first beat
                            r_source_port <= in_source_port;
                            r_destination_port <= in_destination_port;
                            r_udp_length <= in_udp_length;
                            r_payload_offset <= udp_offset + 16'd8; // udp header is 8 bytes

                            if (!enable) begin
                                // filtering not enabled so pass everything
                                r_udp_valid <= 1'b1;
                                r_drop_packet <= 1'b0;
                                state <= axis_input_tlast ? IDLE : PASS;
                            end else if (port_match) begin
                                // destination port matches filter so pass the packet
                                r_udp_valid <= 1'b1;
                                r_drop_packet <= 1'b0;
                                state <= axis_input_tlast ? IDLE : PASS;
                            end else begin
                                // port not matched so drop
                                r_udp_valid <= 1'b0; // not a valid udp packet
                                r_drop_packet <= 1'b1; // mark to drop

                                if (axis_input_tlast) begin
                                    // rare case that we get a single beat frame just pulse drop counter immediately
                                    r_drop_count <= 1'b1;
                                    r_drop_packet <= 1'b0;
                                    state <= IDLE;
                                end else begin
                                    // multi beat frame so go to drop state and consume rest of the beats
                                    state <= DROP;
                                end
                            end
                        end
                    end
                end

                PARSE: begin
                    // forward the rest of the rest of the bytes
                    if (go) state <= axis_input_tlast ? IDLE : PASS;
                end

                PASS: begin
                    // forward the rest of the beats
                    if (go) state <= axis_input_tlast ? IDLE : PASS;
                end

                DROP: begin
                    // consume the input without forwarding and wait for last beat
                    if (axis_input_tvalid) begin
                        if (axis_input_tlast) begin
                            // got to the end of the dropped packet
                            r_drop_count <= 1'b1; // pulse for drop counter
                            r_drop_packet <= 1'b0; // clear drop flag since packet is done
                            state <= IDLE;
                        end
                        // otherwise stay in drop and keep consuming beats
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    // output stuff

    // datapath outputs from stage 1 (just forwarding stuff)
    assign output_tdata = s1_data;
    assign output_tvalid = s1_valid & ~r_drop_packet; // suppress output when dropping
    assign output_tlast = s1_last;
    assign output_tkeep = s1_keep;

    // status output stuff
    assign udp_valid = r_udp_valid;
    assign udp_source_port = r_source_port;
    assign udp_destination_port = r_destination_port;
    assign udp_length = r_udp_length;
    assign payload_offset = r_payload_offset;
    assign drop_packet = r_drop_packet;
    assign drop_count = r_drop_count;
endmodule