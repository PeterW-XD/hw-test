/* audio.sv
 * Top Module
 * Author: Sound Localizer
 * Notes:
 * 1. There is a startup time for mic.
 * 2. Contention across clock domains matters.
 */ 
module audio(	
	input logic clk,	// 50M, 20ns
	input logic reset,
	input logic chipselect,
	input logic read,
	input logic write,
	input logic [31:0] writedata,
	input logic [2:0] address,
	input logic SD1,	// Serial data input: microphone set 1
	input logic SD2,	// Set 2
	input logic SD3,	// Reserved
	input logic SCK,	// Sampling rate * 32 bits * 2 channels: 320
	
	output logic WS,	// Sampling rate
	output logic irq,	// Reserved
	output logic [31:0] readdata
);
	
logic rst_n = 0;
logic sck_rst = 1;
logic [3:0] count1 = 4'd0;
logic [3:0] count2 = 4'd0;
logic [5:0] clk_cnt;				// 64 counter to generate WS signal
logic [4:0] stretch_cnt;		// Strech signal for synchro
logic go, go_SCK;				// go command to start sampling and calculation
logic [23:0] right1, left1, right2, left2;  // Temp memory
// RAM for raw data
logic ram_wren;							// write enable for raw data RAM
logic [10:0] wr_addr;				// RAM write address
logic [10:0] rd_addr;				// RAM read address
logic [15:0] ram1_in, ram2_in, ram3_in, ram4_in; // RAM inputs
logic [15:0] ram1q, ram2q, ram3q, ram4q;	// RAM outputs
logic ready1, ready2, ready3, ready4;		// Asserted when raw data RAM is full
logic rdreq1, rdreq2, rdreq3, rdreq4;
// FFT wrapper
logic [27:0] ram1_fft, ram2_fft, ram3_fft, ram4_fft;	// RAM outputs for fft RAM
logic [9:0] rd_addr_hps;		// Read address for fft RAM (testing purpose)
logic fftdone, detectdone;
logic [9:0] rd_addr_fd, maxbin;

enum {IDLE, WRITE, READ} state;

/* Generate reset signal
 */
always_ff @(posedge clk) begin
	count1 <= count1 + 4'd1;
	if (count1 == 4'b1111)
		rst_n <= 1'd1;
end

always_ff @(negedge SCK) begin
	count2 <= count2 + 4'd1;
	if (count2 == 4'b1111)
		sck_rst = 1'd0;
end

/* Go signal synchronizer
 * go -> go_SCK
 * Faster clk -> Slower SCK
 * 320/20 = 16
 * Stretch the go_clk signal so that SCK can get
 */ 
always_ff @(posedge clk) begin
	if (~rst_n) 
		stretch_cnt <= 5'd0;
	else begin
		if (go)
			stretch_cnt <= 5'd16;
		else if (stretch_cnt > 5'd0)
			stretch_cnt <= stretch_cnt - 5'd1;
	end
end

assign go_SCK = (stretch_cnt > 0) ? 1'd1 : 1'd0;

/* WS clock generator
 * 64 division
 */
always_ff @(negedge SCK) begin // Negedge of SCK
	if (sck_rst) begin
		clk_cnt <=  6'd0;
	end else begin
		clk_cnt <= clk_cnt + 6'd1;
	end
end

assign WS = clk_cnt[5];  // Flip at 31st cycles

/* I2S decoder
 * Get left and right channels based on the clk_cnt counter
 * 0-25 left channel
 * 32-57 right channel
 */
always_ff @(negedge SCK) begin
	if (sck_rst) begin		// Initialize
		left1 <= 24'd0;
		right1 <= 24'd0;
		left2 <= 24'd0;
		right2 <= 24'd0;
		wr_addr <= 11'd2047;// 0 address is avaible
		ram_wren <= 1'd0;		// Initialize with 0 to reset RAMs
		ram1_in <= 16'd0;
		ram2_in <= 16'd0;
		ram3_in <= 16'd0;
		ram4_in <= 16'd0;
		state <= IDLE;
	end else begin
		// Read from the bus
		if (clk_cnt > 0 && clk_cnt < 25) begin // Left channel, 24-bit dept, MSB first
			left1 <= {left1[22:0], SD1};
			left2 <= {left2[22:0], SD2};	
		end else if (clk_cnt > 32 && clk_cnt < 57) begin	// Right channel
			right1 <= {right1[22:0], SD1}; 
			right2 <= {right2[22:0], SD2}; 
		end
		// FSM: 
		// IDLE: Transit to WRITE state when go_SCK is high
		// WRITE: Write raw data to RAMs
		// READ: Ready to be read to the FFT wrapper
		case (state)
			IDLE: begin
				if (go_SCK)
					state <= WRITE;
				else
					state <= IDLE;	
			end
			WRITE:begin
				if (clk_cnt == 57) begin	
					ram1_in <= left1[23:8];			// Discard the lesast 8 bits
					ram2_in <= right1[23:8];		
					ram3_in <= left2[23:8];
					ram4_in <= right2[23:8];
					ram_wren <= 1'd1;
					wr_addr <= wr_addr + 11'd1; // Start with address 0 
				end else if (clk_cnt == 58) begin
					ram_wren <= 1'd0;
				end

				if (wr_addr == 10'd1023)
					state <= READ;
				else
					state <= WRITE;
			end
			READ:	begin 
				wr_addr <= 11'd2047;
				if (go_SCK) begin
					state <= WRITE;
				end else begin
					state <= READ;
				end
			end
			default: begin 
					state <= IDLE;
			end 
		endcase
	end
end

/* Two Port RAM Instantiation
 * Raw data from i2s bus
 */ 
myfifo fifo1(
	.data		(ram1_in),
	.rdclk	(clk),
	.rdreq	(rdreq1),
	.wrclk	(SCK),
	.wrreq	(ram_wren),
	.q			(ram1q),
	.rdfull	(ready1),
	.wrempty	()
);

fft_wrapper fft1(
	.clk(clk),
	.rst_n(rst_n),
	.go(detectdone),
	.ready(ready1),		    // Raw data ready
	.data_in(ram1q[15:2]),	// Raw data in
	.rd_addr_fft(rd_addr_fd),// Read address of fft RAMs

	.out_ready(fftdone),
	.rdreq(rdreq1),
	.ram_q(ram1_fft)			// fft results from fft RAMs
);

freqdetect fd1(
	.clk		(clk),		// 50 MHz, 20 ns
	.reset		(~rst_n),		
	.fftdone	(fftdone),	// Set high upon FFT block finishing
	.ramq		(ram1_fft),	// Output port of channel 1 FFT RAM

	.detectdone	(detectdone),		// Set high when iteration is complete
	.ramaddr	(rd_addr_fd),		// Address to read from RAM
	.maxbin	(maxbin)// Index of max bin
);

/* Avalon bus configuration
 * readdata: FPGA -> HPS
 * writedata: HPS -> FPGA
 */  
always_ff @(posedge clk) begin
	if (reset) begin
		irq <= 1'd0;
		readdata <= 32'd0;
		go <= 1'd0;
		rd_addr_hps <= 10'd0;
	end else if (chipselect && read) begin
		case (address)
		3'h0: readdata <= {{22{1'b0}}, maxbin};
		3'h1: readdata <= {{4{1'b0}}, ram1q};
		3'h2: readdata <= {{4{1'b0}}, ram1q};
		3'h3: readdata <= {{4{1'b0}}, ram1q};
		// 3'h4: begin irq <= 1'd0; readdata <= 32'd1; end
		endcase
	end else if (chipselect && write) begin
		case (address)
		3'h0: rd_addr_hps <= writedata[9:0];
		3'h1: go <= writedata[0];
		endcase
	end
end

endmodule