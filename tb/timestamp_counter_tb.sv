`timescale 1ns/1ps

module timestamp_counter_tb;
    logic clk;
    logic rst_n;
    logic enable;
    logic clear;
    logic [63:0] timestamp;

    timestamp_counter dut (.*);

    // 10ns clock (100MHz)
    initial clk = 0;
    always #5 clk = ~clk;

    // counters
    int pass_count = 0;
    int fail_count = 0;

    task check(input string name, input logic [63:0] got, input logic [63:0] exp);
        if (got === exp) begin
            $display("PASS  %-45s  got=0x%016h", name, got);
            pass_count++;
        end else begin
            $error("FAIL  %-45s  got=0x%016h  exp=0x%016h", name, got, exp);
            fail_count++;
        end
    endtask

    // tick n rising edges then wait 1ns for outputs to settle
    task tick(input int n = 1);
        repeat(n) @(posedge clk);
        #1;
    endtask

    // tests
    initial begin
        rst_n = 1;
        enable = 0;
        clear = 0;

        $display("\n=====================================================");
        $display("tb_timestamp_counter");
        $display("=====================================================");

        // asynhronous reset
        $display("\n--- 1. Async reset ---");
        rst_n = 0;
        #3; // mid-cycle, no clock edge needed
        check("rst_n low mid-cycle -> 0", timestamp, 64'd0);
        tick(2);
        check("rst_n held low after 2 ticks -> still 0", timestamp, 64'd0);
        rst_n = 1;

        // basic increment
        $display("\n--- 2. Basic increment ---");
        enable = 1;
        tick(1); check("tick 1 -> 1", timestamp, 64'd1);
        tick(1); check("tick 2 -> 2", timestamp, 64'd2);
        tick(1); check("tick 3 -> 3", timestamp, 64'd3);
        tick(7); check("tick 10 -> 10", timestamp, 64'd10);

        // hold when not enabled
        $display("\n--- 3. Hold when enable=0 ---");
        enable = 0;
        tick(3);
        check("enable=0 for 3 ticks -> still 10", timestamp, 64'd10);

        // synchronous clear
        $display("\n--- 4. Synchronous clear ---");
        clear = 1;
        tick(1); check("clear=1 -> 0", timestamp, 64'd0);
        clear = 0;
        tick(1); check("clear released, enable=0 -> still 0", timestamp, 64'd0);

        // make sure clear is over enable
        $display("\n--- 5. Clear priority over enable ---");
        enable = 1;
        tick(3); check("ran up to 3", timestamp, 64'd3);
        clear = 1;
        enable = 1;
        tick(1); check("clear=1 & enable=1 -> 0", timestamp, 64'd0);
        clear = 0;
        tick(1); check("clear released -> 1", timestamp, 64'd1);

        // make sure asynchronous reset is the highest
        $display("\n--- 6. Async reset priority ---");
        enable = 1;
        clear = 1;
        tick(2); // value is 0 due to clear
        enable = 1;
        clear = 0;
        tick(3); check("running at 3", timestamp, 64'd3);
        rst_n = 0; // async - no clock needed
        #3;
        check("rst_n low async -> 0", timestamp, 64'd0);
        rst_n = 1;
        enable = 0;
        clear = 0;
        tick(1); check("after reset release, no enable -> 0", timestamp, 64'd0);

        // saturated
        $display("\n--- 7. Saturation at MAX ---");
        force dut.timestamp = 64'hFFFF_FFFF_FFFF_FFFE;
        @(posedge clk);
        #1;
        release dut.timestamp;
        enable = 1;
        tick(1); check("MAX-1 + 1 -> MAX", timestamp, 64'hFFFF_FFFF_FFFF_FFFF);
        tick(1); check("MAX + 1 -> MAX (sat)", timestamp, 64'hFFFF_FFFF_FFFF_FFFF);
        tick(3); check("3 more ticks -> still MAX", timestamp, 64'hFFFF_FFFF_FFFF_FFFF);

        // clear from the max
        $display("\n--- 8. Clear from MAX ---");
        clear = 1;
        tick(1); check("clear from MAX -> 0", timestamp, 64'd0);
        clear = 0;
        tick(1); check("tick after clear -> 1", timestamp, 64'd1);

        // results
        $display("\n=====================================================");
        $display("Results: %0d passed, %0d failed", pass_count, fail_count);
        $display("=====================================================\n");
        if (fail_count) $fatal(1, "FAILED");
        else begin
            $display("ALL CHECKS PASSED");
            $finish;
        end
    end

    initial #50_000 $fatal(1, "TIMEOUT");

endmodule