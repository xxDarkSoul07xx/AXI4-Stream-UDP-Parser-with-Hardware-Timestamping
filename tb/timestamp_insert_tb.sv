`timescale 1ns/1ps

module timestamp_insert_tb;
    logic clk;
    logic rst_n;
    logic [511:0] axis_input_tdata;
    logic axis_input_tvalid;
    logic axis_input_tlast;
    logic [63:0] axis_input_tkeep;
    logic [63:0] timestamp;
    logic udp_valid;
    logic [15:0] payload_offset;
    logic enable;
    logic [511:0] output_tdata;
    logic output_tvalid;
    logic output_tlast;
    logic [63:0] output_tkeep;
    logic output_tready;
    logic timestamp_span_beat;
    
    timestamp_insert dut (.*);
    
    // 10ns clock (100MHz)
    initial clk = 0;
    always #5 clk = ~clk;
    
    // counters
    int pass_count = 0;
    int fail_count = 0;
    int timeout;
    
    // Shared variables for capturing output
    logic [511:0] cap;
    logic last;
    
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
    
    // Wait for next output beat
    task wait_beat(output logic [511:0] data, output logic last_out);
        timeout = 0;
        while (!output_tvalid) begin
            @(posedge clk);
            #1;
            timeout++;
            if (timeout > 20) begin
                $error("wait_beat: TIMEOUT waiting for output_tvalid");
                fail_count++;
                data = 'x;
                last_out = 'x;
                disable wait_beat;
            end
        end
        data = output_tdata;
        last_out = output_tlast;
        @(posedge clk);
        #1;
    endtask
    
    function automatic logic [511:0] filled_beat(input logic [7:0] fill);
        return {64{fill}};
    endfunction
    
    // Send one beat
    task send_beat(
        input logic [511:0] data,
        input logic [63:0] keep = '1,
        input logic last_in = 1
    );
        @(negedge clk);
        axis_input_tdata = data;
        axis_input_tkeep = keep;
        axis_input_tlast = last_in;
        axis_input_tvalid = 1;
        @(posedge clk);
        #1;
        axis_input_tvalid = 0;
        axis_input_tlast = 0;
    endtask
    
    // Drain pipeline
    task drain;
        repeat(4) @(posedge clk);
        #1;
    endtask
    
    localparam logic [15:0] PAYLOAD_OFFSET = 16'd42;
    localparam logic [63:0] TIMESTAMP_A = 64'hDEAD_BEEF_CAFE_0001;
    localparam logic [63:0] TIMESTAMP_B = 64'h1234_5678_9ABC_DEF0;
    
    // tests
    initial begin
        rst_n = 1;
        axis_input_tdata = '0;
        axis_input_tvalid = 0;
        axis_input_tlast = 0;
        axis_input_tkeep = '0;
        timestamp = TIMESTAMP_A;
        udp_valid = 1;
        payload_offset = PAYLOAD_OFFSET;
        enable = 1;
        output_tready = 1;
        
        $display("\n=====================================================");
        $display("timestamp_insert_tb");
        $display("=====================================================");
        
        // 1. Async reset
        $display("\n--- 1. Async reset ---");
        rst_n = 0;
        #3;
        check("rst_n low mid-cycle: output_tvalid=0", output_tvalid, 0);
        check("rst_n low mid-cycle: timestamp_span_beat=0", timestamp_span_beat, 0);
        tick(2);
        check("rst_n held low after 2 ticks: output_tvalid=0", output_tvalid, 0);
        rst_n = 1;
        tick(1);
        
        // 2. enable=0 -> passthrough
        $display("\n--- 2. enable=0 -> passthrough ---");
        enable = 0;
        send_beat(filled_beat(8'hAA));
        wait_beat(cap, last);
        check_eq("enable=0: ts window unchanged", cap[PAYLOAD_OFFSET*8 +: 64], {8{8'hAA}});
        enable = 1;
        drain;
        
        // 3. udp_valid=0 -> passthrough
        $display("\n--- 3. udp_valid=0 -> passthrough ---");
        udp_valid = 0;
        send_beat(filled_beat(8'hBB));
        wait_beat(cap, last);
        check_eq("udp_valid=0: ts window unchanged", cap[PAYLOAD_OFFSET*8 +: 64], {8{8'hBB}});
        udp_valid = 1;
        drain;
        
        // 4. Basic insertion
        $display("\n--- 4. Basic timestamp insertion ---");
        timestamp = TIMESTAMP_A;
        send_beat(filled_beat(8'hCC));
        wait_beat(cap, last);
        check_eq("insert: timestamp at payload_offset", cap[PAYLOAD_OFFSET*8 +: 64], TIMESTAMP_A);
        check_eq("insert: byte before window unchanged", {56'd0, cap[(PAYLOAD_OFFSET-1)*8 +: 8]}, {56'd0, 8'hCC});
        check_eq("insert: byte after window unchanged", {56'd0, cap[(PAYLOAD_OFFSET+8)*8 +: 8]}, {56'd0, 8'hCC});
        drain;
        
        // 5. Timestamp snapshot
        $display("\n--- 5. Timestamp snapshot ---");
        timestamp = TIMESTAMP_A;
        // Beat 0 (not last)
        @(negedge clk);
        axis_input_tdata = filled_beat(8'hDD);
        axis_input_tkeep = '1;
        axis_input_tlast = 0;
        axis_input_tvalid = 1;
        @(posedge clk);
        #1;
        // Change timestamp mid-frame
        timestamp = TIMESTAMP_B;
        // Beat 1 (last)
        @(negedge clk);
        axis_input_tdata = filled_beat(8'hEE);
        axis_input_tlast = 1;
        @(posedge clk);
        #1;
        axis_input_tvalid = 0;
        axis_input_tlast = 0;
        wait_beat(cap, last);
        check_eq("snapshot: beat0 has TIMESTAMP_A not TIMESTAMP_B", cap[PAYLOAD_OFFSET*8 +: 64], TIMESTAMP_A);
        timestamp = TIMESTAMP_A;
        drain;
        
        // 6. Back-pressure
        $display("\n--- 6. Back-pressure ---");
        output_tready = 1;
        send_beat(filled_beat(8'h11));
        output_tready = 0;
        tick(3);
        check("bp: output_tvalid=0 (stalled)", output_tvalid, 0);
        output_tready = 1;
        wait_beat(cap, last);
        check_eq("bp: released, timestamp inserted", cap[PAYLOAD_OFFSET*8 +: 64], TIMESTAMP_A);
        drain;
        
        // 7. Multi-beat frame
        $display("\n--- 7. Multi-beat frame ---");
        output_tready = 1;
        // Beat 0 (not last)
        @(negedge clk);
        axis_input_tdata = filled_beat(8'h22);
        axis_input_tkeep = '1;
        axis_input_tlast = 0;
        axis_input_tvalid = 1;
        @(posedge clk);
        #1;
        // Beat 1 (last)
        @(negedge clk);
        axis_input_tdata = filled_beat(8'h33);
        axis_input_tlast = 1;
        @(posedge clk);
        #1;
        axis_input_tvalid = 0;
        axis_input_tlast = 0;
        wait_beat(cap, last);
        check_eq("multi: beat0 has timestamp", cap[PAYLOAD_OFFSET*8 +: 64], TIMESTAMP_A);
        check("multi: beat0 not last", last, 0);
        wait_beat(cap, last);
        check_eq("multi: beat1 unchanged", cap[0 +: 64], {8{8'h33}});
        check("multi: beat1 is last", last, 1);
        drain;
        
        // 8. Back-to-back frames
        $display("\n--- 8. Back-to-back frames ---");
        timestamp = TIMESTAMP_A;
        send_beat(filled_beat(8'h44));
        wait_beat(cap, last);
        check_eq("b2b A: timestamp=TIMESTAMP_A", cap[PAYLOAD_OFFSET*8 +: 64], TIMESTAMP_A);
        
        timestamp = TIMESTAMP_B;
        send_beat(filled_beat(8'h55));
        wait_beat(cap, last);
        check_eq("b2b B: timestamp=TIMESTAMP_B", cap[PAYLOAD_OFFSET*8 +: 64], TIMESTAMP_B);
        drain;
        
        // 9. timestamp_span_beat detection
        $display("\n--- 9. timestamp_span_beat detection ---");
        payload_offset = 16'd57;
        check("span_beat=1 when offset=57", timestamp_span_beat, 1);
        payload_offset = 16'd56;
        check("span_beat=0 when offset=56", timestamp_span_beat, 0);
        payload_offset = PAYLOAD_OFFSET;
        check("span_beat=0 when offset=42", timestamp_span_beat, 0);
        
        // 10. Various payload offsets
        $display("\n--- 10. Various payload offsets ---");
        timestamp = TIMESTAMP_A;
        
        payload_offset = 16'd24;
        send_beat(filled_beat(8'hAB));
        wait_beat(cap, last);
        check_eq("offset=24: ts inserted", cap[24*8 +: 64], TIMESTAMP_A);
        check_eq("offset=24: byte before unchanged", {56'd0, cap[23*8 +: 8]}, {56'd0, 8'hAB});
        
        payload_offset = 16'd40;
        send_beat(filled_beat(8'hAB));
        wait_beat(cap, last);
        check_eq("offset=40: ts inserted", cap[40*8 +: 64], TIMESTAMP_A);
        check_eq("offset=40: byte before unchanged", {56'd0, cap[39*8 +: 8]}, {56'd0, 8'hAB});
        
        payload_offset = 16'd56;
        send_beat(filled_beat(8'hAB));
        wait_beat(cap, last);
        check_eq("offset=56: ts inserted", cap[56*8 +: 64], TIMESTAMP_A);
        check_eq("offset=56: byte before unchanged", {56'd0, cap[55*8 +: 8]}, {56'd0, 8'hAB});
        
        payload_offset = PAYLOAD_OFFSET;
        
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