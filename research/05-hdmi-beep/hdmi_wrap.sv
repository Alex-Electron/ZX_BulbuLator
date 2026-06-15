// Обёртка hdl-util/hdmi: плоские порты для Verilog-топа
module hdmi_wrap (
    input  wire clk_pixel_x5,
    input  wire clk_pixel,
    input  wire clk_audio,
    input  wire reset,
    input  wire [23:0] rgb,
    input  wire [15:0] audio_pcm,
    output wire [2:0] tmds,
    output wire tmds_clock,
    output wire [10:0] cx,
    output wire [10:0] cy
);
    logic [15:0] audio_word [1:0];
    assign audio_word[0] = audio_pcm;
    assign audio_word[1] = audio_pcm;
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
