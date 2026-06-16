// hdl-util/hdmi wrapper: flat ports for the Verilog top. Based verbatim on the
// proven Step-5 wrapper (research/05-hdmi-beep/hdmi_wrap.sv) so we stay on the
// exact HDMI config that already works on this board; the only change is stereo
// audio - the ZX core gives separate left/right (AY+beeper+tape) instead of one
// mono PCM word. cx/cy are exposed as 11-bit (720p50: cx<1980, cy<750 both fit).
module hdmi_wrap (
    input  wire clk_pixel_x5,
    input  wire clk_pixel,
    input  wire clk_audio,
    input  wire reset,
    input  wire [23:0] rgb,
    input  wire [15:0] audio_left,
    input  wire [15:0] audio_right,
    output wire [2:0] tmds,
    output wire tmds_clock,
    output wire [10:0] cx,
    output wire [10:0] cy
);
    logic [15:0] audio_word [1:0];
    assign audio_word[0] = audio_left;   // hdl-util: index 0 = LEFT
    assign audio_word[1] = audio_right;  //           index 1 = RIGHT
    hdmi #(
        .VIDEO_ID_CODE(19), .VIDEO_REFRESH_RATE(50.0),
        .AUDIO_RATE(48000), .AUDIO_BIT_WIDTH(16)
    ) hdmi_ (
        .clk_pixel_x5(clk_pixel_x5), .clk_pixel(clk_pixel), .clk_audio(clk_audio),
        .reset(reset),
        .rgb(rgb), .audio_sample_word(audio_word),
        .tmds(tmds), .tmds_clock(tmds_clock),
        .cx(cx), .cy(cy),
        .frame_width(), .frame_height(), .screen_width(), .screen_height()
    );
endmodule
