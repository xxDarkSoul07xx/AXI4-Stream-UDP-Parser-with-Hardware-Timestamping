module ethernet_parser(
    input logic clk,
    input logic rst_n,

    // axi-stream input
    input logic [511:0] axis_input_tdata, // 512 bits of data per cycle
    input logic axis_input_tvalid, // valid
    input logic axis_input_tlast, // last packet
    input logic [63:0] axis_input_tkeep, // which bytes are valid
    input logic parsing_enable, // parse Ethernet headers when 1
    output logic [47:0] ethernet_destination_mac, // destination mac address
    output logic [47:0] ethernet_source_mac, // source mac address
    output logic [15:0] ethernet_type, // ethertype field
    output logic ethernet_valid, // 1 when above are valid
    output logic is_ipv4, // ipv4
    output logic bypass, // packet should bypass processing when high
 
    //axi-stream output
    output logic [511:0] output_tdata, // data out
    output logic output_tvalid, // output data valid
    output logic output_tlast, // last of output packet
    output logic [63:0] output_tkeep, // which output bytes are valid
    input  logic output_tready // back-pressure from downstream
);

    // fsm
    typedef enum logic [1:0] {
        IDLE = 2'd0, // waiting for a packet
        PASSTHROUGH = 2'd1, // passing through a packet
        BYPASS = 2'd2 // bypassing non-ipv4 packets
    } state_t;

    state_t state; // curr state

    // pipeline regs
    logic [511:0] s0_data, s1_data; // stage 0 and stage 1 data
    logic s0_valid, s1_valid;
    logic s0_last, s1_last;
    logic [63:0] s0_keep, s1_keep;

    // regs for holding header info
    logic [47:0] r_destination_mac, r_source_mac; // mac addresses
    logic [15:0] r_ethertype;
    logic r_ethernet_valid, r_is_ipv4, r_bypass; // status stuff

    // back-pressure flow control
    // input is valid and output is ready to accept
    wire go = axis_input_tvalid & output_tready;

    // decode header from current input
    // ethernet header bytes format:
    // 0-5: destination mac
    // 6-11: source mac
    // 12-13: ethertype
    wire [47:0] in_destination = axis_input_tdata[47:0]; // destination mac
    wire [47:0] in_source = axis_input_tdata[95:48]; // source mac
    wire [15:0] in_type = axis_input_tdata[111:96]; // ethertype
    wire in_ipv4 = (in_type == 16'h0800); // check if ipv4

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // reset regs to zero
            state <= IDLE;
            s0_data <= '0;
            s0_valid <= 1'b0;
            s0_last <= 1'b0;
            s0_keep <= '0;
            s1_data <= '0;
            s1_valid <= 1'b0;
            s1_last <= 1'b0;
            s1_keep <= '0;
            r_destination_mac <= '0;
            r_source_mac <= '0;
            r_ethertype <= '0;
            r_ethernet_valid <= 1'b0;
            r_is_ipv4 <= 1'b0;
            r_bypass <= 1'b0;
        end else begin
            // 2 stage pipeline
            // advance when downstream ready
            // prevent data loss when output_tready low
            // transfer s0 to s1, then give s0 new data
            if (output_tready) begin
                s1_data <= s0_data;
                s1_valid <= s0_valid;
                s1_last <= s0_last;
                s1_keep <= s0_keep;

                s0_data <= axis_input_tdata;
                s0_valid <= axis_input_tvalid;
                s0_last <= axis_input_tlast;
                s0_keep <= axis_input_tkeep;
            end
            
            // fsm logic
            case(state)
                IDLE: begin
                    // only do something if input is valid and output is ready
                    if (go) begin
                        if (parsing_enable) begin
                            // go through the header
                            r_destination_mac <= in_destination;
                            r_source_mac <= in_source;
                            r_ethertype <= in_type;
                            r_is_ipv4 <= in_ipv4;
                            r_ethernet_valid <= 1'b1;
                            r_bypass <= ~in_ipv4; // if it's ipv4, don't bypass it

                            if (axis_input_tlast) state <= IDLE; // single beat packet (probably not going to happen)
                            else if (in_ipv4) state <= PASSTHROUGH; // ipv4
                            else state <= BYPASS; // not ipv4
                        end else begin
                            // no parsing so just bypass everything
                            r_ethernet_valid <= 1'b0;
                            r_is_ipv4 <= 1'b0;
                            r_bypass <= 1'b1;

                            if (axis_input_tlast) state <= IDLE;
                            else state <= BYPASS;
                        end
                    end
                end

                PASSTHROUGH: begin
                    // just go through the ipv4 packet
                    if (go) state <= axis_input_tlast ? IDLE : PASSTHROUGH; // on the last beat, go to idle otherwise stay in passthrough
                end

                BYPASS: begin
                    // bypass non-ipv4
                    if (go) state <= axis_input_tlast ? IDLE : BYPASS; // same as passthrough
                end
                
                default: state <= IDLE;
            endcase
        end
    end

    // datapath outputs
    // just forwarding data from stage 1
    assign output_tdata = s1_data;
    assign output_tvalid = s1_valid;
    assign output_tlast = s1_last;
    assign output_tkeep = s1_keep;

    // status outputs
    // just forwarding the header info
    assign ethernet_destination_mac = r_destination_mac;
    assign ethernet_source_mac = r_source_mac;
    assign ethernet_type = r_ethertype;
    assign ethernet_valid = r_ethernet_valid;
    assign is_ipv4 = r_is_ipv4;
    assign bypass = r_bypass;
endmodule