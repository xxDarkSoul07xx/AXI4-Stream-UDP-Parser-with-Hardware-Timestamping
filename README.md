# AXI4-Stream UDP Parser with Hardware Timestamping

512-bit AXI4-Stream UDP/IP packet parser extracting Ethernet, IPv4, and UDP headers with configurable port filtering and 64-bit hardware timestamp insertion.

## Features
- Ethernet, IPv4, and UDP header extraction at 512 bits per beat
- Configurable UDP destination port filtering with drop support
- 64-bit cycle-accurate hardware timestamp insertion at payload offset
- Passthrough mode for non-IPv4 traffic and parser disable
- AXI4-Stream backpressure propagation across 5-stage pipeline
- 8-cycle parse latency with single-beat-per-cycle throughput

## Block Diagram

```
AXI4-Stream In                              AXI4-Stream Out
     |                                            ^
     v                                            |
+-------------------------------------------------+
|                UDP Parser +                     |
|              Timestamp Insertion                |
+-------------------------------------------------+
     |                                            ^
     |   Control (reg_enable, dst_port_filter)    |
     +--------------------------------------------+

Internal Pipeline:
+----------------+  +----------------+  +----------------+
| Ethernet Parser |->| IPv4 Parser   |->| UDP Parser     |
+----------------+  +----------------+  +----------------+
                                         |
                                         v
                                +----------------+
                                | Port Filter    |
                                +----------------+
                                         |
                                         v
                                +----------------+
                                | Timestamp      |
                                | Insertion      |
                                +----------------+
```

## Resource Utilization
Synthesized on Xilinx Artix-7:

| Resource | Count |
|----------|-------|
| LUTs     | 2,140 |
| FFs      | 3,455 |
| BRAM     | 0     |
| DSP      | 0     |

## Performance
- Throughput: 512 bits/cycle (single-beat-per-cycle)
- Parse latency: 8 cycles (min: 8, max: 8, avg: 8)
- Clock: 100 MHz

## Verification
- 5 directed functional tests covering timestamp insertion, port filtering, ARP passthrough, and disable mode
- Python golden model validated against 1,000+ randomized test vectors (100% pass)
- Latency measurement across all test packets

## Project Structure
```
AXI4-Stream-UDP-Parser-with-Hardware-Timestamping/
├── rtl/
│   ├── udp_parser_package.sv
│   ├── timestamp_counter.sv
│   ├── ethernet_parser.sv
│   ├── ipv4_parser.sv
│   ├── udp_parser_filter.sv
│   ├── timestamp_insert.sv
│   └── udp_parser_top.sv
├── tb/
│   ├── ethernet_parser_tb.sv
│   ├── ipv4_parser_tb.sv
│   ├── timestamp_counter_tb.sv
│   ├── timestamp_insert_tb.sv
│   ├── udp_parser_filter_tb.sv
│   └── udp_parser_tb.sv
├── python/
│   ├── golden_model.py
│   ├── random_test.py
│   └── test_vectors.txt
├── latency_results.txt
├── LICENSE
└── README.md
```

## How to Run

### Simulation
Add all `.sv` files to a Vivado project, set `tb_udp_parser` as the top-level simulation source, and run behavioral simulation.

### Python Golden Model
```bash
cd python
python random_test.py 1000
```
Generates `test_vectors.txt` with 1,000 randomized test vectors covering UDP match, UDP mismatch, ARP passthrough, TCP passthrough, and short/invalid frames.