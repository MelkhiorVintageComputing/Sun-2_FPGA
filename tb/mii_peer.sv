`timescale 1ns / 1ps

//
// A benign MII link for simulation: clocks, an idle receive side, and no
// carrier or collisions.
//
// This is not decoration.  The boot PROM's driver waits on the 82586 with no
// timeout anywhere -- `while (scb->ie_cmd != 0)` and `while (!cb->ie_done)` in
// iesimple(), and the same shape in iexmit() -- so a transmit that never
// completes hangs the machine solid, with no message and no bus error to show
// for it.  The transmit datapath is clocked by mii_tx_clk, which on real
// hardware comes from the PHY.  With no PHY and no clock, the first TRANSMIT
// command never finishes and the PROM stops dead.
//
// It can also *send*.  Nothing in this project had ever driven rx_dv high --
// mii_peer had no tasks at all and the receive path of neither Ethernet card
// had been simulated even once -- so send_frame() below is new ground rather
// than a convenience, and it is the instrument the 3C400's buffer ownership,
// RBBA, doff and address filter are all measured with.
//
// Holding crs and col inactive is the other half: mii_tx defers to carrier
// sense before transmitting, so a carrier stuck active would also hang it.
// An unplugged AUI is quiet, which is what we model.
//
// The line rate is ours to pick in simulation, and it is the cheapest knob for
// bus pressure: BIT_PERIOD_NS = 100 is 10 Mb/s, the rate a Sun-2 actually ran.
// Four bits per MII clock, so the clock period is four times that.
//
module mii_peer #(
    parameter int PHY_DATA_W   = 4,
    parameter int BIT_PERIOD_NS = 100   // 100 ns/bit = 10 Mb/s
) (
    output reg                   mii_tx_clk,
    input  wire [PHY_DATA_W-1:0] mii_txd,
    input  wire                  mii_tx_en,
    input  wire                  mii_tx_er,
    output reg                   mii_rx_clk,
    output reg  [PHY_DATA_W-1:0] mii_rxd,
    output reg                   mii_rx_dv,
    output reg                   mii_rx_er,
    output reg                   mii_crs,
    output reg                   mii_col
);

   localparam real HALF = (BIT_PERIOD_NS * PHY_DATA_W) / 2.0;

   initial begin
      mii_tx_clk = 1'b0;
      mii_rx_clk = 1'b0;
      mii_rxd    = '0;
      mii_rx_dv  = 1'b0;
      mii_rx_er  = 1'b0;
      mii_crs    = 1'b0;   // quiet line: nothing to defer to
      mii_col    = 1'b0;   // and nobody to collide with
   end

   // +crs_stuck jams carrier sense on, which is what a PHY out of reset, with
   // no link, or with CRS wired to a pull-up looks like -- the Wukong pulls it
   // up through R59.  Without a deferral timeout in the MAC this hangs the boot
   // PROM outright, so this is how that defence gets tested rather than assumed.
   int crs_stuck = 0;
   initial begin
      void'($value$plusargs("crs_stuck=%d", crs_stuck));
      if (crs_stuck != 0) begin
         $display("mii_peer: holding carrier sense asserted -- the medium never goes idle");
         #1 mii_crs = 1'b1;
      end
   end

   // Two clocks of the same rate but deliberately not the same edge, as a PHY's
   // would be: the MAC crosses between them with gray-coded FIFOs and a
   // four-phase handshake, and running them in lockstep would hide a fault in
   // either.
   always #(HALF)         mii_tx_clk = ~mii_tx_clk;
   always #(HALF * 1.013) mii_rx_clk = ~mii_rx_clk;

   // Count what the machine puts on the wire.  With no server out there the
   // PROM will send ND boot requests and get nothing back, so this is the
   // evidence that the transmit path ran at all.
   int frames = 0;
   always @(posedge mii_tx_clk)
     if (mii_tx_en && !$past(mii_tx_en, 1)) begin
        frames++;
        $display("[%t] mii_peer: frame %0d begins on the wire", $realtime, frames);
     end

   // ------------------------------------------------------------------
   // Capture, so a test can compare the wire byte for byte
   // ------------------------------------------------------------------
   // Everything between tx_en rising and falling, preamble and SFD included --
   // the MAC drives those itself and a test that wants to check them should be
   // able to.  tx_last is republished only on the falling edge, so a test that
   // waits on tx_frames is guaranteed a complete frame rather than a partial
   // one, which is the mistake the equivalent code in tb_mb_ether makes by
   // sampling mid-transmission.
   byte unsigned tx_cur[$];
   byte unsigned tx_last[$];
   int           tx_frames = 0;
   reg [3:0]     tx_lo;
   bit           tx_phase = 0;

   always @(posedge mii_tx_clk) begin
      if (mii_tx_en) begin
         if (!tx_phase) begin tx_lo <= mii_txd; tx_phase <= 1'b1; end
         else begin tx_cur.push_back({mii_txd, tx_lo}); tx_phase <= 1'b0; end
      end else if (tx_cur.size() != 0) begin
         tx_last   = tx_cur;
         tx_cur    = {};
         tx_phase  = 1'b0;
         tx_frames = tx_frames + 1;
      end
   end

   // +dump_tx decodes what the machine put on the wire.  "A frame was
   // transmitted" is a much weaker fact than it looks: a card that sends a
   // frame with the wrong source address, or a broadcast that is not
   // broadcast, is indistinguishable from a working one until a server fails
   // to answer it -- at which point the fault looks like the server's.  This
   // is the cheap way to tell those apart before touching hardware.
   int dump_tx = 0;
   initial void'($value$plusargs("dump_tx=%d", dump_tx));

   always @(tx_frames) if (dump_tx != 0 && tx_last.size() > 22) begin
      automatic int n = tx_last.size();
      // The first eight bytes are preamble and SFD, which the MAC drives
      // itself; the frame proper starts at 8.
      $display("[%t] mii_peer: frame %0d, %0d bytes on the wire (%0d of frame)",
               $realtime, tx_frames, n, n - 8);
      $display("            preamble %02x %02x %02x %02x %02x %02x %02x sfd %02x",
               tx_last[0], tx_last[1], tx_last[2], tx_last[3],
               tx_last[4], tx_last[5], tx_last[6], tx_last[7]);
      $display("            dst %02x:%02x:%02x:%02x:%02x:%02x  src %02x:%02x:%02x:%02x:%02x:%02x  type %02x%02x",
               tx_last[8],  tx_last[9],  tx_last[10], tx_last[11], tx_last[12], tx_last[13],
               tx_last[14], tx_last[15], tx_last[16], tx_last[17], tx_last[18], tx_last[19],
               tx_last[20], tx_last[21]);
      $display("            fcs %02x %02x %02x %02x",
               tx_last[n-4], tx_last[n-3], tx_last[n-2], tx_last[n-1]);
   end

   // ------------------------------------------------------------------
   // Transmit into the machine
   // ------------------------------------------------------------------
   // The Ethernet FCS: reflected CRC-32, init and final xor all-ones, and the
   // four bytes go on the wire least-significant first.  Computed here rather
   // than reusing crc32_eth so that the model and the thing under test are
   // independent -- a shared implementation would agree with itself about a
   // wrong polynomial.
   function automatic logic [31:0] eth_fcs(ref byte unsigned d[$]);
      logic [31:0] c = 32'hFFFFFFFF;
      foreach (d[i]) begin
         c = c ^ {24'h0, d[i]};
         for (int b = 0; b < 8; b++)
           c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
      end
      return ~c;
   endfunction

   task automatic put_byte(input byte unsigned v);
      @(posedge mii_rx_clk); #1;  mii_rxd = v[3:0];   // low nibble first
      @(posedge mii_rx_clk); #1;  mii_rxd = v[7:4];
   endtask

   // bad_fcs corrupts the checksum without touching the data, which is how the
   // FCSERR status bit is tested; the frame is otherwise well formed, so a
   // card that silently accepted it would be doing so for the right length.
   task automatic send_frame(ref byte unsigned f[$], input bit bad_fcs = 0);
      logic [31:0] crc;
      crc = eth_fcs(f);
      if (bad_fcs) crc = crc ^ 32'h0000_0001;

      // A real PHY raises carrier sense for the whole of a received frame, and
      // it matters: mii_tx defers to crs, so a card told to transmit into an
      // arriving frame must wait.  Modelling the line as always idle would let
      // a half-duplex bug through untouched.
      @(posedge mii_rx_clk); #1;
      mii_crs   = 1'b1;
      // rx_dv covers the preamble, not just the data.  mii_rx leaves RX_IDLE
      // on rx_dv and only then hunts for the delimiter, so raising it at the
      // SFD instead -- which reads plausibly -- means the receiver enters
      // RX_PREAMBLE one nibble late and eats the first data nibble.
      mii_rx_dv = 1'b1;

      // Seven octets of 0x55 and the 0xD5 start delimiter.  On MII the
      // delimiter is recognised by its second nibble, 0xD; the first, 0x5, is
      // indistinguishable from preamble and is meant to be.
      for (int i = 0; i < 7; i++) put_byte(8'h55);
      put_byte(8'hD5);

      foreach (f[i]) put_byte(f[i]);
      put_byte(crc[7:0]);
      put_byte(crc[15:8]);
      put_byte(crc[23:16]);
      put_byte(crc[31:24]);

      @(posedge mii_rx_clk); #1;
      mii_rx_dv = 1'b0;
      mii_rxd   = 4'h0;
      if (crs_stuck == 0) mii_crs = 1'b0;

      // 96 bit times of interframe gap, which at four bits a clock is 24.
      repeat (24) @(posedge mii_rx_clk);
   endtask

endmodule
