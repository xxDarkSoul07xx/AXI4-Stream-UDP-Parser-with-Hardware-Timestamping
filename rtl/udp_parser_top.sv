`timescale 1ns/1ps
import udp_parser_package::*;

module udp_parser_top #(
    parameter int unsigned DATA_WIDTH = 512,
    parameter int unsigned BYTE_WIDTH = 64
)(
    input logic clk,
    input logic rst_n,

    // AXI-Stream slave (input) interface
    input  logic [DATA_WIDTH-1:0] s_axis_tdata,
    input  logic s_axis_tvalid,
    output logic s_axis_tready,
    input  logic s_axis_tlast,
    input  logic [BYTE_WIDTH-1:0] s_axis_tkeep,

    // AXI-Stream master (output) interface
    output logic [DATA_WIDTH-1:0] m_axis_tdata,
    output logic m_axis_tvalid,
    input  logic m_axis_tready,
    output logic m_axis_tlast,
    output logic [BYTE_WIDTH-1:0] m_axis_tkeep,

    // Control inputs
    input logic reg_enable,
    input logic [15:0] dst_port_filter
);

    // internal wires
    logic [63:0] timestamp_64;
    logic ts_out_tready;

    // AXI-Stream connections between stages
    logic [511:0] eth_out_tdata, ipv4_out_tdata, udp_out_tdata;
    logic eth_out_tvalid, ipv4_out_tvalid, udp_out_tvalid;
    logic eth_out_tlast, ipv4_out_tlast, udp_out_tlast;
    logic [63:0] eth_out_tkeep, ipv4_out_tkeep, udp_out_tkeep;
    logic eth_out_tready, ipv4_out_tready, udp_out_tready;

    // Parsed header fields from Ethernet parser
    logic [47:0] eth_dst_mac, eth_src_mac;
    logic [15:0] eth_type;
    logic eth_valid, is_ipv4, bypass;

    // Parsed fields from IPv4 parser
    logic ipv4_valid;
    logic [15:0] ip_total_len;
    logic [31:0] ip_src_addr, ip_dst_addr;
    logic [7:0] ip_header_bytes;
    logic [15:0] udp_offset;

    // Parsed/filtered fields from UDP parser
    logic udp_valid;
    logic [15:0] udp_src_port, udp_dst_port, udp_length, payload_offset;
    logic drop_packet, drop_pulse;

    // Timestamp insertion output
    logic ts_span_beat;

    // Statistics counters
    logic [31:0] pkt_count, drop_count;

    // backpressure
    assign ts_out_tready = m_axis_tready;
    assign udp_out_tready = ts_out_tready;
    assign ipv4_out_tready = udp_out_tready;
    assign eth_out_tready = ipv4_out_tready;
    assign s_axis_tready = eth_out_tready;

    // timestamp counter
    timestamp_counter u_counter (
        .clk(clk),
        .rst_n(rst_n),
        .enable(1'b1),
        .clear(1'b0),
        .timestamp(timestamp_64)
    );

    // ethernet parser
    ethernet_parser u_eth (
        .clk(clk),
        .rst_n(rst_n),
        .axis_input_tdata(s_axis_tdata),
        .axis_input_tvalid(s_axis_tvalid),
        .axis_input_tlast(s_axis_tlast),
        .axis_input_tkeep(s_axis_tkeep),
        .parsing_enable(reg_enable),
        .ethernet_destination_mac(eth_dst_mac),
        .ethernet_source_mac(eth_src_mac),
        .ethernet_type(eth_type),
        .ethernet_valid(eth_valid),
        .is_ipv4(is_ipv4),
        .bypass(bypass),
        .output_tdata(eth_out_tdata),
        .output_tvalid(eth_out_tvalid),
        .output_tlast(eth_out_tlast),
        .output_tkeep(eth_out_tkeep),
        .output_tready(eth_out_tready)
    );

    // ipv4 parser
    ipv4_parser u_ipv4 (
        .clk(clk),
        .rst_n(rst_n),
        .axis_input_tdata(eth_out_tdata),
        .axis_input_tvalid(eth_out_tvalid),
        .axis_input_tlast(eth_out_tlast),
        .axis_input_tkeep(eth_out_tkeep),
        .is_ipv4(is_ipv4),
        .ipv4_valid(ipv4_valid),
        .ip_total_length(ip_total_len),
        .ip_source_address(ip_src_addr),
        .ip_destination_address(ip_dst_addr),
        .ip_header_bytes(ip_header_bytes),
        .udp_offset(udp_offset),
        .output_tdata(ipv4_out_tdata),
        .output_tvalid(ipv4_out_tvalid),
        .output_tlast(ipv4_out_tlast),
        .output_tkeep(ipv4_out_tkeep),
        .output_tready(ipv4_out_tready)
    );

    // udp parser/filter
    udp_parser_filter u_udp (
        .clk(clk),
        .rst_n(rst_n),
        .axis_input_tdata(ipv4_out_tdata),
        .axis_input_tvalid(ipv4_out_tvalid),
        .axis_input_tlast(ipv4_out_tlast),
        .axis_input_tkeep(ipv4_out_tkeep),
        .ipv4_valid(ipv4_valid),
        .udp_offset(udp_offset),
        .destination_port_filter(dst_port_filter),
        .enable(reg_enable),
        .udp_valid(udp_valid),
        .udp_source_port(udp_src_port),
        .udp_destination_port(udp_dst_port),
        .udp_length(udp_length),
        .payload_offset(payload_offset),
        .drop_packet(drop_packet),
        .drop_count(drop_pulse),
        .output_tdata(udp_out_tdata),
        .output_tvalid(udp_out_tvalid),
        .output_tlast(udp_out_tlast),
        .output_tkeep(udp_out_tkeep),
        .output_tready(udp_out_tready)
    );

    // timestamp insert
    timestamp_insert u_ts (
        .clk(clk),
        .rst_n(rst_n),
        .axis_input_tdata(udp_out_tdata),
        .axis_input_tvalid(udp_out_tvalid),
        .axis_input_tlast(udp_out_tlast),
        .axis_input_tkeep(udp_out_tkeep),
        .timestamp(timestamp_64),
        .udp_valid(udp_valid),
        .payload_offset(payload_offset),
        .enable(reg_enable),
        .output_tdata(m_axis_tdata),
        .output_tvalid(m_axis_tvalid),
        .output_tlast(m_axis_tlast),
        .output_tkeep(m_axis_tkeep),
        .output_tready(ts_out_tready),
        .timestamp_span_beat(ts_span_beat)
    );
endmodule