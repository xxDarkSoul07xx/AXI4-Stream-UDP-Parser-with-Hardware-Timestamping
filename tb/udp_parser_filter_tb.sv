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
    // udp_offset is a runtime parameter (bytes from frame start)
    // UDP fields are in network byte order in the beat
    function automatic logic [511:0] make_udp_beat(
        input logic [15:0] udp_off,     // byte offset of UDP header in frame
        input logic [15:0] src_port,    // network byte order src port
        input logic [15:0] dst_port,    // network byte order dst port
        input logic [15:0] length,      // UDP length field
        input logic [7:0] fill = 8'hDD
    );
        logic [511:0] b;
        int base;
        b = {64{fill}};
        base = udp_off * 8;
        // Store big-endian (network order) into little-endian stream
        b[base +: 8] = src_port[15:8];
        b[base+8 +: 8] = src_port[7:0];
        b[base+16 +: 8] = dst_port[15:8];
        b[base+24 +: 8] = dst_port[7:0];
        b[base+32 +: 8] = length[15:8];
        b[base+40 +: 8] = length[7:0];
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
        // Need to check DUT state - referencing internal state would require hierarchy
        // Using output_tready as proxy, but DROP state consumes regardless
        while (!output_tready) @(posedge clk);
        #1;
        axis_input_tvalid = 0;
        axis_input_tlast = 0;
    endtask
    
    // Known port values (network byte order on the wire)
    localparam logic [15:0] DEST_PORT_FILTER_VAL = 16'd5000;
    localparam logic [15:0] OTHER_PORT = 16'd9999;
    localparam logic [15:0] SRC_PORT = 16'd12345;
    localparam logic [15:0] UDP_OFF = 16'd34;    // standard IHL=5
    
    // tests
    initial begin
        rst_n = 1;
        axis_input_tdata = '0;
        axis_input_tvalid = 0;
        axis_input_tlast = 0;
        axis_input_tkeep = '0;
        ipv4_valid = 1;
        udp_offset = UDP_OFF;
        destination_port_filter = DEST_PORT_FILTER_VAL;
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
        check("rst_n low mid-cycle: drop_count=0", drop_count, 0);
        check("rst_n low mid-cycle: output_tvalid=0", output_tvalid, 0);
        tick(2);
        check("rst_n held low after 2 ticks: udp_valid=0", udp_valid, 0);
        rst_n = 1;
        tick(1);
        
        // 2. Non-IPv4 -> passthrough
        $display("\n--- 2. Non-IPv4 passthrough ---");
        ipv4_valid = 0;
        send_beat(512'hABCD, '1, 1);
        tick(2);
        check("non-ipv4: udp_valid=0", udp_valid, 0);
        check("non-ipv4: drop_packet=0", drop_packet, 0);
        ipv4_valid = 1;
        
        // 3. enable=0 -> no filtering, all UDP passes
        $display("\n--- 3. enable=0 -> all UDP passes ---");
        enable = 0;
        send_beat(make_udp_beat(UDP_OFF, SRC_PORT, OTHER_PORT, 16'd20));
        tick(2);
        check("no-enable: udp_valid=1", udp_valid, 1);
        check("no-enable: drop_packet=0", drop_packet, 0);
        enable = 1;
        
        // 4. Port match -> pass
        $display("\n--- 4. Port match ---");
        send_beat(make_udp_beat(UDP_OFF, SRC_PORT, DEST_PORT_FILTER_VAL, 16'd28));
        tick(2);
        check("match: udp_valid=1", udp_valid, 1);
        check("match: drop_packet=0", drop_packet, 0);
        check_eq("match: udp_source_port", {48'd0, udp_source_port}, {48'd0, SRC_PORT});
        check_eq("match: udp_destination_port", {48'd0, udp_destination_port}, {48'd0, DEST_PORT_FILTER_VAL});
        check_eq("match: udp_length", {48'd0, udp_length}, {48'd0, 16'd28});
        check_eq("match: payload_offset", {48'd0, payload_offset}, {48'd0, UDP_OFF+16'd8});
        
        // 5. Port mismatch -> drop, drop_count pulse
        $display("\n--- 5. Port mismatch -> drop ---");
        begin
            logic drop_count_seen;
            drop_count_seen = 0;
            send_beat(make_udp_beat(UDP_OFF, SRC_PORT, OTHER_PORT, 16'd20));
            // Sample drop_count over the next few cycles
            repeat(6) begin
                @(posedge clk);
                if (drop_count) drop_count_seen = 1;
            end
            #1;
            check("mismatch: udp_valid=0", udp_valid, 0);
            check("mismatch: drop_packet clears", drop_packet, 0);
            check("mismatch: drop_count seen", drop_count_seen, 1);
            check("mismatch: output_tvalid=0", output_tvalid, 0);
        end
        
        // 6. Filter=0 (wildcard) -> all ports pass
        $display("\n--- 6. Filter=0 wildcard ---");
        destination_port_filter = 16'd0;
        send_beat(make_udp_beat(UDP_OFF, SRC_PORT, OTHER_PORT, 16'd20));
        tick(2);
        check("wildcard: udp_valid=1", udp_valid, 1);
        check("wildcard: drop_packet=0", drop_packet, 0);
        destination_port_filter = DEST_PORT_FILTER_VAL;
        
        // 7. Back-pressure stalls PASS
        $display("\n--- 7. Back-pressure stall ---");
        output_tready = 0;
        axis_input_tdata = make_udp_beat(UDP_OFF, SRC_PORT, DEST_PORT_FILTER_VAL, 16'd28);
        axis_input_tvalid = 1;
        axis_input_tlast = 1;
        axis_input_tkeep = '1;
        tick(3);
        check("bp: stalled output_tvalid=0", output_tvalid, 0);
        output_tready = 1;
        tick(4);
        axis_input_tvalid = 0;
        check("bp: released udp_valid=1", udp_valid, 1);
        
        // 8. Multi-beat matched frame
        $display("\n--- 8. Multi-beat matched frame ---");
        output_tready = 1;
        @(negedge clk);
        axis_input_tdata = make_udp_beat(UDP_OFF, SRC_PORT, DEST_PORT_FILTER_VAL, 16'd100);
        axis_input_tkeep = '1;
        axis_input_tlast = 0;
        axis_input_tvalid = 1;
        @(posedge clk);
        #1;
        axis_input_tdata = 512'hBBBB;
        axis_input_tlast = 0;
        @(posedge clk);
        #1;
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
        check_eq("multi-match: udp_destination_port", {48'd0, udp_destination_port}, {48'd0, DEST_PORT_FILTER_VAL});
        
        // 9. Multi-beat dropped frame (no output)
        $display("\n--- 9. Multi-beat dropped frame (no output) ---");
        begin
            logic drop_count_seen;
            drop_count_seen = 0;
            @(negedge clk);
            axis_input_tdata = make_udp_beat(UDP_OFF, SRC_PORT, OTHER_PORT, 16'd100);
            axis_input_tkeep = '1;
            axis_input_tlast = 0;
            axis_input_tvalid = 1;
            @(posedge clk);
            #1;
            axis_input_tdata = 512'hBBBB;
            axis_input_tlast = 0;
            @(posedge clk);
            #1;
            axis_input_tdata = 512'hCCCC;
            axis_input_tlast = 1;
            @(posedge clk);
            #1;
            axis_input_tvalid = 0;
            axis_input_tlast = 0;
            repeat(6) begin
                @(posedge clk);
                if (drop_count) drop_count_seen = 1;
            end
            #1;
            check("multi-drop: output_tvalid=0", output_tvalid, 0);
            check("multi-drop: drop_count seen", drop_count_seen, 1);
            check("multi-drop: drop_packet clears", drop_packet, 0);
        end
        
        // 10. Back-to-back: match then mismatch
        $display("\n--- 10. Back-to-back match then mismatch ---");
        output_tready = 1;
        send_beat(make_udp_beat(UDP_OFF, SRC_PORT, DEST_PORT_FILTER_VAL, 16'd28));
        tick(2);
        check("b2b match: udp_valid=1", udp_valid, 1);
        check("b2b match: drop_packet=0", drop_packet, 0);
        
        begin
            logic drop_count_seen;
            drop_count_seen = 0;
            send_beat(make_udp_beat(UDP_OFF, SRC_PORT, OTHER_PORT, 16'd28));
            repeat(6) begin
                @(posedge clk);
                if (drop_count) drop_count_seen = 1;
            end
            #1;
            check("b2b mismatch: udp_valid=0", udp_valid, 0);
            check("b2b mismatch: drop_count seen", drop_count_seen, 1);
            check("b2b mismatch: output_tvalid=0", output_tvalid, 0);
        end
        
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
    
    initial #500_000 $fatal(1, "TIMEOUT");
endmodule