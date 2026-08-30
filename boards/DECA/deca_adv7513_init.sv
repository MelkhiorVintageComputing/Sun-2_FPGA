`timescale 1ns / 1ps

`include "sun2_attr.vh"

//
// Bring the DECA's ADV7513 up and keep it up.
//
// The Wukong makes HDMI itself -- an MMCM, a 5x bit clock, eight OSERDESE2 and
// four OBUFDS turning pixels into TMDS.  The DECA does not: it has a real
// transmitter chip that takes parallel 24-bit RGB with HSYNC, VSYNC and DE on
// pins, and does the encoding in silicon.  The price is that it must be told
// what to do over I2C before it will emit anything at all, and that
// configuration is what this file is.
//
// The third twin of boards/Wukong/phy_rtl8211_init.sv and
// boards/DECA/phy_dp83620_init.sv: a board-layer sequencer that puts a modern
// part into the state a 1982 machine assumes, written here rather than
// imported so that it can be unit-tested (make -C sim adv7513) against an
// independent model of the thing it talks to.
//
// **The register values are not invented.**  They are transcribed from
// Inputs/doc/DECA_board/Tutorials/Porting-Cores/rtl_deca/hdmi/I2C_HDMI_Config.v,
// which is Terasic's own configuration for this exact board, cross-checked
// against the mandatory list in ADV7513_Programming_Guide_RB.pdf section 3.
// What is *not* taken from anywhere is the I2C engine: Terasic's is a
// bit-banged busy-loop on a divided clock that has to be named in the SDC to
// stop it floating, and it never reads the bus back.
//
// Two deliberate departures from the reference, both recorded rather than
// silent:
//
//   * **DVI mode, not HDMI** -- 0xAF bit 1 clear.  The reference sets HDMI
//     mode, which commits the transmitter to sending infoframes and audio
//     packets we do not generate.  boards/Wukong instantiates its encoder with
//     DVI_OUTPUT(1'b1) for the same reason, so this matches what the project
//     already puts on a monitor.  If a sink ever refuses it, 0x14 -> 0x16 is
//     the whole change.
//
//   * **No audio.**  The reference's twelve audio registers (N value, channel
//     status, I2S format, speaker allocation) are dropped, leaving 27 writes.
//     The chip has an I2S port and the board wires it; nothing here has a
//     sample to send it.
//
// What is deliberately *not* done yet: reading 0x42[6] to find out whether hot
// plug detect actually went high before powering up.  That is the sequence the
// programming guide blesses, and it needs a read path -- an extra direction
// through the bit engine and its own tests -- to avoid replaying the table on
// an interrupt that was not a plug event.  Replaying unconditionally is what
// both working references do and is harmless; the refinement is worth having
// only once there is a reason to think spurious interrupts are happening.
//
module deca_adv7513_init #(
    // 50 MHz in, ~100 kHz on the wire.  Four ticks to an SCL period, so the
    // divider is CLK_HZ / (SCL_HZ * 4).  Well under the part's 400 kHz limit
    // and far enough under that the on-board 2K pull-ups have no trouble.
    parameter int CLK_HZ  = 50_000_000,
    parameter int SCL_HZ  = 100_000,

    // The programming guide asks for 200 ms after the supplies are up before
    // talking to the part, because the I2C address is latched from the PD/AD
    // strap during power-up.  An FPGA that has just been configured is long
    // past that, but a board that has just been switched on may not be.
    // Overridden to something tiny by the testbench.
    parameter int STARTUP_CLKS = CLK_HZ / 5,

    // 0x72 write address: PD/AD is strapped low on this board, which the
    // schematic annotates as "Default: I2C Address 0x72/0x73".
    parameter logic [7:0] SLAVE_ADDR = 8'h72
) (
    input  wire        clk,
    input  wire        rst,

    // Open drain.  There is no output data line: I2C only ever pulls down, and
    // the board's pull-ups do the rest.  The top ties these to 1'b0 or 1'bz.
    output wire        scl_oe,      // 1 = pull SCL low
    output wire        sda_oe,      // 1 = pull SDA low
    input  wire        sda_i,

    // ADV7513 INT, active low, asynchronous.  Hot plug detect is not routed to
    // the FPGA on this board -- it goes from the connector to the transmitter
    // and stops -- so this pin is the only news we ever get about the cable.
    input  wire        int_n,

    // Observability, for the ISSP panel: has the table been sent, and how many
    // times.  A replay counter that climbs on its own is a bouncing cable or a
    // sink that keeps re-asserting, and neither is visible any other way.
    output wire        cfg_done,
    // Sticky: at least one byte of the last pass went unacknowledged.  Worth a
    // pin of its own because "the part is not there at all" and "the part is
    // there and the picture is still black" are different problems and look
    // identical from outside.
    output reg         cfg_nak,
    output reg  [7:0]  cfg_passes
);

   // ------------------------------------------------------------------
   // The table
   // ------------------------------------------------------------------
   localparam int N_REGS = 27;

   // {sub-address, value}.  Order matters in one place only -- 0x41 powers the
   // part up and everything the guide calls "fixed" should be in before that
   // matters -- but the reference sends them in this order and it works, so
   // this is its order with the audio entries removed.
   function automatic logic [15:0] entry(input int i);
      case (i)
        0:  entry = 16'h98_03;   // ADI fixed: must be 0x03 for proper operation
        1:  entry = 16'h15_20;   // input ID 0: 24-bit RGB 4:4:4, separate syncs
        2:  entry = 16'h16_30;   // output 4:4:4, 8-bit colour depth
        3:  entry = 16'h18_46;   // CSC disabled
        4:  entry = 16'h40_80;   // general control packet enable
        5:  entry = 16'h41_10;   // POWER UP.  The part comes up powered down.
        6:  entry = 16'h49_A8;   // dither 12->10, default
        7:  entry = 16'h55_10;   // AVI infoframe: RGB
        8:  entry = 16'h56_08;   // AVI: active format same as aspect ratio
        9:  entry = 16'h96_F6;   // clear all interrupt status (write 1 to clear)
        10: entry = 16'h98_03;   // ADI fixed (again, as the reference does)
        11: entry = 16'h99_02;   // ADI fixed
        12: entry = 16'h9A_E0;   // ADI fixed: [7:5] must be 0b111
        13: entry = 16'h9C_30;   // ADI fixed: PLL filter R1
        14: entry = 16'h9D_61;   // ADI fixed: [1:0]=01, clock not divided
        15: entry = 16'hA2_A4;   // ADI fixed: must be 0xA4
        16: entry = 16'hA3_A4;   // ADI fixed: must be 0xA4
        17: entry = 16'hA5_04;   // default
        18: entry = 16'hAB_40;   // default
        19: entry = 16'hAF_14;   // DVI mode (bit 1 clear) -- see the header
        20: entry = 16'hBA_60;   // TMDS clock delay: none
        21: entry = 16'hD1_FF;   // default
        22: entry = 16'hDE_10;   // default
        23: entry = 16'hE4_60;   // default
        24: entry = 16'hFA_7C;   // phase-search retries
        25: entry = 16'hE0_D0;   // ADI fixed -- omitted by BrianHG's table
        26: entry = 16'hF9_00;   // ADI fixed -- omitted by BrianHG's table
        default: entry = 16'h98_03;
      endcase
   endfunction

   // ------------------------------------------------------------------
   // Bit timing
   // ------------------------------------------------------------------
   // Four phases to an SCL period, which is the least that lets START and STOP
   // be expressed as an SDA edge in the middle of an SCL high:
   //
   //   phase 0   SCL low, SDA changes here
   //   phase 1   SCL rises
   //   phase 2   SCL high, the slave's ACK is sampled here
   //   phase 3   SCL falls
   //
   localparam int DIV = CLK_HZ / (SCL_HZ * 4);

   reg [$clog2(DIV+1)-1:0] divcnt;
   wire                    tick = (divcnt == DIV[$clog2(DIV+1)-1:0] - 1'b1);
   always @(posedge clk)
     if (rst)      divcnt <= '0;
     else if (tick) divcnt <= '0;
     else          divcnt <= divcnt + 1'b1;

   reg [1:0] phase;
   always @(posedge clk)
     if (rst)       phase <= 2'd0;
     else if (tick) phase <= phase + 2'd1;

   wire ph_setup = (phase == 2'd0);

   // ------------------------------------------------------------------
   // Sequencer
   // ------------------------------------------------------------------
   localparam [3:0] S_WAIT  = 4'd0,   // power-on / restart delay
                    S_START = 4'd1,
                    S_ADDR  = 4'd2,
                    S_SUB   = 4'd3,
                    S_DATA  = 4'd4,
                    S_ACK   = 4'd5,
                    S_STOP  = 4'd6,
                    S_NEXT  = 4'd7,
                    S_DONE  = 4'd8;

   reg [3:0]  st, ret;
   reg [2:0]  bitno;
   reg [7:0]  shift;
   reg [4:0]  idx;
   reg [31:0] delay;
   reg        scl_lo, sda_lo;
   reg        ack_bad;

   wire [15:0] cur = entry(int'(idx));

   // int_n is asynchronous and this is the one input we have.
   `SUN2_ASYNC_REG reg int_s1, int_s2, int_s3;
   always @(posedge clk) begin
      int_s1 <= int_n;
      int_s2 <= int_s1;
      int_s3 <= int_s2;
   end
   wire int_fell = int_s3 & ~int_s2;

   assign scl_oe   = scl_lo;
   assign sda_oe   = sda_lo;
   assign cfg_done = (st == S_DONE);

   always @(posedge clk) begin
      if (rst) begin
         st         <= S_WAIT;
         ret        <= S_ADDR;
         bitno      <= 3'd7;
         shift      <= 8'h0;
         idx        <= 5'd0;
         delay      <= STARTUP_CLKS;
         scl_lo     <= 1'b1;      // hold the bus down until we are ready
         sda_lo     <= 1'b0;
         ack_bad    <= 1'b0;
         cfg_nak    <= 1'b0;
         cfg_passes <= 8'd0;
      end else begin
         case (st)

           // Idle the bus high, count down, then begin.
           S_WAIT: begin
              scl_lo <= 1'b0;
              sda_lo <= 1'b0;
              if (delay != 0) delay <= delay - 1'b1;
              else if (tick && ph_setup) begin
                 idx     <= 5'd0;
                 ack_bad <= 1'b0;
                 st      <= S_START;
              end
           end

           // START: SDA falls while SCL is high.
           S_START:
             if (tick) case (phase)
               2'd0: sda_lo <= 1'b0;
               2'd1: scl_lo <= 1'b0;          // SCL high
               2'd2: sda_lo <= 1'b1;          // SDA low with SCL high = START
               2'd3: begin
                  scl_lo <= 1'b1;
                  shift  <= SLAVE_ADDR;
                  bitno  <= 3'd7;
                  st     <= S_ADDR;
                  ret    <= S_SUB;
               end
             endcase

           // The three byte states share one shifter; `ret' says what follows
           // the acknowledgement.
           S_ADDR, S_SUB, S_DATA:
             if (tick) case (phase)
               2'd0: sda_lo <= ~shift[7];     // MSB first, drive low for a 0
               2'd1: scl_lo <= 1'b0;
               2'd2: ;                        // slave samples here
               2'd3: begin
                  scl_lo <= 1'b1;
                  if (bitno == 3'd0) begin
                     sda_lo <= 1'b0;          // release for the ACK bit
                     st     <= S_ACK;
                  end else begin
                     shift <= {shift[6:0], 1'b0};
                     bitno <= bitno - 3'd1;
                  end
               end
             endcase

           S_ACK:
             if (tick) case (phase)
               2'd0: sda_lo <= 1'b0;          // stay released
               2'd1: scl_lo <= 1'b0;
               2'd2: if (sda_i) ack_bad <= 1'b1;   // 1 = nobody pulled it down
               2'd3: begin
                  scl_lo <= 1'b1;
                  bitno  <= 3'd7;
                  case (ret)
                    S_SUB:  begin shift <= cur[15:8]; st <= S_SUB;  ret <= S_DATA; end
                    S_DATA: begin shift <= cur[7:0];  st <= S_DATA; ret <= S_STOP; end
                    default: st <= S_STOP;
                  endcase
               end
             endcase

           // STOP: SDA rises while SCL is high.
           S_STOP:
             if (tick) case (phase)
               2'd0: sda_lo <= 1'b1;
               2'd1: scl_lo <= 1'b0;          // SCL high, SDA still low
               2'd2: sda_lo <= 1'b0;          // SDA released = STOP
               2'd3: st <= S_NEXT;
             endcase

           S_NEXT:
             if (tick && ph_setup) begin
                if (idx == N_REGS[4:0] - 1'b1) begin
                   cfg_passes <= cfg_passes + 8'd1;
                   cfg_nak    <= ack_bad;
                   st         <= S_DONE;
                end else begin
                   idx <= idx + 5'd1;
                   st  <= S_START;
                end
             end

           // Configured.  The only thing that can happen now is the cable.
           //
           // The part powers itself down when HPD goes away and resets much of
           // its register file, so there is nothing to do but send the whole
           // table again.  Waiting on the falling edge rather than the level
           // matters: INT is level-sensitive and the only thing that clears it
           // is the 0x96 write partway through the replay, so a level trigger
           // would restart the table on top of itself.
           S_DONE:
             if (int_fell) begin
                delay <= STARTUP_CLKS;
                st    <= S_WAIT;
             end

           default: st <= S_WAIT;
         endcase
      end
   end

endmodule
