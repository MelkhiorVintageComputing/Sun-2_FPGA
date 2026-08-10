// 8 input myx

module ttl_74F151(input D0,
		   input  D1,
		   input  D2,
		   input  D3,
		   input  D4,
		   input  D5,
		   input  D6,
		   input  D7,
		   input  A,
		   input  B,
		   input  C,
		   output Y,
		   output W,
		   input  S);

   wire [2:0] sel;
   wire       mux;
   assign sel = { C, B, A };

   assign mux =
	       sel == 0 ? D0 :
	       sel == 1 ? D1 :
	       sel == 2 ? D2 :
	       sel == 3 ? D3 :
	       sel == 4 ? D4 :
	       sel == 5 ? D5 :
	       sel == 6 ? D6 :
	       D7;

   assign W = ~S ? mux : 1'b0;
   assign Y = ~S ? ~mux : 1'b1;
   
endmodule

