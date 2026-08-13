`timescale 1ns / 1ps

//
// Serial console monitor: decodes the SCC channel A transmit line as 8N1 and
// prints what the boot PROM is saying, both to stdout and to a log file.
//
// The old design dumped TxDA into a VCD and decoded it by hand in pulseview;
// this makes "did it reach the monitor prompt?" answerable by grep.
//
// The monitor also measures the shortest observed pulse on the line.  With
// 8N1 traffic that is one bit time, so the implied baud rate is reported at
// the end of the run -- an immediate check that the SCC's clock is what we
// think it is (get clk4m9152 wrong and everything decodes as garbage).
//

module uart_monitor #(
    parameter int    BAUD    = 9600,
    parameter string LOGFILE = "console.log"
) (
    input wire rx      // the DUT's tx line
);

   localparam real BIT_TIME = 1.0e9 / real'(BAUD);   // in ns, matching `timescale

   integer      logfd;
   int unsigned nchars = 0;

   // shortest observed pulse, used to sanity-check the line rate
   realtime     last_edge = 0;
   realtime     min_pulse = 0;

   // rolling tail of the output, so we can stop as soon as a wanted string shows up
   string       tail = "";
   string       stop_on = "";
   bit          stop_seen = 0;

   // A second, longer tail that wait_for() searches.  Kept separate from
   // `tail' above, which is trimmed to exactly stop_on's length.
   localparam int RECENT_LEN = 256;
   string       recent = "";

   initial begin
      logfd = $fopen(LOGFILE, "w");
      if (logfd == 0)
        $display("[uart] WARNING: cannot open %s for writing", LOGFILE);
      void'($value$plusargs("stop_on=%s", stop_on));
   end

   // pulse-width measurement
   always @(rx) begin
      if (last_edge != 0) begin
         automatic realtime w = $realtime - last_edge;
         if (min_pulse == 0 || w < min_pulse) min_pulse = w;
      end
      last_edge = $realtime;
   end

   // 8N1 receiver
   initial begin
      byte unsigned c;
      forever begin
         @(negedge rx);                 // start bit
         #(BIT_TIME * 1.5);             // sample in the middle of bit 0
         for (int i = 0; i < 8; i++) begin
            c[i] = rx;
            if (i != 7) #(BIT_TIME);
         end
         #(BIT_TIME);                   // into the stop bit
         if (rx !== 1'b1)
           $display("[uart] framing error at %t (got %02x)", $realtime, c);

         nchars++;
         if (logfd != 0) begin
            $fwrite(logfd, "%c", c);
            $fflush(logfd);
         end
         $write("%c", c);
         $fflush();

         recent = {recent, string'(c)};
         if (recent.len() > RECENT_LEN)
           recent = recent.substr(recent.len() - RECENT_LEN, recent.len() - 1);

         if (stop_on.len() > 0) begin
            tail = {tail, string'(c)};
            if (tail.len() > stop_on.len())
              tail = tail.substr(tail.len() - stop_on.len(), tail.len() - 1);
            if (tail == stop_on) stop_seen = 1;
         end
      end
   end

   //
   // Block until `what' has come out of the console, or give up after
   // `limit_ns'.  Returns 1 if it appeared.
   //
   // The search window is cleared first, so waiting twice for the same prompt
   // does not match the previous one -- which is exactly what a sequence of
   // monitor commands does, every one of them ending in "? ".
   //
   function automatic bit contains(input string hay, input string needle);
      begin
         contains = 0;
         if (needle.len() == 0 || hay.len() < needle.len()) return 0;
         for (int i = 0; i <= hay.len() - needle.len(); i++)
           if (hay.substr(i, i + needle.len() - 1) == needle) return 1;
      end
   endfunction

   task automatic wait_for(input string what, input realtime limit_ns, output bit ok);
      realtime deadline;
      begin
         recent   = "";
         deadline = $realtime + limit_ns;
         ok       = 0;
         while ($realtime < deadline) begin
            if (contains(recent, what)) begin
               ok = 1;
               return;
            end
            #(BIT_TIME);
         end
         $display("[uart] TIMEOUT waiting for \"%s\" at %t; last saw \"%s\"",
                  what, $realtime, recent);
      end
   endtask

   task automatic report();
      $display("");
      $display("[uart] %0d characters received", nchars);
      if (min_pulse > 0)
        $display("[uart] shortest pulse %0.3f ns => %0.0f baud (configured %0d)",
                 min_pulse, 1.0e9 / min_pulse, BAUD);
   endtask

endmodule
