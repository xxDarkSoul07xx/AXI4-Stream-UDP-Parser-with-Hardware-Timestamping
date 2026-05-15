`timescale 1ns/1ps

module ipv4_parser_tb;
    logic clk;
    logic rst_n;
    logic [511:0] axis_input_tdata;
    logic axis_input_tvalid;
    logic axis_input_tlast;
    logic [63:0] axis_input_tkeep;
    logic is_ipv4;
    logic ipv4_valid;
    logic [15:0] ip_total_length;
    logic [31:0] ip_source_address;
    logic [31:0] ip_destination_address;
    logic [7:0] ip_header_bytes;
    logic [15:0] udp_offset;
    logic [511:0] output_tdata;
    logic output_tvalid;
    logic output_tlast;
    logic [63:0] output_tkeep;
    logic output_tready;
    
    ipv4_parser dut (.*);
    
    // 10ns clock (100MHz)
    initial clk = 0;
    always #5 clk = ~clk;
    
    // counters
    int pass_count = 0;
    int fail_count = 0;
    
    task check(input string name, input logic got, input logic exp);
        if (got === exp) begin
            $display("PASS  %-45s  got=%0b", name, got);
            pass_count++;
        end else begin
            $error("FAIL  %-45s  got=%0b  exp=%0b", name, got, exp);
            fail_count++;
        end
    endtask
    
    task check_eq(input string name, input logic [63:0] got, input logic [63:0] exp);
        if (got === exp) begin
            $display("PASS  %-45s  got=0x%016h", name, got);
            pass_count++;
        end else begin
            $error("FAIL  %-45s  got=0x%016h  exp=0x%016h", name, got, exp);
            fail_count++;
        end
    endtask
    
    task tick(input int n = 1);
        repeat(n) @(posedge clk);
        #1;
    endtask
    
    // Build a 512-bit beat containing an Ethernet+IPv4 header
    localparam int ETHERNET_HEADER_BITS = 112;
    
    function automatic logic [511:0] ipv4_beat(
        input logic [3:0]  ihl = 4'd5,
        input logic [15:0] total_len  = 16'd40,
        input logic [31:0] src_ip = 32'hC0A8_0101,
        input logic [31:0] dst_ip = 32'hC0A8_0102,
        input logic [7:0]  fill = 8'hEE
    );
        logic [511:0] b;
        b = {64{fill}};
        
        // Version=4, IHL
        b[ETHERNET_HEADER_BITS +: 8] = {4'd4, ihl};
        
        // Total Length (big-endian in network order)
        b[ETHERNET_HEADER_BITS + 16 +: 8] = total_len[15:8]; // MSB
        b[ETHERNET_HEADER_BITS + 24 +: 8] = total_len[7:0];  // LSB
        
        // Source IP (bytes 28-31)
        b[ETHERNET_HEADER_BITS + 96  +: 8] = src_ip[31:24];
        b[ETHERNET_HEADER_BITS + 104 +: 8] = src_ip[23:16];
        b[ETHERNET_HEADER_BITS + 112 +: 8] = src_ip[15:8];
        b[ETHERNET_HEADER_BITS + 120 +: 8] = src_ip[7:0];
        
        // Destination IP (bytes 32-35)
        b[ETHERNET_HEADER_BITS + 128 +: 8] = dst_ip[31:24];
        b[ETHERNET_HEADER_BITS + 136 +: 8] = dst_ip[23:16];
        b[ETHERNET_HEADER_BITS + 144 +: 8] = dst_ip[15:8];
        b[ETHERNET_HEADER_BITS + 152 +: 8] = dst_ip[7:0];
        
        return b;
    endfunction
    
    // Send one beat; wait for handshake
    task send_beat(
        input logic [511:0] data,
        input logic [63:0] keep = '1,
        input logic last = 1
    );
        @(negedge clk);
        axis_input_tdata = data;
        axis_input_tkeep = keep;
        axis_input_tlast = last;
        axis_input_tvalid = 1;
        @(posedge clk);
        while (!output_tready) @(posedge clk);
        #1;
        axis_input_tvalid = 0;
        axis_input_tlast = 0;
    endtask
    
    // Known IP addresses
    localparam logic [31:0] SRC_A = 32'hC0A8_0101; // 192.168.1.1
    localparam logic [31:0] DST_A = 32'hC0A8_0102; // 192.168.1.2
    localparam logic [31:0] SRC_B = 32'h0A00_0001; // 10.0.0.1
    localparam logic [31:0] DST_B = 32'h0A00_0002; // 10.0.0.2
    
    // tests
    initial begin
        rst_n = 1;
        axis_input_tdata = '0;
        axis_input_tvalid = 0;
        axis_input_tlast = 0;
        axis_input_tkeep = '0;
        is_ipv4 = 0;
        output_tready = 1;
        
        $display("\n=====================================================");
        $display("ipv4_parser_tb");
        $display("=====================================================");
        
        // 1. Async reset
        $display("\n--- 1. Async reset ---");
        rst_n = 0;
        #3;
        check("rst_n low mid-cycle: ipv4_valid=0", ipv4_valid, 0);
        check("rst_n low mid-cycle: out_tvalid=0", output_tvalid, 0);
        check_eq("rst_n low mid-cycle: ip_source_address=0", {32'd0, ip_source_address}, 64'd0);
        check_eq("rst_n low mid-cycle: ip_destination_address=0", {32'd0, ip_destination_address}, 64'd0);
        tick(2);
        check("rst_n held low after 2 ticks: ipv4_valid=0", ipv4_valid, 0);
        rst_n = 1;
        tick(1);
        
        // 2. is_ipv4=0 -> no parsing
        $display("\n--- 2. is_ipv4=0 -> no parsing ---");
        is_ipv4 = 0;
        send_beat(ipv4_beat(4'd5, 16'd40, SRC_A, DST_A));
        tick(2);
        check("no parse: ipv4_valid=0", ipv4_valid, 0);
        check_eq("no parse: ip_source_address=0", {32'd0, ip_source_address}, 64'd0);
        check_eq("no parse: ip_destination_address=0", {32'd0, ip_destination_address}, 64'd0);
        check_eq("no parse: ip_total_length=0", {48'd0, ip_total_length}, 64'd0);
        is_ipv4 = 1;
        tick(2);
        
        // 3. IHL=5 (standard) -> ipv4_valid=1, correct fields
        $display("\n--- 3. IHL=5, valid IPv4 frame ---");
        send_beat(ipv4_beat(4'd5, 16'd60, SRC_A, DST_A));
        tick(2);
        check("ihl5: ipv4_valid=1", ipv4_valid, 1);
        check_eq("ihl5: ip_source_address", {32'd0, ip_source_address}, {32'd0, SRC_A});
        check_eq("ihl5: ip_destination_address", {32'd0, ip_destination_address}, {32'd0, DST_A});
        check_eq("ihl5: ip_total_length", {48'd0, ip_total_length}, {48'd0, 16'h003C});
        check_eq("ihl5: ip_header_bytes=20", {56'd0, ip_header_bytes}, 64'd20);
        check_eq("ihl5: udp_offset=34", {48'd0, udp_offset}, 64'd34);
        
        // 4. IHL=6 (options) -> ipv4_valid=0, hdr_bytes/udp_offset still computed
        $display("\n--- 4. IHL=6 (options) -> ipv4_valid=0 ---");
        send_beat(ipv4_beat(4'd6, 16'd60, SRC_A, DST_A));
        tick(2);
        check("ihl6: ipv4_valid=0", ipv4_valid, 0);
        check_eq("ihl6: ip_header_bytes=24", {56'd0, ip_header_bytes}, 64'd24);
        check_eq("ihl6: udp_offset=38", {48'd0, udp_offset}, 64'd38);
        
        // 5. Back-pressure
        $display("\n--- 5. Back-pressure stall ---");
        output_tready = 0;
        axis_input_tdata = ipv4_beat(4'd5, 16'd40, SRC_A, DST_A);
        axis_input_tvalid = 1;
        axis_input_tlast = 1;
        axis_input_tkeep = '1;
        tick(3);
        check("stalled: out_tvalid=0", output_tvalid, 0);
        output_tready = 1;
        tick(4);
        axis_input_tvalid = 0;
        check("released: ipv4_valid=1", ipv4_valid, 1);
        
        // 6. Multi-beat frame
        $display("\n--- 6. Multi-beat IPv4 frame ---");
        output_tready = 1;
        // Beat 0 — header beat, not last
        @(negedge clk);
        axis_input_tdata = ipv4_beat(4'd5, 16'd40, SRC_A, DST_A, 8'hAA);
        axis_input_tkeep = '1;
        axis_input_tlast = 0;
        axis_input_tvalid = 1;
        @(posedge clk);
        #1;
        // Beat 1
        axis_input_tdata = 512'hBBBB;
        axis_input_tlast = 0;
        @(posedge clk);
        #1;
        // Beat 2 — last
        axis_input_tdata = 512'hCCCC;
        axis_input_tlast = 1;
        axis_input_tkeep = 64'h00FF_FFFF_FFFF_FFFF;
        @(posedge clk);
        #1;
        axis_input_tvalid = 0;
        axis_input_tlast = 0;
        tick(2);
        check("multi-beat: ipv4_valid=1", ipv4_valid, 1);
        check_eq("multi-beat: ip_source_address", {32'd0, ip_source_address}, {32'd0, SRC_A});
        check_eq("multi-beat: ip_destination_address", {32'd0, ip_destination_address}, {32'd0, DST_A});
        check_eq("multi-beat: ip_header_bytes=20", {56'd0, ip_header_bytes}, 64'd20);
        check_eq("multi-beat: udp_offset=34", {48'd0, udp_offset}, 64'd34);
        
        // 7. Back-to-back frames
        $display("\n--- 7. Back-to-back IPv4 frames ---");
        send_beat(ipv4_beat(4'd5, 16'd40, SRC_A, DST_A));
        tick(2);
        check("b2b A: ipv4_valid=1", ipv4_valid, 1);
        check_eq("b2b A: ip_source_address", {32'd0, ip_source_address}, {32'd0, SRC_A});
        check_eq("b2b A: ip_destination_address", {32'd0, ip_destination_address}, {32'd0, DST_A});
        
        send_beat(ipv4_beat(4'd5, 16'd80, SRC_B, DST_B));
        tick(2);
        check("b2b B: ipv4_valid=1", ipv4_valid, 1);
        check_eq("b2b B: ip_source_address", {32'd0, ip_source_address}, {32'd0, SRC_B});
        check_eq("b2b B: ip_destination_address", {32'd0, ip_destination_address}, {32'd0, DST_B});
        
        // Summary
        $display("\n=====================================================");
        $display("Results: %0d passed, %0d failed", pass_count, fail_count);
        $display("=====================================================\n");
        if (fail_count) $fatal(1, "FAILED");
        else begin
            $display("ALL CHECKS PASSED");
            $finish;
        end
    end
    
    initial #200_000 $fatal(1, "TIMEOUT");
endmodule