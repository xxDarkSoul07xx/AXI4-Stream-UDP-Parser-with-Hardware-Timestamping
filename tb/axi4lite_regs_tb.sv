`timescale 1ns/1ps

import udp_parser_package::*;

module axi4lite_regs_tb;
    logic s_axi_aclk;
    logic s_axi_arestn;
    logic [31:0] s_axi_awaddr;
    logic s_axi_awvalid;
    logic s_axi_awready;
    logic [31:0] s_axi_wdata;
    logic [3:0] s_axi_wstrb;
    logic s_axi_wvalid;
    logic s_axi_wready;
    logic [1:0] s_axi_bresp;
    logic s_axi_bvalid;
    logic s_axi_bready;
    logic [31:0] s_axi_araddr;
    logic s_axi_arvalid;
    logic s_axi_arready;
    logic [31:0] s_axi_rdata;
    logic [1:0] s_axi_rresp;
    logic s_axi_rvalid;
    logic s_axi_rready;
    logic reg_enable;
    logic [15:0] reg_destination_port_filter;
    logic [63:0] status_timestamp;
    logic [31:0] status_packet_count;
    logic [31:0] status_drop_count;
    logic status_fifo_full;
    logic status_packet_dropped;
    
    axi4lite_regs dut (
        .s_axi_aclk(s_axi_aclk),
        .s_axi_arestn(s_axi_arestn),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .reg_enable(reg_enable),
        .reg_destination_port_filter(reg_destination_port_filter),
        .status_timestamp(status_timestamp),
        .status_packet_count(status_packet_count),
        .status_drop_count(status_drop_count),
        .status_fifo_full(status_fifo_full),
        .status_packet_dropped(status_packet_dropped)
    );
    
    // 10ns clock (100MHz)
    initial s_axi_aclk = 0;
    always #5 s_axi_aclk = ~s_axi_aclk;
    
    // counters
    int pass_count = 0;
    int fail_count = 0;
    logic [31:0] read_data;
    
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
        repeat(n) @(posedge s_axi_aclk);
        #1;
    endtask
    
    // AXI4-Lite write transaction
    task axi_write(
        input logic [31:0] addr,
        input logic [31:0] data,
        input logic [3:0] strb = 4'hF
    );
        @(negedge s_axi_aclk);
        s_axi_awaddr = addr;
        s_axi_awvalid = 1;
        s_axi_wdata = data;
        s_axi_wstrb = strb;
        s_axi_wvalid = 1;
        s_axi_bready = 1;
        
        @(posedge s_axi_aclk);
        #1;
        while (!s_axi_awready) begin
            @(posedge s_axi_aclk);
            #1;
        end
        s_axi_awvalid = 0;
        
        while (!s_axi_wready) begin
            @(posedge s_axi_aclk);
            #1;
        end
        s_axi_wvalid = 0;
        
        while (!s_axi_bvalid) begin
            @(posedge s_axi_aclk);
            #1;
        end
        @(posedge s_axi_aclk);
        #1;
        s_axi_bready = 0;
    endtask
    
    // AXI4-Lite read transaction
    task axi_read(input logic [31:0] addr, output logic [31:0] data);
        @(negedge s_axi_aclk);
        s_axi_araddr = addr;
        s_axi_arvalid = 1;
        s_axi_rready = 1;
        
        @(posedge s_axi_aclk);
        #1;
        while (!s_axi_arready) begin
            @(posedge s_axi_aclk);
            #1;
        end
        s_axi_arvalid = 0;
        
        while (!s_axi_rvalid) begin
            @(posedge s_axi_aclk);
            #1;
        end
        data = s_axi_rdata;
        
        @(posedge s_axi_aclk);
        #1;
        s_axi_rready = 0;
    endtask
    
    // tests
    initial begin
        // initialize all inputs
        s_axi_arestn = 1;
        s_axi_awaddr = '0;
        s_axi_awvalid = 0;
        s_axi_wdata = '0;
        s_axi_wstrb = '0;
        s_axi_wvalid = 0;
        s_axi_bready = 0;
        s_axi_araddr = '0;
        s_axi_arvalid = 0;
        s_axi_rready = 0;
        status_timestamp = 64'hCAFE_BABE_1234_5678;
        status_packet_count = 32'd42;
        status_drop_count = 32'd7;
        status_fifo_full = 0;
        status_packet_dropped = 0;
        
        $display("\n=====================================================");
        $display("axi4lite_regs_tb");
        $display("=====================================================");
        
        // 1. Async reset
        $display("\n--- 1. Async reset ---");
        s_axi_arestn = 0;
        #3;
        check("reset: reg_enable=0", reg_enable, 0);
        check_eq("reset: reg_destination_port_filter=0", {48'd0, reg_destination_port_filter}, 64'd0);
        check("reset: s_axi_bvalid=0", s_axi_bvalid, 0);
        check("reset: s_axi_rvalid=0", s_axi_rvalid, 0);
        tick(2);
        check("reset held: reg_enable=0", reg_enable, 0);
        s_axi_arestn = 1;
        tick(2);
        
        // 2. Write and read back CONTROL
        $display("\n--- 2. Write/read CONTROL ---");
        axi_write(REGISTER_CONTROL, 32'h0000_0001);
        axi_read(REGISTER_CONTROL, read_data);
        check_eq("CONTROL readback", {32'd0, read_data}, {32'd0, 32'h0000_0001});
        check("reg_enable=1", reg_enable, 1);
        
        // 3. Write and read back DST_PORT_FILTER
        $display("\n--- 3. Write/read DST_PORT_FILTER ---");
        axi_write(REGISTER_DESTINATION_PORT_FILTER, 32'h0000_1388);
        axi_read(REGISTER_DESTINATION_PORT_FILTER, read_data);
        check_eq("DST_PORT_FILTER readback", {32'd0, read_data}, {32'd0, 32'h0000_1388});
        check_eq("reg_destination_port_filter output", {48'd0, reg_destination_port_filter}, {48'd0, 16'h1388});
        
        // 4. Read-only registers reflect live inputs
        $display("\n--- 4. Read-only registers ---");
        axi_read(REGISTER_TIMESTAMP_LOW, read_data);
        check_eq("TIMESTAMP_LOW", {32'd0, read_data}, {32'd0, status_timestamp[31:0]});
        axi_read(REGISTER_TIMESTAMP_HIGH, read_data);
        check_eq("TIMESTAMP_HIGH", {32'd0, read_data}, {32'd0, status_timestamp[63:32]});
        axi_read(REGISTER_PACKET_COUNT, read_data);
        check_eq("PACKET_COUNT", {32'd0, read_data}, {32'd0, status_packet_count});
        axi_read(REGISTER_DROPPED_COUNT, read_data);
        check_eq("DROP_COUNT", {32'd0, read_data}, {32'd0, status_drop_count});
        
        // 5. STATUS live fifo_full
        $display("\n--- 5. STATUS live inputs ---");
        status_fifo_full = 1;
        tick(1);
        axi_read(REGISTER_STATUS, read_data);
        check("STATUS[0]=fifo_full=1", read_data[STATUS_FIFO_FULL_BIT], 1);
        status_fifo_full = 0;
        tick(1);
        axi_read(REGISTER_STATUS, read_data);
        check("STATUS[0]=fifo_full=0", read_data[STATUS_FIFO_FULL_BIT], 0);
        
        // 6. pkt_dropped sticky
        $display("\n--- 6. pkt_dropped sticky ---");
        status_packet_dropped = 1;
        tick(1);
        status_packet_dropped = 0;
        tick(1);
        axi_read(REGISTER_STATUS, read_data);
        check("STATUS[1]=pkt_dropped sticky=1", read_data[STATUS_PACKET_DROPPED_BIT], 1);
        axi_read(REGISTER_STATUS, read_data);
        check("STATUS[1]=pkt_dropped cleared after read", read_data[STATUS_PACKET_DROPPED_BIT], 0);
        
        // 7. Write to RO register ignored
        $display("\n--- 7. Write to RO register ignored ---");
        axi_write(REGISTER_PACKET_COUNT, 32'hDEAD_BEEF);
        axi_read(REGISTER_PACKET_COUNT, read_data);
        check_eq("PACKET_COUNT unchanged after RO write", {32'd0, read_data}, {32'd0, status_packet_count});
        
        // 8. Byte-strobe partial write
        $display("\n--- 8. Byte-strobe partial write ---");
        axi_write(REGISTER_CONTROL, 32'h0000_0001, 4'hF);
        axi_write(REGISTER_CONTROL, 32'hAB00_0000, 4'b1000);
        axi_read(REGISTER_CONTROL, read_data);
        check_eq("CONTROL after byte-strobe write", {32'd0, read_data}, {32'd0, 32'hAB00_0001});
        
        // 9. Back-to-back writes
        $display("\n--- 9. Back-to-back writes ---");
        axi_write(REGISTER_CONTROL, 32'h0000_0000);
        axi_write(REGISTER_DESTINATION_PORT_FILTER, 32'h0000_1F90);
        axi_read(REGISTER_CONTROL, read_data);
        check_eq("b2b write: CONTROL=0", {32'd0, read_data}, {32'd0, 32'h0000_0000});
        axi_read(REGISTER_DESTINATION_PORT_FILTER, read_data);
        check_eq("b2b write: DST_PORT=8080", {32'd0, read_data}, {32'd0, 32'h0000_1F90});
        
        // 10. Back-to-back reads
        $display("\n--- 10. Back-to-back reads ---");
        status_packet_count = 32'd100;
        status_drop_count = 32'd5;
        tick(1);
        axi_read(REGISTER_PACKET_COUNT, read_data);
        check_eq("b2b read: PACKET_COUNT", {32'd0, read_data}, {32'd0, 32'd100});
        axi_read(REGISTER_DROPPED_COUNT, read_data);
        check_eq("b2b read: DROP_COUNT", {32'd0, read_data}, {32'd0, 32'd5});
        axi_read(REGISTER_CONTROL, read_data);
        check_eq("b2b read: CONTROL", {32'd0, read_data}, {32'd0, 32'h0000_0000});
        
        // 11. Output signals track register writes
        $display("\n--- 11. Output signals track register writes ---");
        axi_write(REGISTER_CONTROL, 32'h0000_0001);
        check("reg_enable=1 after write", reg_enable, 1);
        axi_write(REGISTER_CONTROL, 32'h0000_0000);
        check("reg_enable=0 after write", reg_enable, 0);
        axi_write(REGISTER_DESTINATION_PORT_FILTER, 32'h0000_ABCD);
        check_eq("reg_destination_port_filter=0xABCD", {48'd0, reg_destination_port_filter}, {48'd0, 16'hABCD});
        
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