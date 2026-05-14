`timescale 1ns/1ps

module ethernet_parser_tb;
    logic clk;
    logic rst_n;
    logic [511:0] axis_input_tdata;
    logic axis_input_tvalid;
    logic axis_input_tlast;
    logic [63:0] axis_input_tkeep;
    logic parsing_enable;
    logic [47:0] ethernet_destination_mac;
    logic [47:0] ethernet_source_mac;
    logic [15:0] ethernet_type;
    logic ethernet_valid;
    logic is_ipv4;
    logic bypass;
    logic [511:0] output_tdata;
    logic output_tvalid;
    logic output_tlast;
    logic [63:0] output_tkeep;
    logic output_tready;
    
    ethernet_parser dut (.*);
    
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
    
    // Build a 512-bit first beat from Ethernet header fields
    function automatic logic [511:0] eth_beat(
        input logic [47:0] dst,
        input logic [47:0] src,
        input logic [15:0] etype,
        input logic [7:0]  fill = 8'hAB
    );
        logic [511:0] b;
        b = {64{fill}};
        b[47:0] = dst;
        b[95:48] = src;
        b[111:96] = etype;
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
    
    // Known addresses
    localparam logic [47:0] DST = 48'hDE_AD_BE_EF_00_01;
    localparam logic [47:0] SRC = 48'hCA_FE_BA_BE_00_02;
    localparam logic [47:0] DST2 = 48'h11_22_33_44_55_66;
    localparam logic [47:0] SRC2 = 48'hAA_BB_CC_DD_EE_FF;
    
    // tests
    initial begin
        rst_n = 1;
        axis_input_tdata = '0;
        axis_input_tvalid = 0;
        axis_input_tlast = 0;
        axis_input_tkeep = '0;
        parsing_enable = 1;
        output_tready = 1;
        
        $display("\n=====================================================");
        $display("ethernet_parser_tb");
        $display("=====================================================");
        
        // 1. Async reset
        $display("\n--- 1. Async reset ---");
        rst_n = 0;
        #3;
        check("rst_n low mid-cycle: ethernet_valid=0", ethernet_valid, 0);
        check("rst_n low mid-cycle: is_ipv4=0", is_ipv4, 0);
        check("rst_n low mid-cycle: bypass=0", bypass, 0);
        check("rst_n low mid-cycle: out_tvalid=0", output_tvalid, 0);
        tick(2);
        check("rst_n held low after 2 ticks: ethernet_valid=0", ethernet_valid, 0);
        rst_n = 1;
        tick(1);
        
        // 2. parsing_enable=0 -> bypass
        $display("\n--- 2. parsing_enable=0 bypass ---");
        parsing_enable = 0;
        send_beat(eth_beat(DST, SRC, 16'h0800));
        tick(2);
        check("bypass=1", bypass, 1);
        check("ethernet_valid=0", ethernet_valid, 0);
        check("is_ipv4=0", is_ipv4, 0);
        parsing_enable = 1;
        tick(2);
        
        // 3. IPv4 frame
        $display("\n--- 3. IPv4 frame ---");
        send_beat(eth_beat(DST, SRC, 16'h0800));
        tick(2);
        check("ethernet_valid=1", ethernet_valid, 1);
        check("is_ipv4=1", is_ipv4, 1);
        check("bypass=0", bypass, 0);
        check_eq("ethernet_destination_mac", {16'd0, ethernet_destination_mac}, {16'd0, DST});
        check_eq("ethernet_source_mac", {16'd0, ethernet_source_mac}, {16'd0, SRC});
        check_eq("ethernet_type", {48'd0, ethernet_type}, {48'd0, 16'h0800});
        
        // 4. Non-IPv4 (ARP) frame
        $display("\n--- 4. ARP (non-IPv4) frame ---");
        send_beat(eth_beat(DST, SRC, 16'h0806));
        tick(2);
        check("ethernet_valid=1", ethernet_valid, 1);
        check("is_ipv4=0", is_ipv4, 0);
        check("bypass=1", bypass, 1);
        check_eq("ethernet_type=0x0806", {48'd0, ethernet_type}, {48'd0, 16'h0806});
        
        // 5. Back-pressure
        $display("\n--- 5. Back-pressure stall ---");
        output_tready = 0;
        axis_input_tdata = eth_beat(DST, SRC, 16'h0800);
        axis_input_tvalid = 1;
        axis_input_tlast = 1;
        axis_input_tkeep = '1;
        tick(3);
        check("stalled: out_tvalid=0", output_tvalid, 0);
        output_tready = 1;
        tick(4);
        axis_input_tvalid = 0;
        check("released: pipeline flushed, ethernet_valid=1", ethernet_valid, 1);
        
        // 6. Multi-beat IPv4 frame
        $display("\n--- 6. Multi-beat IPv4 frame ---");
        output_tready = 1;
        // Beat 0 — header beat, not last
        @(negedge clk);
        axis_input_tdata = eth_beat(DST, SRC, 16'h0800, 8'hAA);
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
        check("multi-beat: ethernet_valid=1", ethernet_valid, 1);
        check("multi-beat: is_ipv4=1", is_ipv4, 1);
        check_eq("multi-beat: destination_mac", {16'd0, ethernet_destination_mac}, {16'd0, DST});
        
        // 7. Back-to-back frames
        $display("\n--- 7. Back-to-back IPv4 frames ---");
        output_tready = 1;
        send_beat(eth_beat(DST, SRC, 16'h0800));
        tick(2);
        check("b2b A: ethernet_valid=1", ethernet_valid, 1);
        check_eq("b2b A: dst_mac", {16'd0, ethernet_destination_mac}, {16'd0, DST});
        
        send_beat(eth_beat(DST2, SRC2, 16'h0800));
        tick(2);
        check("b2b B: ethernet_valid=1", ethernet_valid, 1);
        check_eq("b2b B: dst_mac", {16'd0, ethernet_destination_mac}, {16'd0, DST2});
        check_eq("b2b B: src_mac", {16'd0, ethernet_source_mac}, {16'd0, SRC2});
        
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