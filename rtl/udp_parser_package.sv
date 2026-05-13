`timescale 1ns/1ps

package udp_parser_package;

    localparam int unsigned DATA_WIDTH = 512; // 512 bits per chunk
    localparam int unsigned BYTE_WIDTH = DATA_WIDTH / 8; // 64 bytes per chunk
    localparam int unsigned TIMESTAMP_WIDTH = 64; // 64 bit wide timestamps

    // forwarding signals
    typedef struct packed {
        logic [DATA_WIDTH-1:0] tdata; // packet bytes
        logic [BYTE_WIDTH-1:0] tkeep; // actual real bits (1 bit per byte = 64)
        logic tlast; // last chunk of packet
        logic tvalid;
    } axis_master_t;

    // backward signals
    typedef struct packed {
        logic tready; // 1 = ready to receive, 0 = don't send yet
    } axis_slave_t;

    typedef axis_master_t axis_input_t; // signals going into the parser
    typedef axis_master_t axis_output_t; // signals going out of the parser

    // ethernet header
    // bytes structure:
    // 0-5: destination mac
    // 6-11: source mac
    // 12-13: ethertype (kind of packet)
    localparam int unsigned ETHERNET_DESTINATION_MAC = 0; // bytes 0-5
    localparam int unsigned ETHERNET_SOURCE_MAC = 48; // bytes 6-11
    localparam int unsigned ETHERNET_TYPE = 96; // bytes 12-13

    localparam logic [15:0] ETHERTYPE_IPV4 = 16'h0800; // identify IPv4 packet

    // ipv4 header
    // bits structure:
    // 0-7: version and version length
    // 16-31: total length of ip packet
    // 96-127: sender's ip address
    // 128-159: destination ip address
    localparam int unsigned IP_VERSION_IHL = 0;
    localparam int unsigned IP_TOTAL_LENGTH = 16;
    localparam int unsigned IP_SOURCE_ADDRESS = 96;
    localparam int unsigned IP_DESTINATION_ADDRESS = 128;

    localparam logic [7:0] IP_PROTOCOL_UDP = 8'h11; // identify udp packet
    localparam int unsigned ETHERNET_HEADER_BITS = 112; // 14 bytes

    // udp header
    // bits structure:
    // 0-15: source port
    // 16-31: destination port
    // 32-47: length of udp data
    // 48-63: checksum
    localparam int unsigned UDP_SOURCE_PORT = 0;
    localparam int unsigned UDP_DESTINATION_PORT = 16;
    localparam int unsigned UDP_LENGTH = 32;
    localparam int unsigned UDP_CHECKSUM = 48;

    // register addresses
    // 4 bytes each
    localparam logic [7:0] REGISTER_CONTROL = 8'h00; // parser on or off
    localparam logic [7:0] REGISTER_STATUS = 8'h04; // check for problems
    localparam logic [7:0] REGISTER_DESTINATION_PORT_FILTER = 8'h08; // set desired udp port
    localparam logic [7:0] REGISTER_TIMESTAMP_LOW = 8'h0C; // timestamp bottom 32 bits
    localparam logic [7:0] REGISTER_TIMESTAMP_HIGH = 8'h10; // timestamp top 32 bits
    localparam logic [7:0] REGISTER_PACKET_COUNT = 8'h14; // count packets we saw
    localparam logic [7:0] REGISTER_DROPPED_COUNT = 8'h18; // count packets we dropped

    // control register
    // bit 0 is the on or off switch
    // 1 = working, 0 = not working
    localparam int unsigned CONTROL_ENABLE_BIT = 0;

    // status register
    localparam int unsigned STATUS_FIFO_FULL_BIT = 0; // 1 = can't take anything else
    localparam int unsigned STATUS_PACKET_DROPPED_BIT = 1; // 1 = lost packets
endpackage : udp_parser_package