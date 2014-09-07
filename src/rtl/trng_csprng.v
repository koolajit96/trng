//======================================================================
//
// trng_csprng.v
// -------------
// CSPRNG for the TRNG.
//
//
// Author: Joachim Strombergson
// Copyright (c) 2014, Secworks Sweden AB
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or
// without modification, are permitted provided that the following
// conditions are met:
//
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in
//    the documentation and/or other materials provided with the
//    distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
// FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
// COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
// INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
// BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
// STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
// ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
//======================================================================

module trng_csprng(
                   // Clock and reset.
                   input wire           clk,
                   input wire           reset_n,

                   // Control, config and status.
                   input                debug_mode,
                   input wire [4 : 0]   num_rounds,
                   input wire [63 : 0]  num_blocks,
                   input wire           seed,
                   input wire           enable,
                   output wire          ready,
                   output wire          error,

                   // Seed input
                   input wire           seed_syn,
                   input [511 : 0]      seed_data,
                   output wire          seed_ack,

                   // Random data output
                   output wire          rnd_syn,
                   output wire [31 : 0] rnd_data,
                   input wire           rnd_ack
                  );


  //----------------------------------------------------------------
  // Internal constant and parameter definitions.
  //----------------------------------------------------------------
  parameter CIPHER_KEYLEN256  = 1'b1; // 256 bit key.
  parameter CIPHER_MAX_BLOCKS = 64'h1000000000000000;

  parameter CTRL_IDLE      = 4'h0;
  parameter CTRL_SEED0     = 4'h1;
  parameter CTRL_SEED0_ACK = 4'h2;
  parameter CTRL_SEED1     = 4'h3;
  parameter CTRL_SEED1_ACK = 4'h4;
  parameter CTRL_INIT0     = 4'h5;
  parameter CTRL_INIT1     = 4'h6;
  parameter CTRL_NEXT0     = 4'h7;
  parameter CTRL_NEXT1     = 4'h8;
  parameter CTRL_CANCEL    = 4'hf;


  //----------------------------------------------------------------
  // Registers including update variables and write enable.
  //----------------------------------------------------------------
  reg [255 : 0] cipher_key_reg;
  reg [255 : 0] cipher_key_new;
  reg           cipher_key_we;

  reg [63 : 0]  cipher_iv_reg;
  reg [63 : 0]  cipher_iv_new;
  reg           cipher_iv_we;

  reg [63 : 0]  cipher_ctr_reg;
  reg [63 : 0]  cipher_ctr_new;
  reg           cipher_ctr_we;

  reg [511 : 0] cipher_block_reg;
  reg [511 : 0] cipher_block_new;
  reg           cipher_block_we;

  reg [63 : 0]  block_ctr_reg;
  reg [63 : 0]  block_ctr_new;
  reg           block_ctr_inc;
  reg           block_ctr_rst;
  reg           block_ctr_we;
  reg           block_ctr_max;

  reg           rnd_syn_reg;
  reg           rnd_syn_new;
  reg           rnd_syn_we;

  reg [31 : 0]  rnd_data_reg;
  reg [31 : 0]  rnd_data_new;
  reg           rnd_data_we;

  reg           ready_reg;
  reg           ready_new;
  reg           ready_we;

  reg           error_reg;
  reg           error_new;
  reg           error_we;

  reg [3 : 0]   csprng_ctrl_reg;
  reg [3 : 0]   csprng_ctrl_new;
  reg           csprng_ctrl_we;


  //----------------------------------------------------------------
  // Wires.
  //----------------------------------------------------------------
  reg            cipher_init;
  reg            cipher_next;

  wire [511 : 0] cipher_data_out;
  wire           cipher_data_out_valid;

  reg [31 : 0]   tmp_read_data;
  reg            tmp_error;

  reg            tmp_seed_ack;

  reg            discard_outputs;


  //----------------------------------------------------------------
  // Concurrent connectivity for ports etc.
  //----------------------------------------------------------------
  assign read_data = tmp_read_data;
  assign error     = tmp_error;

  assign seed_ack  = tmp_seed_ack;

  assign ready     = ready_reg;
  assign error     = error_reg;

  assign rnd_syn   = rnd_syn_reg;
  assign rnd_data  = rnd_data_reg;


  //----------------------------------------------------------------
  // core instantiation.
  //----------------------------------------------------------------
  chacha_core chacha(
                     .clk(clk),
                     .reset_n(reset_n),

                     .init(cipher_init),
                     .next(cipher_next),

                     .key(cipher_key_reg),
                     .keylen(CHACHA_KEYLEN256),
                     .iv(cipher_iv_reg),
                     .ctr(cipher_ctr_reg),
                     .rounds(num_rounds),

                     .data_in(cipher_block_reg),
                     .ready(cipher_ready),

                     .data_out(cipher_data_out),
                     .data_out_valid(cipher_data_out_valid)
                    );


  //----------------------------------------------------------------
  // reg_update
  //
  // Update functionality for all registers in the core.
  // All registers are positive edge triggered with synchronous
  // active low reset. All registers have write enable.
  //----------------------------------------------------------------
  always @ (posedge clk or negedge reset_n)
    begin
      if (!reset_n)
        begin
          cipher_key_reg   <= {8{32'h00000000}};
          cipher_iv_reg    <= {2{32'h00000000}};
          cipher_ctr_reg   <= {2{32'h00000000}};
          cipher_block_reg <= {16{32'h00000000}};
          block_ctr_reg    <= {2{32'h00000000}};
          ready_reg        <= 0;
          error_reg        <= 0;
          rnd_syn_reg      <= 0;
          rnd_data_reg     <= 32'h00000000;
          csprng_ctrl_reg  <= CTRL_IDLE;
        end
      else
        begin
          if (cipher_key_we)
            begin
              cipher_key_reg <= cipher_key_new;
            end

          if (cipher_iv_we)
            begin
              cipher_iv_reg <= cipher_iv_new;
            end

          if (cipher_ctr_we)
            begin
              cipher_ctr_reg <= cipher_ctr_new;
            end

          if (cipher_block_we)
            begin
              cipher_block_reg <= cipher_block_new;
            end

          if (block_ctr_we)
            begin
              block_ctr_reg <= block_ctr_new;
            end

          if (ready_we)
            begin
              ready_reg <= ready_new;
            end

          if (error_we)
            begin
              error_reg <= error_new;
            end

          if (rnd_syn_we)
            begin
              rnd_syn_reg <= rnd_syn_new;
            end

          if (rnd_data_we)
            begin
              rnd_data_reg <= rnd_data_new;
            end

          if (csprng_ctrl_we)
            begin
              csprng_ctrl_reg <= csprng_ctrl_new;
            end
        end
    end // reg_update


  //----------------------------------------------------------------
  // block_ctr
  //
  // Logic to implement the block counter. This includes the
  // ability to detect that maximum allowed number of blocks
  // has been reached. Either as defined by the application
  // or the hard coded CIPHER_MAX_BLOCKS value.
  //----------------------------------------------------------------
  always @*
    begin : block_ctr
      block_ctr_new = 64'h0000000000000000;
      block_ctr_we  = 0;
      block_ctr_max = 0;

      if (block_ctr_rst)
        begin
          block_ctr_new = 64'h0000000000000000;
          block_ctr_we  = 1;
        end

      if ((block_ctr_reg == num_blocks) || (block_ctr_reg == CIPHER_MAX_BLOCKS))
        begin
          block_ctr_max = 1;
        end

      if ((block_ctr_inc) && (!block_ctr_max))
        begin
          block_ctr_new = 64'h0000000000000001;
          block_ctr_we  = 1;
        end
    end // block_ctr


  //----------------------------------------------------------------
  // csprng_ctrl_fsm
  //
  // Control FSM for the CSPRNG.
  //----------------------------------------------------------------
  always @*
    begin : csprng_ctrl_fsm
      cipher_key_new   = {8{32'h00000000}};
      cipher_key_we    = 0;
      cipher_iv_new    = {2{32'h00000000}};
      cipher_iv_we     = 0;
      cipher_ctr_new   =  {2{32'h00000000}};
      cipher_ctr_we    = 0;
      cipher_block_new =  {16{32'h00000000}};
      cipher_block_we  = 0;
      cipher_init      = 0;
      cipher_next      = 0;
      block_ctr_rst    = 0;
      block_ctr_inc    = 0;
      ready_new        = 0;
      ready_we         = 0;
      error_new        = 0;
      error_we         = 0;
      discard_outputs  = 0;
      tmp_seed_ack     = 0;
      csprng_ctrl_new  = CTRL_IDLE;
      csprng_ctrl_we   = 0;

      case (csprng_ctrl_reg)
        CTRL_IDLE:
          begin
            if (enable)
              begin
                csprng_ctrl_new = CTRL_SEED0;
                csprng_ctrl_we  = 1;
              end
          end

        CTRL_SEED0:
          begin
            if (!enable)
              begin
                csprng_ctrl_new = CTRL_CANCEL;
                csprng_ctrl_we  = 1;
              end
            else if (seed_syn)
              begin
                cipher_block_new = seed_data;
                cipher_block_we  = 1;
                csprng_ctrl_new  = CTRL_SEED0_ACK;
                csprng_ctrl_we   = 1;
              end
          end

        CTRL_SEED0_ACK:
          begin
            if (!enable)
              begin
                csprng_ctrl_new = CTRL_CANCEL;
                csprng_ctrl_we  = 1;
              end
            else
              begin
                tmp_seed_ack    = 1;
                csprng_ctrl_new = CTRL_SEED1;
                csprng_ctrl_we  = 1;
              end
          end

        CTRL_SEED1:
          begin
            if (!enable)
              begin
                csprng_ctrl_new = CTRL_CANCEL;
                csprng_ctrl_we  = 1;
              end
            else if (seed_syn)
              begin
                cipher_key_new  = seed_data[255 : 0];
                cipher_key_we   = 1;
                cipher_iv_new   = seed_data[319 : 256];
                cipher_iv_we    = 1;
                cipher_ctr_new  = seed_data[383 : 320];
                cipher_ctr_we   = 1;
                csprng_ctrl_new = CTRL_SEED1_ACK;
                csprng_ctrl_we  = 1;
              end
          end

        CTRL_SEED1_ACK:
          begin
            if (!enable)
              begin
                csprng_ctrl_new = CTRL_CANCEL;
                csprng_ctrl_we  = 1;
              end
            else
              begin
                tmp_seed_ack    = 1;
                csprng_ctrl_new = CTRL_INIT0;
                csprng_ctrl_we  = 1;
              end
          end

        CTRL_INIT0:
          begin
            if (!enable)
              begin
                csprng_ctrl_new = CTRL_CANCEL;
                csprng_ctrl_we  = 1;
              end
            else
              begin
                cipher_init     = 1;
                block_ctr_rst   = 1;
                csprng_ctrl_new = CTRL_INIT1;
                csprng_ctrl_we  = 1;
              end
          end

        CTRL_INIT1:
          begin
            if (!enable)
              begin
                csprng_ctrl_new = CTRL_CANCEL;
                csprng_ctrl_we  = 1;
              end
            else if (cipher_ready)
              begin
                csprng_ctrl_new = CTRL_NEXT0;
                csprng_ctrl_we  = 1;
              end
          end

        CTRL_NEXT0:
          begin
            if (!enable)
              begin
                csprng_ctrl_new = CTRL_CANCEL;
                csprng_ctrl_we  = 1;
              end
            else
              begin
                // We stay here for now.
              end
          end

        CTRL_CANCEL:
          begin
            cipher_key_new   = {8{32'h00000000}};
            cipher_key_we    = 1;
            cipher_iv_new    = {2{32'h00000000}};
            cipher_iv_we     = 1;
            cipher_ctr_new   = {2{32'h00000000}};
            cipher_ctr_we    = 1;
            cipher_block_new = {16{32'h00000000}};
            cipher_block_we  = 1;
            block_ctr_rst    = 1;
            discard_outputs  = 1;
            csprng_ctrl_new  = CTRL_IDLE;
            csprng_ctrl_we   = 1;
          end

      endcase // case (cspng_ctrl_reg)
    end // csprng_ctrl_fsm

endmodule // trng_csprng

//======================================================================
// EOF trng_csprng
//======================================================================
