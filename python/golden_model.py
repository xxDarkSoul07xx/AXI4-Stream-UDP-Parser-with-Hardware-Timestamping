import struct

class UDPParserGolden:
    def __init__(self, dst_port_filter=0, enable=1, timestamp_value=0):
        self.dst_port_filter = dst_port_filter
        self.enable = enable
        self.timestamp_value = timestamp_value
        self.pkt_count = 0
        self.drop_count = 0

    def process_frame(self, frame_bytes):
        """process a single Ethernet frame, return (output_bytes, dropped, timestamp_used)"""

        # passthrough if disabled
        if not self.enable:
            return frame_bytes, False, 0

        # must have at least 14 bytes for Ethernet header
        if len(frame_bytes) < 14:
            return frame_bytes, False, 0

        # parse EtherType (bytes 12-13, big-endian)
        ethertype = (frame_bytes[12] << 8) | frame_bytes[13]

        # passthrough if not IPv4
        if ethertype != 0x0800:
            return frame_bytes, False, 0

        # must have at least 14 + 20 + 8 = 42 bytes
        if len(frame_bytes) < 42:
            return frame_bytes, False, 0

        # parse IPv4 header (bytes 14-33, assume IHL=5 = 20 bytes)
        ip_header_offset = 14
        protocol = frame_bytes[ip_header_offset + 9]

        # only process UDP (protocol = 17)
        if protocol != 17:
            return frame_bytes, False, 0

        # parse UDP header (bytes 34-41)
        udp_offset = ip_header_offset + 20
        dst_port = (frame_bytes[udp_offset + 2] << 8) | frame_bytes[udp_offset + 3]

        # check port filter
        if self.dst_port_filter != 0 and dst_port != self.dst_port_filter:
            self.drop_count += 1
            return None, True, 0

        # insert timestamp into UDP payload (bytes 42+)
        self.pkt_count += 1
        payload_offset = udp_offset + 8
        output = bytearray(frame_bytes)
        ts_bytes = struct.pack('<Q', self.timestamp_value)

        for i in range(8):
            if payload_offset + i < len(output):
                output[payload_offset + i] = ts_bytes[i]

        return bytes(output), False, self.timestamp_value

    def configure(self, dst_port_filter=None, enable=None, timestamp_value=None):
        if dst_port_filter is not None:
            self.dst_port_filter = dst_port_filter
        if enable is not None:
            self.enable = enable
        if timestamp_value is not None:
            self.timestamp_value = timestamp_value

    def get_stats(self):
        return self.pkt_count, self.drop_count


def build_ethernet_frame(dst_mac, src_mac, ethertype, payload):
    """Build a complete Ethernet frame."""
    frame = bytearray(14 + len(payload))
    for i in range(6):
        frame[i] = (dst_mac >> (40 - 8 * i)) & 0xFF
    for i in range(6):
        frame[6 + i] = (src_mac >> (40 - 8 * i)) & 0xFF
    frame[12] = (ethertype >> 8) & 0xFF
    frame[13] = ethertype & 0xFF
    frame[14:] = payload
    return bytes(frame)


def build_ipv4_header(src_ip, dst_ip, protocol, payload_len):
    """Build a 20-byte IPv4 header."""
    total_len = 20 + payload_len
    header = bytearray(20)
    header[0] = 0x45
    header[1] = 0x00
    struct.pack_into('>H', header, 2, total_len)
    header[4:8] = b'\x00\x00\x00\x00'
    header[8] = 64
    header[9] = protocol
    header[10:12] = b'\x00\x00'
    struct.pack_into('>I', header, 12, src_ip)
    struct.pack_into('>I', header, 16, dst_ip)
    return bytes(header)


def build_udp_header(src_port, dst_port, payload_len):
    """Build an 8-byte UDP header."""
    udp_len = 8 + payload_len
    header = bytearray(8)
    struct.pack_into('>H', header, 0, src_port)
    struct.pack_into('>H', header, 2, dst_port)
    struct.pack_into('>H', header, 4, udp_len)
    header[6:8] = b'\x00\x00'
    return bytes(header)


def build_udp_frame(dst_mac, src_mac, src_ip, dst_ip,
                    src_port, dst_port, payload):
    """Build a complete Ethernet/IPv4/UDP frame."""
    udp_header = build_udp_header(src_port, dst_port, len(payload))
    ipv4_header = build_ipv4_header(src_ip, dst_ip, 17, len(udp_header) + len(payload))
    return build_ethernet_frame(dst_mac, src_mac, 0x0800, ipv4_header + udp_header + payload)