`timescale 1ns/1ps

module udp_parser_filter_tb;
    logic clk;
    logic rst_n;
    logic [511:0] axis_input_tdata;
    logic axis_input_tvalid;
    logic axis_input_tlast;
    logic [63:0] axis_input_tkeep;
    logic ipv4_valid;
    logic [15:0] udp_offset;
    logic [15:0] destination_port_filter;
    logic enable;
    logic udp_valid;
    logic [15:0] udp_source_port;
    logic [15:0] udp_destination_port;
    logic [15:0] udp_length;
    logic [15:0] payload_offset;
    logic drop_packet;
    logic drop_count;
    logic [511:0] output_tdata;
    logic output_tvalid;
    logic output_tlast;
    logic [63:0] output_tkeep;
    logic output_tready;
    
    udp_parser_filter dut (.*);
    
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
    
    // Build a 512-bit beat with Ethernet+IPv4+UDP headers
    function automatic logic [511:0] udp_beat(
        input logic [15:0] udp_off,
        input logic [15:0] src_port,
        input logic [15:0] dst_port,
        input logic [15:0] length,
        input logic [7:0] fill = 8'hDD
    );
        logic [511:0] b;
        int base;
        b = {64{fill}};
        base = udp_off * 8;
        
        // Store big-endian (network order) into little-endian stream
        b[base +: 8] = src_port[15:8];
        b[base + 8 +: 8] = src_port[7:0];
        b[base + 16 +: 8] = dst_port[15:8];
        b[base + 24 +: 8] = dst_port[7:0];
        b[base + 32 +: 8] = length[15:8];
        b[base + 40 +: 8] = length[7:0];
        
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
    
    // Known port values
    localparam logic [15:0] FILTER_PORT = 16'd5000;
    localparam logic [15:0] OTHER_PORT = 16'd9999;
    localparam logic [15:0] SOURCE_PORT = 16'd12345;
    localparam logic [15:0] UDP_OFFSET = 16'd34; // standard IHL=5
    
    // tests
    initial begin
        rst_n = 1;
        axis_input_tdata = '0;
        axis_input_tvalid = 0;
        axis_input_tlast = 0;
        axis_input_tkeep = '0;
        ipv4_valid = 1;
        udp_offset = UDP_OFFSET;
        destination_port_filter = FILTER_PORT;
        enable = 1;
        output_tready = 1;
        
        $display("\n=====================================================");
      $display("udp_parser_filter_tb");
        $display("=====================================================");
        
        // 1. Async reset
        $display("\n--- 1. Async reset ---");
        rst_n = 0;
        #3;
        check("rst_n low mid-cycle: udp_valid=0", udp_valid, 0);
        check("rst_n low mid-cycle: drop_packet=0", drop_packet, 0);
        check("rst_n low mid-cycle: out_tvalid=0", output_tvalid, 0);
        check("rst_n low mid-cycle: drop_count=0", drop_count, 0);
        tick(2);
        check("rst_n held low after 2 ticks: udp_valid=0", udp_valid, 0);
        rst_n = 1;
        tick(1);
        
        // 2. Non-IPv4 -> passthrough
        $display("\n--- 2. Non-IPv4 passthrough ---");
        ipv4_valid = 0;
        send_beat(512'hABCD);
        tick(2);
        check("non-ipv4: udp_valid=0", udp_valid, 0);
        check("non-ipv4: drop_packet=0", drop_packet, 0);
        ipv4_valid = 1;
        
        // 3. enable=0 -> all UDP passes
        $display("\n--- 3. enable=0 -> all UDP passes ---");
        enable = 0;
        send_beat(udp_beat(UDP_OFFSET, SOURCE_PORT, OTHER_PORT, 16'd20));
        tick(2);
        check("no-enable: udp_valid=1", udp_valid, 1);
        check("no-enable: drop_packet=0", drop_packet, 0);
        enable = 1;
        
        // 4. Port match -> pass
        $display("\n--- 4. Port match ---");
        send_beat(udp_beat(UDP_OFFSET, SOURCE_PORT, FILTER_PORT, 16'd28));
        tick(2);
        check("match: udp_valid=1", udp_valid, 1);
        check("match: drop_packet=0", drop_packet, 0);
        check_eq("match: udp_source_port", {48'd0, udp_source_port}, {48'd0, SOURCE_PORT});
        check_eq("match: udp_destination_port", {48'd0, udp_destination_port}, {48'd0, FILTER_PORT});
        check_eq("match: udp_length", {48'd0, udp_length}, {48'd0, 16'd28});
        check_eq("match: payload_offset", {48'd0, payload_offset}, {48'd0, UDP_OFFSET + 16'd8});
        
        // 5. Port mismatch -> drop
        $display("\n--- 5. Port mismatch -> drop ---");
        send_beat(udp_beat(UDP_OFFSET, SOURCE_PORT, OTHER_PORT, 16'd20));
        tick(2);
        check("mismatch: udp_valid=0", udp_valid, 0);
        check("mismatch: drop_count=1", drop_count, 1);
        tick(1);
        check("mismatch: drop_packet clears", drop_packet, 0);
        check("mismatch: out_tvalid=0", output_tvalid, 0);
        
        // 6. Filter=0 (wildcard) -> all ports pass
        $display("\n--- 6. Filter=0 wildcard ---");
        destination_port_filter = 16'd0;
        send_beat(udp_beat(UDP_OFFSET, SOURCE_PORT, OTHER_PORT, 16'd20));
        tick(2);
        check("wildcard: udp_valid=1", udp_valid, 1);
        check("wildcard: drop_packet=0", drop_packet, 0);
        destination_port_filter = FILTER_PORT;
        
        // 7. Back-pressure stall
        $display("\n--- 7. Back-pressure stall ---");
        output_tready = 0;
        axis_input_tdata = udp_beat(UDP_OFFSET, SOURCE_PORT, FILTER_PORT, 16'd28);
        axis_input_tvalid = 1;
        axis_input_tlast = 1;
        axis_input_tkeep = '1;
        tick(3);
        check("bp: stalled out_tvalid=0", output_tvalid, 0);
        output_tready = 1;
        tick(4);
        axis_input_tvalid = 0;
        check("bp: released udp_valid=1", udp_valid, 1);
        
        // 8. Multi-beat matched frame
        $display("\n--- 8. Multi-beat matched frame ---");
        output_tready = 1;
        // Beat 0 — header beat, not last
        @(negedge clk);
        axis_input_tdata = udp_beat(UDP_OFFSET, SOURCE_PORT, FILTER_PORT, 16'd100);
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
        axis_input_tkeep = 64'hFFFF_FFFF_FFFF_0000;
        @(posedge clk);
        #1;
        axis_input_tvalid = 0;
        axis_input_tlast = 0;
        tick(2);
        check("multi-match: udp_valid=1", udp_valid, 1);
        check("multi-match: drop_packet=0", drop_packet, 0);
        check_eq("multi-match: udp_destination_port", {48'd0, udp_destination_port}, {48'd0, FILTER_PORT});
        
        // 9. Multi-beat dropped frame
        $display("\n--- 9. Multi-beat dropped frame ---");
        // Beat 0 — header beat, not last
        @(negedge clk);
        axis_input_tdata = udp_beat(UDP_OFFSET, SOURCE_PORT, OTHER_PORT, 16'd100);
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
        axis_input_tkeep = 64'hFFFF_FFFF_FFFF_0000;
        @(posedge clk);
        #1;
        axis_input_tvalid = 0;
        axis_input_tlast = 0;
        tick(2);
        check("multi-drop: out_tvalid=0", output_tvalid, 0);
        check("multi-drop: drop_count=1", drop_count, 1);
        tick(1);
        check("multi-drop: drop_packet clears", drop_packet, 0);
        
        // 10. Back-to-back match then mismatch
        $display("\n--- 10. Back-to-back match then mismatch ---");
        send_beat(udp_beat(UDP_OFFSET, SOURCE_PORT, FILTER_PORT, 16'd28));
        tick(2);
        check("b2b match: udp_valid=1", udp_valid, 1);
        check("b2b match: drop_packet=0", drop_packet, 0);
        
        send_beat(udp_beat(UDP_OFFSET, SOURCE_PORT, OTHER_PORT, 16'd28));
        tick(2);
        check("b2b mismatch: udp_valid=0", udp_valid, 0);
        check("b2b mismatch: drop_count=1", drop_count, 1);
        tick(1);
        check("b2b mismatch: out_tvalid=0", output_tvalid, 0);
        
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