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

// Bedrock-RTL Flow-Controlled Arbiter (Least-Recently-Used)
//
// Grants a single request at a time with least-recently-used (LRU) priority
// where the lowest index flow initializes with the highest priority.
// Uses ready-valid flow control for flows (push)
// and the grant (pop).
//
// 0-cycle latency, but clock and reset are still needed to manage
// the internal arbiter priority state.
//
// TODO(mgottscho): Write spec

`include "br_registers.svh"
`include "br_asserts_internal.svh"

module br_flow_arb_lru #(
    // Must be at least 2
    parameter int NumFlows = 2
) (
    input logic clk,
    input logic rst,
    output logic [NumFlows-1:0] push_ready,
    input logic [NumFlows-1:0] push_valid,
    input logic pop_ready,
    output logic pop_valid
);

  //------------------------------------------
  // Integration checks
  //------------------------------------------
  // Rely on submodule integration checks

  // TODO(mgottscho): Add more

  //------------------------------------------
  // Implementation
  //------------------------------------------
  logic [NumFlows-1:0] grant;

  br_arb_lru #(
      .NumRequesters(NumFlows)
  ) br_arb_lru (
      .clk,
      .rst,
      .enable_priority_update(pop_ready),
      .request(push_valid),
      .grant
  );

  // We could just make push_ready[i] == grant[i], but then push_ready[i] will always
  // depend on push_valid[i]. It is nicer to indicate ready independently of the valid
  // for the same flow.
  for (genvar i = 0; i < NumFlows; i++) begin : gen_push_ready
    always_comb begin
      push_ready[i] = 1'b1;
      for (int j = 0; j < NumFlows; j++) begin
        if (i != j) begin
          push_ready[i] &= !grant[j];
        end
      end
    end
  end

  assign pop_valid = |push_valid;

  //------------------------------------------
  // Implementation checks
  //------------------------------------------
  // Rely on submodule implementation checks

  `BR_ASSERT_IMPL(grant_onehot0_a, $onehot0(grant))
  `BR_ASSERT_IMPL(grant_equals_push_ready_and_valid_a, grant == (push_ready & push_valid))

endmodule : br_flow_arb_lru
