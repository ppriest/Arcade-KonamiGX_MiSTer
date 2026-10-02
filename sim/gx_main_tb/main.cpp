// SPDX-License-Identifier: GPL-3.0-or-later
//
// Verilator main for sim/gx_main_tb: drives the 48 MHz clock and saves or
// restores the whole simulation, so that a run can start after the boot
// instead of at reset. scripts/run_verilator.sh builds with this file when
// it exists (--cc --exe --savable, no --timing: Verilator cannot save a
// --timing model).
//
//   +SAVE=<file> +SAVE_AT=<frame>   save when the bench's frame count reaches
//                                   <frame> (at the vblank marker, the trace
//                                   flushed), then stop
//   +RESTORE=<file>                 start from a saved simulation
//
// A snapshot holds everything the bench loaded (ROM images, EEPROM, the
// sound replies): restoring does not read them again. See
// scripts/check_gx_main.py --save-at / --from.

#include <cstdio>
#include <fcntl.h>
#include <cstdlib>
#include <memory>
#include <string>

#include "Vtb_gx_main.h"
#include "verilated.h"
#include "verilated_save.h"

double sc_time_stamp() { return 0; }                 // required of a custom main; time is the context's

static std::string plus(VerilatedContext* ctx, const char* name) {
    std::string key = std::string(name) + "=";
    const char* m = ctx->commandArgsPlusMatch(key.c_str());
    if (!m || !*m) return "";
    return std::string(m).substr(key.size() + 1);      // past the '+'
}

int main(int argc, char** argv) {
#ifdef _WIN32
    _fmode = _O_BINARY;    // VerilatedSave opens with open(): in text mode Windows turns each 0x0a into 0d 0a
#endif
    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);
    auto top = std::make_unique<Vtb_gx_main>(ctx.get(), "TOP");

    std::string save = plus(ctx.get(), "SAVE"), restore = plus(ctx.get(), "RESTORE");
    std::string at = plus(ctx.get(), "SAVE_AT");
    long save_at = at.empty() ? -1 : std::atol(at.c_str());

    unsigned rises = 0;                                // clk rises, for clk_cpu's phase
    if (!restore.empty()) {
        VerilatedRestore os;
        os.open(restore.c_str());
        uint64_t t;
        os >> t >> *top;                               // the context has no serialiser: its time
        ctx->time(t);
        os.close();
        ctx->commandArgs(argc, argv);                  // this run's plusargs, not the saved run's
        ctx->gotFinish(false);                         // a snapshot taken at its run's last frame
                                                       // was saved with $finish already called
        top->reopen = 1;
        rises = top->clk_cpu ? 1 : 0;                  // keep the two clocks' phase
        std::printf("restored %s\n", restore.c_str());
    }

    while (!ctx->gotFinish()) {
        top->clk = !top->clk;
        if (top->clk) top->clk_cpu = !(rises++ & 1);   // 24 MHz, rising with every other clk rise
        ctx->timeInc(10417);                           // half of 48 MHz, in the bench's 1 ps
        top->eval();
        if (top->clk) {
            top->reopen = 0;                           // sampled by exactly one rising edge
            if (save_at >= 0 && (long)top->frame_o >= save_at) {
                VerilatedSave os;
                os.open(save.c_str());
                uint64_t t = ctx->time();
                os << t << *top;
                os.close();
                std::printf("SAVED %s at frame %ld\n", save.c_str(), (long)top->frame_o);
                break;
            }
        }
    }
    top->final();
    return 0;
}
