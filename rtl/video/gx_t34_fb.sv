// The Type 3/4 boards' two monitors on HDMI (docs/TYPE34.md, "Screens on
// MiSTer"). The board draws the monitors on alternate frames, vid_sub
// saying which; the demux board held each monitor's picture. Here the
// frames go to the scaler's framebuffer in DDR3, as screen_rotate_two (the
// PsikyoSH2 core's) writes it:
//
//   mode 0, First:  the main monitor's frames only
//   mode 1, Second: the sub monitor's frames only
//   mode 2, Both:   side by side, main left, sub right
//   mode 3, Stacked CCW: each monitor turned 90 degrees CCW, main left, sub
//                   right: main above sub on a panel turned clockwise
//   mode 4, Stacked CW: each turned CW, main right, sub left: main above
//                   sub on a panel turned counter-clockwise
//
// The turned modes write a pixel a beat down a column, as sys/arcade_video.v's
// screen_rotate does (and, like it, without waiting on DDRAM_BUSY).
//
// Three buffers: one written, one shown, and at most one finished and
// waiting. The shown buffer moves only to a finished one, so a monitor's
// 30 Hz picture is not interleaved with an older frame on a 60 Hz output.
// In Both and the stacked modes the written buffer is finished by the sub
// frame, so a pair of frames is one picture.
module gx_t34_fb (
    input             CLK_VIDEO,
    input             CE_PIXEL,
    input      [ 7:0] VGA_R,
    input      [ 7:0] VGA_G,
    input      [ 7:0] VGA_B,
    input             VGA_VS,
    input             VGA_DE,

    input             vid_sub,      // the frame now being sent is the sub monitor's (clk_sys)
    input      [ 2:0] mode_in,      // the OSD's (clk_sys): registered here

    output            FB_EN,
    output     [ 4:0] FB_FORMAT,
    output reg [11:0] FB_WIDTH,
    output reg [11:0] FB_HEIGHT,
    output     [31:0] FB_BASE,
    output     [13:0] FB_STRIDE,
    input             FB_VBL,

    output            DDRAM_CLK,
    input             DDRAM_BUSY,
    output     [ 7:0] DDRAM_BURSTCNT,
    output     [28:0] DDRAM_ADDR,
    output     [63:0] DDRAM_DIN,
    output     [ 7:0] DDRAM_BE,
    output            DDRAM_WE,
    output            DDRAM_RD
);

localparam [6:0] MEM_BASE = 7'b0010010;     // 0x24000000, 3 x 8 MB, as screen_rotate_two

reg  [ 2:0] mode = 3'd0;
always @(posedge CLK_VIDEO) mode <= mode_in;
reg  [ 1:0] i_fb = 2'd0, o_fb = 2'd1, r_fb = 2'd2;
reg         ready = 1'b0;                   // r_fb holds a finished picture
reg  [ 2:0] fb_en = 3'd0;
reg  [11:0] hsz = 12'd288, vsz = 12'd224;
reg  [22:0] ram_addr, line_addr, next_addr;
reg  [31:0] ram_data;
reg         ram_wr;
reg  [ 1:0] sub_s;
reg         fr_sub = 1'b0, fr_wr = 1'b0;    // the frame being sent, from its active lines
reg         got_main = 1'b0;                // a pair: its main frame is in i_fb
wire        sub    = sub_s[1];              // steady through the active lines
wire        both   = mode == 3'd2;
wire        ccw    = mode == 3'd3;
wire        rot    = mode == 3'd3 || mode == 3'd4;
wire        pair   = both || rot;               // both monitors in one picture
wire        wr_now = pair || sub == mode[0];
wire [11:0] fbw    = both ? { hsz[10:0], 1'b0 } : rot ? { vsz[10:0], 1'b0 } : hsz;
wire [13:0] stride = { fbw[11:2] + 10'd1, 4'd0 };   // 4 bytes a pixel, 16-byte rows

assign DDRAM_CLK      = CLK_VIDEO;
assign DDRAM_BURSTCNT = 8'd1;
assign DDRAM_ADDR     = { MEM_BASE, i_fb, ram_addr[22:3] };
assign DDRAM_BE       = ram_addr[2] ? 8'hF0 : 8'h0F;
assign DDRAM_DIN      = { ram_data, ram_data };
assign DDRAM_WE       = ram_wr;
assign DDRAM_RD       = 1'b0;

assign FB_EN     = fb_en[2];
assign FB_FORMAT = 5'b00110;
assign FB_BASE   = { MEM_BASE, o_fb, 23'd0 };
assign FB_STRIDE = stride;

always @(posedge CLK_VIDEO) begin
    FB_WIDTH  <= fbw;
    FB_HEIGHT <= rot ? hsz : vsz;
end

// the picture's size, from the enables
reg [11:0] hcnt = 12'd0, vcnt = 12'd0;
always @(posedge CLK_VIDEO) begin
    reg        old_vs, old_de;
    if( CE_PIXEL ) begin
        old_vs <= VGA_VS;
        old_de <= VGA_DE;
        hcnt <= hcnt + 1'd1;
        if( ~old_de & VGA_DE ) begin hcnt <= 12'd1; vcnt <= vcnt + 1'd1; end
        if( old_de & ~VGA_DE ) hsz <= hcnt;
        if( ~old_vs & VGA_VS ) begin
            vsz   <= vcnt;
            vcnt  <= 12'd0;
            fb_en <= { fb_en[1:0], 1'b1 };
        end
    end
end

// the buffers: a finished one waits in r_fb until the output's vblank
always @(posedge CLK_VIDEO) begin
    reg old_vbl, old_vs, old_de;
    reg vs_ev, vbl_ev, done;
    old_vbl <= FB_VBL;
    sub_s   <= { sub_s[0], vid_sub };
    vbl_ev = ~old_vbl & FB_VBL;
    vs_ev  = 1'b0;
    if( CE_PIXEL ) begin
        old_vs <= VGA_VS;
        old_de <= VGA_DE;
        if( old_de & ~VGA_DE ) begin fr_sub <= sub; fr_wr <= wr_now && FB_EN; end   // as the writes
        vs_ev = ~old_vs & VGA_VS;
    end
    // the frame just sent finished the picture: its monitor's, or the pair's
    // a pair is finished by its sub frame, once its main frame was written
    // (not so for the first frame after FB_EN)
    done = vs_ev && fr_wr && (!pair || (fr_sub && got_main));
    if( vs_ev ) begin
        fr_wr    <= 1'b0;
        got_main <= fr_wr && !fr_sub;
    end
    if( done ) begin
        if( vbl_ev && ready ) begin
            o_fb <= r_fb; r_fb <= i_fb; i_fb <= o_fb;
        end else begin
            r_fb <= i_fb; i_fb <= r_fb;     // a picture still waiting is dropped
        end
        ready <= 1'b1;
    end else if( vbl_ev && ready ) begin
        o_fb <= r_fb; r_fb <= o_fb;
        ready <= 1'b0;
    end
end

// the writes: 32 bits a pixel; in Both the sub monitor's frames start
// half a row in. Turned, a line is a column: CCW from the bottom row up,
// CW from the top down; ly, the line in the frame, picks the column.
reg  [11:0] ly;
reg  [22:0] rbase;                              // the last row's start (CCW)
reg  [11:0] rb_h;
reg  [13:0] rb_s;
wire [11:0] ccol = (sub ? vsz : 12'd0) + ly;                    // CCW: main left
wire [11:0] wcol = (sub ? vsz : { vsz[10:0], 1'b0 }) - 12'd1 - ly;  // CW: main right
always @(posedge CLK_VIDEO) begin
    reg old_vs, old_de;
    ram_wr <= 1'b0;
    // the last row's start, a clock for the product's inputs and one for it
    rb_h   <= hsz - 12'd1;
    rb_s   <= stride;
    rbase  <= 23'(rb_h * rb_s);
    if( CE_PIXEL && FB_EN ) begin
        old_vs <= VGA_VS;
        old_de <= VGA_DE;
        if( ~old_vs & VGA_VS ) begin line_addr <= 23'd0; ly <= 12'd0; end
        if( VGA_DE && wr_now ) begin
            ram_wr   <= 1'b1;
            ram_data <= { 8'd0, VGA_B, VGA_G, VGA_R };
            ram_addr <= next_addr;
        end
        if( VGA_DE ) next_addr <= !rot ? next_addr + 23'd4 :
                                  ccw  ? next_addr - { 9'd0, stride } : next_addr + { 9'd0, stride };
        else         next_addr <= !rot ? line_addr + (both && sub ? { 9'd0, hsz, 2'b00 } : 23'd0) :
                                  ccw  ? rbase + { 9'd0, ccol, 2'b00 } : { 9'd0, wcol, 2'b00 };
        if( old_de & ~VGA_DE ) begin line_addr <= line_addr + { 9'd0, stride }; ly <= ly + 12'd1; end
    end
end

endmodule
