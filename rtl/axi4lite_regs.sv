import udp_parser_package::*;

// udp_parser_package reg map:
// 0x00: CONTROL, RW, [0] = ENABLE
// 0x04: STATUS, RO, [0] = FIFO_FULL, [1] = PKT_DROPPED (sticky)
// 0x08: DST_PORT_FILTER, RW, [15:0] = DESTINATION_PORT_FILTER (0 = pass all)
// 0x0C: TIMESTAMP_LOW, RO, [31:0] = TIMESTAMP[31:0]
// 0x10: TIMESTAMP_HIGH, RO, [31:0] = TIMESTAMP[63:32]
// 0x14: PKT_COUNT, RO, [31:0] = PACKETS_FORWARDED
// 0x18: DROP_COUNT, RO, [31:0] = PACKETS_DROPPED

module axi4lite_regs(
    // axi-4lite clock and reset
    input logic s_axi_aclk,
    input logic s_axi_arestn,

    // write channel - aw
    input logic [31:0] s_axi_awaddr, // write address
    input logic s_axi_awvalid, // write address valid
    output logic s_axi_awready, // write address ready

    // write data channel - w
    input logic [31:0] s_axi_wdata, // write data
    input logic [3:0] s_axi_wstrb, // which bytes to write (strobes)
    input logic s_axi_wvalid, // write data valid
    output logic s_axi_wready, // write data ready

    // write response channel - b
    output logic [1:0] s_axi_bresp, // write response either OKAY or SLVERR
    output logic s_axi_bvalid, // write response valid
    input logic s_axi_bready, // write response ready

    // read address channel - ar
    input logic [31:0] s_axi_araddr, // read address
    input logic s_axi_arvalid, // read address valid
    output logic s_axi_arready, // read address ready

    // read data channel - r
    output logic [31:0] s_axi_rdata, // read data
    output logic [1:0] s_axi_rresp, // read response either OKAY or SLVERR
    output logic s_axi_rvalid, // read data valid
    input logic s_axi_rready, // read data ready

    // outputs to pipeline
    output logic reg_enable, // global enable for udp parser
    output logic [15:0] reg_destination_port_filter, // destination port for filtering

    // inputs from pipeline
    input logic [63:0] status_timestamp, // curr timestamp from counter
    input logic [31:0] status_packet_count, // number of packets forwarded
    input logic [31:0] status_drop_count,// number of packets dropped
    input logic status_fifo_full, // fifo full status
    input logic status_packet_dropped // pulse that packet was dropped
);

    // axi4-lite response codes
    localparam logic [1:0] AXI_OKAY = 2'b00; // normal
    localparam logic [1:0] AXI_SLVERR = 2'b10; // error

    // rw reg storage
    logic [31:0] reg_control; // control register (bit 0 = enable)
    logic [31:0] reg_destination_port; // destination_port_filter register (will use lower 16 bits)

    // status sticky bits to remember that a packet was dropped since last ready
    logic sticky_packet_dropped;

    // write channel state
    // track that aw and w has been received, then issue b response
    logic aw_done; // aw accepted
    logic w_done; // w accepted
    logic [7:0] wr_addr_latch; // latched write address
    logic [31:0] wr_data_latch; // latched write data
    logic [3:0] wr_strb_latch; // latched write strobes

    // read channel state
    logic r_valid; // read data valid
    logic [31:0] r_data; // read data to return

    // output stuff
    assign reg_enable = reg_control[CONTROL_ENABLE_BIT];
    assign reg_destination_port_filter = reg_destination_port[15:0];
    assign s_axi_bresp = AXI_OKAY;
    assign s_axi_rresp = AXI_OKAY;
    assign s_axi_rdata = r_data;
    assign s_axi_rvalid = r_valid;

    // status reg for live inputs and sticky
    //                                  [1]                        [0]
    wire [31:0] status_reg = {30'd0, sticky_packet_dropped, status_fifo_full};

    // read data mux
    function automatic logic [31:0] reg_read(
        input logic [7:0] address
    );
        case(address)
            REGISTER_CONTROL: return reg_control;
            REGISTER_STATUS: return status_reg;
            REGISTER_DESTINATION_PORT_FILTER: return reg_destination_port;
            REGISTER_TIMESTAMP_LOW: return status_timestamp[31:0];
            REGISTER_TIMESTAMP_HIGH: return status_timestamp[63:32];
            REGISTER_PACKET_COUNT: return status_packet_count;
            REGISTER_DROPPED_COUNT: return status_drop_count;
            default: return 32'hDEAD_BEEF;
        endcase
    endfunction

    // write data with byte strobes
    function automatic logic [31:0] apply_strobe(
        input logic [31:0] current,
        input logic [31:0] wdata,
        input logic [3:0] strobe
    );
        logic [31:0] result;
        result = current;
        if (strobe[0]) result[7:0] = wdata[7:0];
        if (strobe[1]) result[15:8] = wdata[15:8];
        if (strobe[2]) result[23:16] = wdata[23:16];
        if (strobe[3]) result[31:24] = wdata[31:24];
        return result;
    endfunction

    // aw channel
    always @(posedge s_axi_aclk or negedge s_axi_arestn) begin
        if (!s_axi_arestn) begin
            s_axi_awready <= 1'b0;
            aw_done <= 1'b0;
            wr_addr_latch <= '0;
        end else begin
            if (s_axi_awvalid && !aw_done) begin
                s_axi_awready <= 1'b1;
                wr_addr_latch <= s_axi_awaddr[7:0];
                aw_done <= 1'b1;
            end else begin
                s_axi_awready <= 1'b0;
            end
            if (s_axi_bvalid && s_axi_bready) aw_done <= 1'b0;
        end
    end

    // w channel
    always @(posedge s_axi_aclk or negedge s_axi_arestn) begin
        if (!s_axi_arestn) begin
            s_axi_wready <= 1'b0;
            w_done <= 1'b0;
            wr_data_latch <= '0;
            wr_strb_latch <= '0; 
        end else begin
            if (s_axi_wvalid && !w_done) begin
                s_axi_wready <= 1'b1;
                wr_data_latch <= s_axi_wdata;
                wr_strb_latch <= s_axi_wstrb;
                w_done <= 1'b1;
            end else begin
                s_axi_wready <= 1'b0;
            end
            if (s_axi_bvalid && s_axi_bready) w_done <= 1'b0;
        end
    end

    // b channel (only valid once both aw and w are done)
    always @(posedge s_axi_aclk or negedge s_axi_arestn) begin
        if (!s_axi_arestn) begin
            s_axi_bvalid <= 1'b0;
        end else begin
            if (aw_done && w_done && !s_axi_bvalid) s_axi_bvalid <= 1'b1;
            else if (s_axi_bready) s_axi_bvalid <= 1'b0;
        end
    end

    // register write
    always @(posedge s_axi_aclk or negedge s_axi_arestn) begin
        if (!s_axi_arestn) begin
            reg_control <= 32'd0;
            reg_destination_port <= 32'd0;
        end else begin
            if (aw_done && w_done && !s_axi_bvalid) begin
                case (wr_addr_latch)
                    REGISTER_CONTROL: reg_control <= apply_strobe(reg_control, wr_data_latch, wr_strb_latch);
                    REGISTER_DESTINATION_PORT_FILTER: reg_destination_port <= apply_strobe(reg_destination_port, wr_data_latch, wr_strb_latch);
                    default: ;
                endcase
            end
        end
    end

    // sticky packet dropped bit
    logic [7:0] ar_addr_latch;
    always @(posedge s_axi_aclk or negedge s_axi_arestn) begin
        if (!s_axi_arestn) ar_addr_latch <= '0;
        else if (s_axi_arvalid && !r_valid) ar_addr_latch <= s_axi_araddr[7:0];
    end

    wire status_being_read = s_axi_arvalid && !r_valid && (s_axi_araddr[7:0] == REGISTER_STATUS);
    
    always @(posedge s_axi_aclk or negedge s_axi_arestn) begin
        if (!s_axi_arestn) sticky_packet_dropped <= 1'b0;
        else begin
            if (status_packet_dropped) sticky_packet_dropped <= 1'b1;
            else if (status_being_read) sticky_packet_dropped <= 1'b0;
        end
    end

    // ar and r channel
    always @(posedge s_axi_aclk or negedge s_axi_arestn) begin
        if (!s_axi_arestn) begin
            s_axi_arready <= 1'b0;
            r_valid <= 1'b0;
            r_data <= 32'd0;
        end else begin
            s_axi_arready <= 1'b0;
            if (s_axi_arvalid && !r_valid) begin
                s_axi_arready <= 1'b1;
                r_data <= reg_read(s_axi_araddr[7:0]);
                r_valid <= 1'b1;
            end else if (s_axi_rready && r_valid) r_valid <= 1'b0;
        end
    end
endmodule