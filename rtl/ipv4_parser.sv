module ipv4_parser(
    input logic clk,
    input logic rst_n,

    // axi4-stream input
    input logic [511:0] axis_input_tdata, // data
    input logic axis_input_tvalid,
    input logic axis_input_tlast, // last beat of the packet
    input logic [63:0] axis_input_tkeep, // which tdata bytes are valid
    input logic is_ipv4, // will come from ethernet_parser.sv

    // ipv4 fields we parsed
    output logic ipv4_valid, // 1 if fields valid and IHL == 5 (20 byte header)
    output logic [15:0] ip_total_length, // total field length including header and payload
    output logic [31:0] ip_source_address,
    output logic [31:0] ip_destination_address,
    output logic [7:0] ip_header_bytes, // IHL * 4
    output logic [15:0] udp_offset, // byte offset from start of packet to udp/l4 header

    //axi-4 stream output
    output logic [511:0] output_tdata,
    output logic output_tvalid,
    output logic output_tlast,
    output logic [63:0] output_tkeep,
    input logic output_tready // backpressure from downstream
);

    // ethernet header made of 14 bytes = 112 bits
    // 6 for destination mac, 6 for source mac, 2 for ethertype
    localparam int unsigned ETHERNET_HEADER_BITS = 112;

    // fsm
    typedef enum logic [1:0] {
        IDLE = 2'd0, // waiting for start of packet
        FIRST_BEAT = 2'd1, // got first beat and latched the header
        PASSTHROUGH = 2'd2 // passing through remaining beats
    } state_t;

    state_t state; // curr state

    // s0 = stage 0: just received from input
    // s1 = stage 1: about to send to output
    logic [511:0] s0_data, s1_data; // data regs
    logic s0_valid, s1_valid;
    logic s0_last, s1_last; // last beat flags
    logic [63:0] s0_keep, s1_keep; // valid bytes

    // regs for holding ipv4 header info for current packet
    logic r_ipv4_valid; // 1 if successfully parsed a valid ipv4 header
    logic [15:0] r_total_length; // ip packet length in bytes
    logic [31:0] r_source_address;
    logic [31:0] r_destination_address;
    logic [7:0] r_header_bytes; // ip header size in bytes
    logic [15:0] r_udp_offset; // byte offset to udp/tcp/l4 header

    // IPv4 header layout (first 20 bytes):
    // Byte 0: Version (4 bits) + IHL (4 bits)
    // Byte 1: DSCP + ECN
    // Bytes 2-3: Total Length
    // Bytes 4-7: Identification, flags, fragment offset
    // Byte 8: TTL
    // Byte 9: Protocol
    // Bytes 10-11: Header Checksum
    // Bytes 12-15: Source IP
    // Bytes 16-19: Destination IP

    // Version+IHL : tdata[119:112] (IP byte 0)
    // Total Length : tdata[135:120] (IP bytes 2-3)
    // Source IP : tdata[207:176] (IP bytes 12-15)
    // Destination IP : tdata[239:208] (IP bytes 16-19)

    // extract the version+ihl byte (7:0 of the ipv4 header)
    wire [7:0] in_version_ihl = axis_input_tdata[ETHERNET_HEADER_BITS +: 8];

    // ihl is the lower 4 bits of the above byte
    wire [3:0] in_ihl = in_version_ihl[3:0];

    // total length is bytes 2-3 of the ipv4 header
    wire [15:0] in_total_length = axis_input_tdata[ETHERNET_HEADER_BITS + 16 +: 16];

    // source ip address is bytes 12-15 of the ipv4 header
    wire [31:0] in_source_address = axis_input_tdata[ETHERNET_HEADER_BITS + 96 +:32];

    // destination ip address is bytes 16-19 of the ipv4 header
    wire [31:0] in_destination_address = axis_input_tdata[ETHERNET_HEADER_BITS + 128 +: 32];

    // ihl=5 is a no options 20 byte header
    wire in_ihl_ok = (in_ihl == 4'd5);

    // handshake for axi4-stream control
    wire go = axis_input_tvalid & output_tready;

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
            r_ipv4_valid <= 0;
            r_total_length <= '0;
            r_source_address <= '0;
            r_destination_address <= '0;
            r_header_bytes <= '0;
            r_udp_offset <= '0;
        end else begin
            // 2-stage pipeline
            // only advance when downstream is ready to prevent data loss
            if (output_tready) begin
                // stage 1 gets stage 0
                // stage 0 gets new input data
                s1_data <= s0_data;
                s1_valid <= s0_valid;
                s1_last <= s0_last;
                s1_keep <= s0_keep;

                s0_data <= axis_input_tdata;
                s0_valid <= axis_input_tvalid;
                s0_last <= axis_input_tlast;
                s0_keep <= axis_input_tkeep;
            end
            //fsm behavior
            case (state)
                IDLE: begin
                    // wait for the start of a packet
                    // only act when input is valid and output is ready
                    if (go) begin
                        if (is_ipv4) begin
                            // parse if ipv4 packet
                            // swap bytes since network is big endian to convert to little endian for storage
                            r_total_length <= {in_total_length[7:0], in_total_length[15:8]};
                            
                            // store source ip and destination ip and swap each byte for little endian
                            r_source_address <= {in_source_address[7:0], in_source_address[15:8], in_source_address[23:16], in_source_address[31:24]};
                            r_destination_address <= {in_destination_address[7:0], in_destination_address[15:8], in_destination_address[23:16], in_destination_address[31:24]};

                            r_header_bytes <= {in_ihl, 2'b00}; // ihl * 4 to find ip header size in bytes

                            // ethernet header (14 bytes) + ip header size to find udp/l4 header in bytes from start of packet
                            r_udp_offset <= 16'd14 + {8'd0, {in_ihl, 2'b00}}; // 14  + (ihl * 4)

                            // check if ihl is 5
                            r_ipv4_valid <= in_ihl_ok;
                        end else begin
                            // not an ipv4 packet so just clear everything
                            r_ipv4_valid <= 1'b0;
                            r_total_length <= '0;
                            r_source_address <= '0;
                            r_destination_address <= '0;
                            r_header_bytes <= '0;
                            r_udp_offset <= '0;
                        end
                        // next state logic
                        if (axis_input_tlast) state <= IDLE; // off case we get a single beat packet
                        else state <= FIRST_BEAT; // need more beats
                    end
                end

                FIRST_BEAT: begin
                    // header has been latched from beat 0
                    // need beat 1 before moving to next state
                    // some packets could have a header split across beats
                    if (go) state <= axis_input_tlast ? IDLE : PASSTHROUGH;
                end

                PASSTHROUGH: begin
                    // just need to forard the remaining beats
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

    // status outputs (header info)
    assign ipv4_valid = r_ipv4_valid;
    assign ip_total_length = r_total_length;
    assign ip_source_address = r_source_address;
    assign ip_destination_address = r_destination_address;
    assign ip_header_bytes = r_header_bytes;
    assign udp_offset = r_udp_offset;
endmodule