`timescale 1ns / 1ps

//
// The other half of the serial console: 8N1 out, so a testbench can type at
// the monitor prompt.
//
// The machine boots to `>' and then waits for a human.  Everything past that
// point -- reading a register the PROM never maps, walking the page map,
// asking what the Ethernet PHY negotiated -- has until now only been checkable
// by hand.  With this, `make -C sim board MACHINE=vme' can type the commands
// itself and check_console.sh can grep the answers.
//
// Timing is generous on purpose.  The SCC is receiving at 9600 baud off a
// 4.9152 MHz clock and the PROM echoes every character through its own
// getline(), so nothing here is trying to be fast; the inter-character gap is
// a whole bit time longer than the standard needs.
//
module uart_console #(
    parameter int BAUD = 9600
) (
    output logic tx
);

   localparam real BIT_TIME = 1.0e9 / real'(BAUD);   // ns, matching `timescale

   initial tx = 1'b1;                                // idle mark

   task automatic send_byte(input byte unsigned c);
      begin
         tx = 1'b0;                                  // start
         #(BIT_TIME);
         for (int i = 0; i < 8; i++) begin
            tx = c[i];
            #(BIT_TIME);
         end
         tx = 1'b1;                                  // stop, and then some
         #(BIT_TIME * 2);
      end
   endtask

   // A carriage return is what the monitor's getline() ends on -- not a
   // newline, which it ignores.
   task automatic send(input string s);
      begin
         for (int i = 0; i < s.len(); i++)
           send_byte(byte'(s[i]));
      end
   endtask

   task automatic send_line(input string s);
      begin
         send(s);
         send_byte(8'h0D);
      end
   endtask

endmodule
