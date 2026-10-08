// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Paul Priest
//
// The save-state image: what gx_savestate walks, in order, and what
// scripts/gxss.py reads (it parses this file: keep one section a line, its
// comment `key: description`).
// Every section is a run of 16-bit words from one channel:
//   HDR   the header (gx_savestate)
//   MCPU  the 68020's register bank, 23 longs high word first (gx_ss_m68k)
//   SCPU  the 68000's
//   SS    a module's internal registers on the state bus (gx_ss_vec), `base` its select
//   MB    the main CPU's bus, `base` a byte address (gx_main's access unit)
//   SB    the sound CPU's bus (gx_sound)
//   SD    the sound board's SDRAM, `base` a word offset into its RAM area
// The slot holds the words four to a 64-bit DDR3 word, the first in bits 15:0.

`ifndef GX_SS_LAYOUT
`define GX_SS_LAYOUT

localparam [15:0] SS_VERSION = 16'd2;

localparam [2:0] SS_HDR = 3'd0, SS_MCPU = 3'd1, SS_SCPU = 3'd2, SS_SS = 3'd3,
                 SS_MB = 3'd4, SS_SB = 3'd5, SS_SD = 3'd6;

// state bus selects, and each module's words
localparam [3:0] SSEL_BOARD = 4'd0, SSEL_SND = 4'd1, SSEL_K056800 = 4'd2, SSEL_EE = 4'd3,
                 SSEL_K0 = 4'd4, SSEL_K1 = 4'd5, SSEL_DSP = 4'd6,
                 SSEL_ESC_H = 4'd7, SSEL_ESC_L = 4'd8, SSEL_ESC_R = 4'd9;

// the Type 3/4 build (GX_T34) has four more, after the others
`ifdef GX_T34
localparam SS_NSEC = 25;
`else
localparam SS_NSEC = 21;
`endif

// { channel, base, words }
function automatic [58:0] ss_sec(input integer i);
    case (i)
        0:  ss_sec = { SS_HDR,  24'h000000, 32'd8      };  // hdr: header
        1:  ss_sec = { SS_MCPU, 24'h000000, 32'd46     };  // mcpu: 68020 registers
        2:  ss_sec = { SS_SCPU, 24'h000000, 32'd46     };  // scpu: 68000 registers
        3:  ss_sec = { SS_SS,   24'd0,      32'd16     };  // board: gx_main latches
        4:  ss_sec = { SS_SS,   24'd1,      32'd16     };  // snd: gx_sound glue
        5:  ss_sec = { SS_SS,   24'd2,      32'd4      };  // k056800: K056800
        6:  ss_sec = { SS_SS,   24'd3,      32'd69     };  // eeprom: 93C46: 64 words, then its state
        7:  ss_sec = { SS_SS,   24'd4,      32'd1398   };  // k539a: K054539 #1: 0x500 register bytes, then the rest
        8:  ss_sec = { SS_SS,   24'd5,      32'd1398   };  // k539b: K054539 #2
        9:  ss_sec = { SS_SS,   24'd6,      32'd2117   };  // dsp: TMS57002: its RAMs, then its registers
        10: ss_sec = { SS_MB,   24'hE00000, 32'd216    };  // regs: the register copy (replayed on load)
        11: ss_sec = { SS_MB,   24'hC00000, 32'd65536  };  // wram: work RAM
        12: ss_sec = { SS_MB,   24'hD90000, 32'd16384  };  // pal: palette
        13: ss_sec = { SS_MB,   24'hD20000, 32'd8192   };  // spr: sprite RAM
        14: ss_sec = { SS_MB,   24'hE20000, 32'd65536  };  // vram: K056832 VRAM, all 16 pages
        15: ss_sec = { SS_SB,   24'h100000, 32'd32768  };  // sram: sound RAM
        16: ss_sec = { SS_SD,   24'h000000, 32'd32768  };  // kram: K054539 RAMs
        17: ss_sec = { SS_SD,   24'h008000, 32'd131072 };  // dram: TMS57002 RAM
        18: ss_sec = { SS_SS,   24'd7,      32'd4096   };  // esch: 056734 local memory, high halves
        19: ss_sec = { SS_SS,   24'd8,      32'd4096   };  // escl: 056734 local memory, low halves
        20: ss_sec = { SS_SS,   24'd9,      32'd141    };  // escr: 056734 registers, pc, s0 s1 s6 s8, mailbox, flags, running
        21: ss_sec = { SS_MB,   24'hE00000, 32'd16     };  // psreg: K053936 registers
        22: ss_sec = { SS_MB,   24'hE60000, 32'd2048   };  // psline: K053936 line control
        23: ss_sec = { SS_MB,   24'hE80000, 32'd8192   };  // mpal: main monitor's palette
        24: ss_sec = { SS_MB,   24'hEA0000, 32'd8192   };  // spal: sub monitor's palette
        default: ss_sec = 59'd0;
    endcase
endfunction

`endif
