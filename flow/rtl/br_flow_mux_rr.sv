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

// Bedrock-RTL Flow-Controlled Multiplexer (Round-Robin)
//
// Combines RR-priority arbitration with data path multiplexing.
// Grants a single request at a time with RR priority.
// Uses ready-valid flow control for flows (push)
// and the grant (pop).
//
// Stateful arbiter, but 0 latency from push to pop.

`include "br_asserts.svh"

module br_flow_mux_rr #(
    parameter int NumFlows  = 2,  // Must be at least 2
    parameter int DataWidth = 1   // Must be at least 1
) (
    input  logic                                clk,
    input  logic                                rst,
    output logic [ NumFlows-1:0]                push_ready,
    input  logic [ NumFlows-1:0]                push_valid,
    input  logic [ NumFlows-1:0][DataWidth-1:0] push_data,
    input  logic                                pop_ready,
    output logic                                pop_valid,
    output logic [DataWidth-1:0]                pop_data
);

  //------------------------------------------
  // Integration checks
  //------------------------------------------
  `BR_ASSERT_STATIC(num_flows_gte_2_a, NumFlows >= 2)
  `BR_ASSERT_STATIC(data_width_gte_1_a, DataWidth >= 1)

  // Rely on submodule integration checks

  //------------------------------------------
  // Implementation
  //------------------------------------------

  br_flow_arb_rr #(
      .NumFlows(NumFlows)
  ) br_flow_arb_rr (
      .clk,
      .rst,
      .push_ready,
      .push_valid,
      .pop_ready,
      .pop_valid
  );

  // Determine the index of the granted flow
  logic [$clog2(NumFlows)-1:0] grant_idx;

  always_comb begin
    grant_idx = '0;
    for (int i = 0; i < NumFlows; i++) begin
      if (push_ready[i] && push_valid[i]) begin
        grant_idx = i;
        break;  // push_ready & push_valid is guaranteed onehot0 by br_flow_arb_fixed
      end
    end
  end

  // Mux to the output
  assign pop_data = push_data[grant_idx];

  //------------------------------------------
  // Implementation checks
  //------------------------------------------
  // Rely on submodule implementation checks

endmodule : br_flow_mux_rr
