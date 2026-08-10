// 8-line to 3-line priority encoder

module ttl_74LS148(input EI_n,
		   input [7:0] 	I_n,
		   output 	EO_n,
		   output 	GS_n,
		   output [2:0] A_n);

   reg EO;
   reg GS;
   reg [2:0] A;

   always @(*)
     begin
	if (EI_n)
	  begin
	     EO = 0;
	     GS = 0;
	     A = 3'b000;
	  end
	else
	  begin
	     EO = 0;
	     GS = 1;

	     casez (I_n)
	       8'b0???????: A = 3'b111;
	       8'b10??????: A = 3'b110;
	       8'b110?????: A = 3'b101;
	       8'b1110????: A = 3'b100;
	       8'b11110???: A = 3'b011;
	       8'b111110??: A = 3'b010;
	       8'b1111110?: A = 3'b001;
	       8'b11111110: A = 3'b000;
	       8'b11111111:
		 begin
		    EO = 1;
		    GS = 0;
		    A = 3'b000;
		 end
	       default: A = 3'b000;
	     endcase
	  end
     end

   assign EO_n = ~EO;
   assign GS_n = ~GS;
   assign A_n = ~A;

endmodule
