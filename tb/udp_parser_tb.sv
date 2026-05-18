`timescale 1ns/1ps
import udp_parser_package::*;

module tb_udp_parser;
    logic clk;
    logic rst_n;
    logic [511:0] s_axis_tdata;
    logic s_axis_tvalid;
    logic s_axis_tready;
    logic s_axis_tlast;
    logic [63:0] s_axis_tkeep;

    // AXI-Stream output
    logic [511:0] m_axis_tdata;
    logic m_axis_tvalid;
    logic m_axis_tready;
    logic m_axis_tlast;
    logic [63:0] m_axis_tkeep;

    // Control signals
    logic reg_enable;
    logic [15:0] dst_port_filter;

    // Clock: 100 MHz
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Reset
    initial begin
        rst_n = 1'b0;
        #100;
        rst_n = 1'b1;
    end

    // DUT
    udp_parser_top u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tkeep(s_axis_tkeep),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tkeep(m_axis_tkeep),
        .reg_enable(reg_enable),
        .dst_port_filter(dst_port_filter)
    );

    // axi-stream helpers
    typedef struct {
        logic [511:0] tdata;
        logic [63:0] tkeep;
        logic tlast;
    } stream_beat_t;

    task automatic send_ethernet_frame(input stream_beat_t beats [], input int beat_count);
        for (int i = 0; i < beat_count; i++) begin
            s_axis_tdata <= beats[i].tdata;
            s_axis_tkeep <= beats[i].tkeep;
            s_axis_tlast <= beats[i].tlast;
            s_axis_tvalid <= 1'b1;
            @(posedge clk);
            while (!s_axis_tready) @(posedge clk);
            s_axis_tvalid <= 1'b0;
        end
        s_axis_tdata <= '0;
        s_axis_tkeep <= '0;
        s_axis_tlast <= 1'b0;
        s_axis_tvalid <= 1'b0;
    endtask

    task automatic receive_frame(output stream_beat_t beats [], output int count);
        beats = '{};
        m_axis_tready = 1'b1;
        forever begin
            @(posedge clk);
            if (m_axis_tvalid && m_axis_tready) begin
                stream_beat_t b;
                b.tdata = m_axis_tdata;
                b.tkeep = m_axis_tkeep;
                b.tlast = m_axis_tlast;
                beats = new [beats.size() + 1] (beats);
                beats[beats.size()-1] = b;
                if (m_axis_tlast) break;
            end
        end
        count = beats.size();
        m_axis_tready = 1'b0;
    endtask

    // frame builders
    function automatic logic [511:0] set_byte(logic [511:0] vec, int byte_idx, logic [7:0] val);
        vec[byte_idx*8 +: 8] = val;
        return vec;
    endfunction

    function automatic void build_udp_frame(
        output stream_beat_t beats [], output int beat_cnt,
        input [47:0] dst_mac, input [47:0] src_mac,
        input [31:0] ip_src, input [31:0] ip_dst,
        input [15:0] udp_sport, input [15:0] udp_dport,
        input [15:0] udp_payload_len, input logic [7:0] payload_bytes []
    );
        int total_ip_len, udp_len, num_beats;
        logic [511:0] first;
        int bytes_in_first, b, j, i;
        logic [511:0] beat_data;
        logic [63:0] beat_keep;
        int start_byte, end_byte;

        total_ip_len = 20 + 8 + udp_payload_len;
        udp_len = 8 + udp_payload_len;
        num_beats = 1 + ((udp_payload_len > 64) ? ((udp_payload_len - 64 + 63) / 64) : 0);
        beats = new [num_beats];
        beat_cnt = num_beats;

        first = '0;
        for (i = 0; i < 6; i++) first = set_byte(first, i, dst_mac[8*i +: 8]);
        for (i = 0; i < 6; i++) first = set_byte(first, 6+i, src_mac[8*i +: 8]);
        first = set_byte(first, 12, 8'h00);
        first = set_byte(first, 13, 8'h08);
        first = set_byte(first, 14, 8'h45);
        first = set_byte(first, 15, 8'h00);
        first = set_byte(first, 16, total_ip_len[7:0]);
        first = set_byte(first, 17, total_ip_len[15:8]);
        for (i = 18; i < 22; i++) first = set_byte(first, i, 8'h00);
        first = set_byte(first, 22, 8'h40);
        first = set_byte(first, 23, 8'h11);
        first = set_byte(first, 24, 8'h00);
        first = set_byte(first, 25, 8'h00);
        for (i = 0; i < 4; i++) first = set_byte(first, 26+i, ip_src[8*i +: 8]);
        for (i = 0; i < 4; i++) first = set_byte(first, 30+i, ip_dst[8*i +: 8]);
        first = set_byte(first, 34, udp_sport[7:0]);
        first = set_byte(first, 35, udp_sport[15:8]);
        first = set_byte(first, 36, udp_dport[15:8]);
        first = set_byte(first, 37, udp_dport[7:0]);
        first = set_byte(first, 38, udp_len[7:0]);
        first = set_byte(first, 39, udp_len[15:8]);
        first = set_byte(first, 40, 8'h00);
        first = set_byte(first, 41, 8'h00);

        bytes_in_first = (udp_payload_len < 64) ? udp_payload_len : 64;
        for (i = 0; i < bytes_in_first; i++)
            if (i < payload_bytes.size()) first = set_byte(first, 42 + i, payload_bytes[i]);

        beats[0].tdata = first;
        beats[0].tkeep = {64{1'b1}};
        beats[0].tlast = (num_beats == 1);

        for (b = 1; b < num_beats; b++) begin
            beat_data = '0; beat_keep = '0;
            start_byte = 64 + (b-1)*64;
            end_byte = start_byte + 63;
            for (j = start_byte; j <= end_byte && j < udp_payload_len; j++)
                if (j < payload_bytes.size()) begin
                    beat_data = set_byte(beat_data, j - start_byte, payload_bytes[j]);
                    beat_keep[j - start_byte] = 1'b1;
                end
            beats[b].tdata = beat_data;
            beats[b].tkeep = beat_keep;
            beats[b].tlast = (b == num_beats-1);
        end
    endfunction

    function automatic void build_arp_frame(
        output stream_beat_t beats [], output int beat_cnt,
        input [47:0] dst_mac, input [47:0] src_mac, input [15:0] ethertype = 16'h0806
    );
        logic [511:0] first;
        first = '0;
        for (int i = 0; i < 6; i++) first = set_byte(first, i, dst_mac[8*i +: 8]);
        for (int i = 0; i < 6; i++) first = set_byte(first, 6+i, src_mac[8*i +: 8]);
        first = set_byte(first, 12, ethertype[7:0]);
        first = set_byte(first, 13, ethertype[15:8]);
        for (int i = 14; i < 64; i++) first = set_byte(first, i, 8'hCC);
        beats = new [1];
        beats[0].tdata = first;
        beats[0].tkeep = 64'hFFFFFFFF_FFFFFFFF;
        beats[0].tlast = 1'b1;
        beat_cnt = 1;
    endfunction

    // main test
    initial begin
        logic [7:0] payload1 [];
        stream_beat_t tx_beats [], rx_beats [];
        int tx_count, rx_count;
        logic [63:0] rx_ts;
        logic [7:0] payload2 [];
        stream_beat_t tx_beats2 [];
        int tx_count2;
        stream_beat_t tx_arp [], rx_arp [];
        int tx_arp_cnt, rx_arp_cnt;
        logic [7:0] payload5 [];
        stream_beat_t tx_beats5 [], rx_beats5 [];
        int tx_count5, rx_count5;
        s_axis_tvalid = 0;
        m_axis_tready = 0;
        reg_enable = 1'b0;
        dst_port_filter = 16'd0;
        @(posedge rst_n);
        repeat(5) @(posedge clk);

        $display("==============================================");
        $display(" UDP Parser Directed Test Sequence");
        $display("==============================================");

        // configure
        // NOTE: THIS WILL NOT SHOW UP PASS/FAIL SINCE IT IS JUST CONFIGURATION
        reg_enable = 1'b1;
        dst_port_filter = 16'h04D2;
        repeat(2) @(posedge clk);
        $display("\nConfigured: enable=1, dst_port_filter=1234");

        // Test 2: UDP port 1234 – timestamp inserted
        $display("\n--- Test 2: UDP port 1234, timestamp inserted ---");
        payload1 = new [20];
        for (int i = 0; i < 20; i++) payload1[i] = 8'hA5;
        build_udp_frame(tx_beats, tx_count,
            .dst_mac(48'hDEADBEEF0001), .src_mac(48'hCAFE12345678),
            .ip_src(32'hC0A80101), .ip_dst(32'hC0A80102),
            .udp_sport(16'h1000), .udp_dport(16'h04D2),
            .udp_payload_len(20), .payload_bytes(payload1));
        fork
            begin send_ethernet_frame(tx_beats, tx_count); end
            begin
                receive_frame(rx_beats, rx_count);
                rx_ts = '0;
                for (int i = 0; i < 8; i++) rx_ts[8*i +: 8] = rx_beats[0].tdata[(42+i)*8 +: 8];
                if (rx_ts == 64'hA5A5A5A5A5A5A5A5)
                    $error("FAIL: Timestamp not inserted");
                else
                    $display("PASS: Timestamp inserted (0x%0h)", rx_ts);
            end
        join

        // Test 3: UDP port 5678 – dropped
        $display("\n--- Test 3: UDP port 5678, dropped ---");
        payload2 = new [16];
        for (int i = 0; i < 16; i++) payload2[i] = 8'h5A;
        build_udp_frame(tx_beats2, tx_count2,
            .dst_mac(48'hDEADBEEF0001), .src_mac(48'hCAFE12345678),
            .ip_src(32'hC0A80101), .ip_dst(32'hC0A80102),
            .udp_sport(16'h2000), .udp_dport(16'h162E),
            .udp_payload_len(16), .payload_bytes(payload2));
        m_axis_tready = 1'b1;
        send_ethernet_frame(tx_beats2, tx_count2);
        repeat(20) @(posedge clk);
        if (m_axis_tvalid)
            $error("FAIL: Output when should be dropped");
        else
            $display("PASS: No output (dropped)");
        m_axis_tready = 1'b0;

        // Test 4: ARP – passthrough unchanged
        $display("\n--- Test 4: ARP passthrough ---");
        build_arp_frame(tx_arp, tx_arp_cnt,
            .dst_mac(48'h010203040506), .src_mac(48'h0A0B0C0D0E0F));
        fork
            begin send_ethernet_frame(tx_arp, tx_arp_cnt); end
            begin
                receive_frame(rx_arp, rx_arp_cnt);
                if (rx_arp[0].tdata !== tx_arp[0].tdata)
                    $error("FAIL: ARP modified");
                else
                    $display("PASS: ARP unchanged");
            end
        join

        // Test 5: Disable parser – passthrough unchanged
        $display("\n--- Test 5: Disable parser, passthrough ---");
        reg_enable = 1'b0;
        repeat(2) @(posedge clk);
        payload5 = new [24];
        for (int i = 0; i < 24; i++) payload5[i] = 8'hA5 + i;
        build_udp_frame(tx_beats5, tx_count5,
            .dst_mac(48'hDEADBEEF0002), .src_mac(48'hCAFE12345679),
            .ip_src(32'hC0A80103), .ip_dst(32'hC0A80104),
            .udp_sport(16'h3000), .udp_dport(16'h1234),
            .udp_payload_len(24), .payload_bytes(payload5));
        fork
            begin send_ethernet_frame(tx_beats5, tx_count5); end
            begin
                receive_frame(rx_beats5, rx_count5);
                if (rx_beats5.size() > 0 && rx_beats5[0].tdata !== tx_beats5[0].tdata)
                    $error("FAIL: Modified when disabled");
                else
                    $display("PASS: Unchanged when disabled");
            end
        join

        $display("\n==============================================");
        $display(" All tests passed.");
        $display("==============================================");
        $finish;
    end
endmodule