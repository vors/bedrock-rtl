// Copyright 2024 The Bedrock-RTL Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// A small-scale circular buffer to use as the pop-side staging buffer for
// a larger FIFO. To limit additional decoding logic, the read and write
// pointers are stored as onehot-encoded vectors.

`include "br_asserts_internal.svh"
`include "br_registers.svh"
`include "br_unused.svh"
`include "br_tieoff.svh"

module br_fifo_staging_buffer #(
    // If 1, data can be bypassed directly from push to the staging buffer.
    // Otherwise, the buffer can only be filled by reading from storage.
    parameter bit EnableBypass = 1,
    // Total depth of the FIFO, including entries in this staging buffer.
    // Must be greater than RamReadLatency + 1.
    parameter int TotalDepth = 3,
    // Latency of RAM reads. Must be >= 1.
    parameter int RamReadLatency = 1,
    // The width of the data. Must be >= 1.
    parameter int Width = 1,
    // If 1, a flow register is added to the output so that
    // valid and data come directly from registers.
    // If 0, valid and data come combinationally from the read muxing logic.
    parameter bit RegisterPopOutputs = 0,

    localparam int BufferDepth = RamReadLatency + 1,
    localparam int TotalCountWidth = $clog2(TotalDepth + 1),
    localparam int BufferCountWidth = $clog2(BufferDepth + 1)
) (
    input logic clk,
    input logic rst,

    input logic [TotalCountWidth-1:0] total_items,

    // ri lint_check_off INEFFECTIVE_NET
    output logic             bypass_ready,
    input  logic             bypass_valid_unstable,
    input  logic [Width-1:0] bypass_data_unstable,
    // ri lint_check_on INEFFECTIVE_NET

    output logic             ram_rd_addr_valid,
    // ram_rd_addr driven externally by counter
    input  logic             ram_rd_data_valid,
    input  logic [Width-1:0] ram_rd_data,

    input  logic             pop_ready,
    output logic             pop_valid,
    output logic [Width-1:0] pop_data
);
  // ===================
  // Integration Checks
  // ===================

  `BR_ASSERT_STATIC(legal_ram_read_latency_a, RamReadLatency >= 1)
  `BR_ASSERT_STATIC(legal_total_depth_a, TotalDepth > BufferDepth)
  `BR_ASSERT_STATIC(legal_bitwidth_a, Width >= 1)
  `BR_ASSERT_INTG(expected_read_latency_a, ##(RamReadLatency) ram_rd_data_valid == $past
                                           (ram_rd_addr_valid, RamReadLatency))

  // Internal integration check
  if (!EnableBypass) begin : gen_no_bypass_assert
    `BR_ASSERT_IMPL(no_bypass_valid_a, !bypass_valid_unstable)
  end

  // ===================
  // Implementation
  // ===================

  localparam int InternalDepth = BufferDepth - RegisterPopOutputs;

  // ================
  // Read Issue Logic
  // ================
  // staged_items counts the number of items either inflight from the RAM
  // or stored in this buffer.
  // Staged items must increment when read is issued or data is bypassed
  // and decrement when popped.
  logic [BufferCountWidth-1:0] staged_items;
  logic                        staged_items_incr;
  logic                        bypass_beat;
  logic                        pop_beat;
  // 1 if there is space available in the buffer. This is true if
  // staged_items < BufferDepth or the buffer is being popped on this cycle.
  logic                        space_available;
  // 1 if there are items in the FIFO that have yet to be staged.
  // This is true if staged_items < total_items.
  logic                        items_not_staged;
  logic                        push_valid;
  logic [           Width-1:0] push_data;

  br_counter #(
      .MaxValue(BufferDepth)
  ) br_counter (
      .clk,
      .rst,

      .reinit       (1'b0),
      .initial_value(BufferCountWidth'(1'b0)),

      .incr_valid(staged_items_incr),
      .incr      (1'b1),

      .decr_valid(pop_beat),
      .decr      (1'b1),

      .value_next(),
      .value     (staged_items)
  );

  assign pop_beat = pop_valid && pop_ready;
  assign space_available = (staged_items < BufferDepth) || pop_ready;
  assign items_not_staged = TotalCountWidth'(staged_items) < total_items;
  assign bypass_beat = bypass_valid_unstable && bypass_ready;
  assign ram_rd_addr_valid = space_available && items_not_staged && !bypass_ready;

  if (EnableBypass) begin : gen_bypass_push
    // Bypass is allowed for the first BufferDepth entries to enter the FIFO.
    assign bypass_ready = space_available && (total_items < BufferDepth);
    assign push_valid = ram_rd_data_valid || bypass_beat;
    assign push_data = ram_rd_data_valid ? ram_rd_data : bypass_data_unstable;
    assign staged_items_incr = ram_rd_addr_valid || bypass_beat;
  end else begin : gen_no_bypass_push
    // TODO(zhemao, #157): Replace this with BR_TIEOFF macros once they are fixed
    assign bypass_ready = 1'b0;  // ri lint_check_waive CONST_OUTPUT CONST_ASSIGN
    assign push_valid = ram_rd_data_valid;
    assign push_data = ram_rd_data;
    assign staged_items_incr = ram_rd_addr_valid;

    `BR_UNUSED_NAMED(bypass_inputs, {bypass_beat, bypass_valid_unstable, bypass_data_unstable})
  end

  // ===================
  // Main Buffer Storage
  // ===================
  logic             internal_pop_valid;
  logic             internal_pop_ready;
  logic [Width-1:0] internal_pop_data;


  if (InternalDepth == 1) begin : gen_flow_reg_rev
    // This is only reachable if RegisterPopOutputs=1 since minimum BufferDepth is 2
    // In this case, place a br_flow_reg_rev so the staging buffer is basically like
    // br_flow_reg_both.
    // Used for assertion only
    logic push_ready;  // ri lint_check_waive NOT_READ HIER_NET_NOT_READ

    br_flow_reg_rev #(
        .Width(Width)
    ) br_flow_reg_rev (
        .clk,
        .rst,
        .push_valid,
        .push_ready,
        .push_data,
        .pop_valid(internal_pop_valid),
        .pop_ready(internal_pop_ready),
        .pop_data (internal_pop_data)
    );

    `BR_ASSERT_IMPL(no_push_hazard_a, !(bypass_valid_unstable && ram_rd_data_valid))
    `BR_ASSERT_IMPL(no_push_overflow_a, push_valid |-> push_ready)
  end else begin : gen_circ_buffer
    // TODO(zhemao): Consider separating the pointer management logic into a standalone module
    logic [InternalDepth-1:0][Width-1:0] mem;
    // Use onehot-encoded pointers to avoid decoding logic
    logic [InternalDepth-1:0] rd_ptr_onehot, rd_ptr_onehot_next;
    logic [InternalDepth-1:0] wr_ptr_onehot, wr_ptr_onehot_next;
    // write-en and next for each data cell
    // mem_wr_en can have up to two bits set (immediate and delayed path)
    logic [InternalDepth-1:0]            mem_wr_en;
    logic [InternalDepth-1:0][Width-1:0] mem_wr_data;
    // Data read from mem. May not be the internal_pop_data since we can do empty bypass.
    logic [        Width-1:0]            mem_rd_data;

    logic maybe_full, maybe_full_next;
    logic ptr_match;
    // only used for assertion
    logic full;  // ri lint_check_waive NOT_READ HIER_NET_NOT_READ
    logic advance_wr_ptr;
    logic advance_rd_ptr;

    assign ptr_match = rd_ptr_onehot == wr_ptr_onehot;
    assign full = ptr_match && maybe_full;

    // Maybe-full becomes high when there is a push without pop
    // and goes low when there is a pop without push
    assign maybe_full_next = (advance_wr_ptr == advance_rd_ptr) ? maybe_full : advance_wr_ptr;
    // Left-Rotate by 1 to advance pointer
    // TODO(zhemao, #159): Use a shift register module for this once available
    assign rd_ptr_onehot_next = {rd_ptr_onehot[InternalDepth-2:0], rd_ptr_onehot[InternalDepth-1]};
    assign wr_ptr_onehot_next = {wr_ptr_onehot[InternalDepth-2:0], wr_ptr_onehot[InternalDepth-1]};

    `BR_REG(maybe_full, maybe_full_next)
    `BR_REGIL(rd_ptr_onehot, rd_ptr_onehot_next, advance_rd_ptr, InternalDepth'(1'b1))
    `BR_REGIL(wr_ptr_onehot, wr_ptr_onehot_next, advance_wr_ptr, InternalDepth'(1'b1))

    // Actual storage update
    for (genvar i = 0; i < InternalDepth; i++) begin : gen_storage
      `BR_REGL(mem[i], mem_wr_data[i], mem_wr_en[i])
    end

    // The read path is the same regardless of bypassing or not
    assign advance_rd_ptr = internal_pop_valid && internal_pop_ready;

    br_mux_onehot #(
        .NumSymbolsIn(InternalDepth),
        .SymbolWidth (Width)
    ) br_mux_onehot_mem (
        .select(rd_ptr_onehot),
        .in    (mem),
        .out   (mem_rd_data)
    );

    if (EnableBypass) begin : gen_bypass_mem_wr
      // If bypassing is enabled, wr_ptr_onehot indicates the cell that will be
      // allocated on a given cycle. If a read is issued to the storage, it should
      // be written to the buffer at the entry pointed to at allocation time.
      // Easiest way to track this is just to put the write pointer through a delay line,
      // even though this creates some additional flops.
      logic [InternalDepth-1:0] wr_ptr_onehot_d;
      // Used for assertion only
      // ri lint_check_waive NOT_READ HIER_NET_NOT_READ
      logic                     wr_ptr_valid_d;

      br_delay_valid #(
          .Width(InternalDepth),
          .NumStages(RamReadLatency)
      ) br_delay_valid_wr_ptr_onehot (
          .clk,
          .rst,
          .in_valid        (ram_rd_addr_valid),
          .in              (wr_ptr_onehot),
          .out_valid       (wr_ptr_valid_d),
          .out             (wr_ptr_onehot_d),
          .out_valid_stages(),
          .out_stages      ()
      );

      logic [InternalDepth-1:0] mem_wr_en_delayed;
      logic [InternalDepth-1:0] mem_wr_en_immediate;
      logic [InternalDepth-1:0] mem_rd_en;

      assign advance_wr_ptr = ram_rd_addr_valid || bypass_beat;
      assign mem_wr_en_immediate = bypass_beat ? wr_ptr_onehot : '0;
      assign mem_wr_en_delayed = ram_rd_data_valid ? wr_ptr_onehot_d : '0;
      assign mem_wr_en = mem_wr_en_immediate | mem_wr_en_delayed;
      assign mem_rd_en = advance_rd_ptr ? rd_ptr_onehot : '0;

      for (genvar i = 0; i < InternalDepth; i++) begin : gen_mem_wr_data
        assign mem_wr_data[i] = mem_wr_en_immediate[i] ? bypass_data_unstable : ram_rd_data;
      end

      // Since the data potentially comes after the write pointer advances, we
      // can't rely on an 'empty' flag based on pointer match to tell whether
      // or not the cell at the head has valid data. Instead, keep a valid bit
      // for each cell.
      logic [InternalDepth-1:0] mem_valid, mem_valid_next;
      logic [InternalDepth-1:0] mem_valid_set, mem_valid_clr;
      logic head_valid;

      // If there is a write and read to the same cell on a cycle,
      // it can be for one of two reasons.
      // 1. The memory is full. The previous occupant of the cell is being replaced by the new data.
      // 2. The memory is empty. The new data is being bypassed through.
      // In the first case, mem_valid will be set and we want it to remain set.
      // In the second case, mem_valid will be clear and we want it to remain clear.
      // Therefore, the value of mem_valid[i] should only change if mem_wr_en[i] != mem_rd_en[i]
      assign mem_valid_set  = mem_wr_en & ~mem_rd_en;
      assign mem_valid_clr  = mem_rd_en & ~mem_wr_en;
      assign mem_valid_next = (mem_valid | mem_valid_set) & ~mem_valid_clr;

      `BR_REGL(mem_valid, mem_valid_next, advance_rd_ptr || advance_wr_ptr)

      assign head_valid = |(mem_valid & rd_ptr_onehot);
      assign internal_pop_valid = head_valid || push_valid;
      assign internal_pop_data = head_valid ? mem_rd_data : push_data;

      `BR_ASSERT_IMPL(no_push_hazard_a, ~|(mem_wr_en_immediate & mem_wr_en_delayed))
      `BR_ASSERT_IMPL(no_push_overwrite_a, ~|(mem_wr_en & mem_valid & ~mem_rd_en))
    end else begin : gen_nonbypass_mem_wr
      logic empty;

      assign empty = ptr_match && !maybe_full;
      assign advance_wr_ptr = push_valid;
      assign mem_wr_en = push_valid ? wr_ptr_onehot : '0;
      assign mem_wr_data = {InternalDepth{ram_rd_data}};
      assign internal_pop_valid = !empty || push_valid;
      assign internal_pop_data = empty ? push_data : mem_rd_data;
    end

    `BR_ASSERT_IMPL(no_push_overflow_a, advance_wr_ptr |-> (!full || advance_rd_ptr))
  end

  // ====================
  // Final Register Stage
  // ====================
  if (RegisterPopOutputs) begin : gen_pop_reg
    br_flow_reg_fwd #(
        .Width(Width)
    ) br_flow_reg_fwd (
        .clk,
        .rst,
        .push_ready(internal_pop_ready),
        .push_valid(internal_pop_valid),
        .push_data (internal_pop_data),
        .pop_ready,
        .pop_valid,
        .pop_data
    );
  end else begin : gen_pop_passthru
    assign pop_valid = internal_pop_valid;
    assign pop_data = internal_pop_data;
    assign internal_pop_ready = pop_ready;
  end

  // Implementation Checks
  if (EnableBypass) begin : gen_bypass_impl_checks
    `BR_ASSERT_IMPL(no_alloc_hazard_a, !(ram_rd_addr_valid && bypass_beat))
  end
endmodule
