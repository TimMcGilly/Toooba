// Copyright (c) 2023 Karlis Susters 
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Prefetcher_intf::*;
import Prefetcher_top::*;
import CheriPrefetchers::*;
import RWBramCore::*;
import StmtFSM::*;
import Types::*;
import Fifos::*;

module mkAllInCapPrefetcherTest(Empty);
    Parameter#(256) maxCapSizeToPrefetch <- mkParameter;
    PCPrefetcher t <- mkAllInCapPrefetcher(maxCapSizeToPrefetch);
    mkAutoFSM(
        seq
            action
                t.reportAccess('h8000, 'h0, MISS, 'd64, 'd200);  //Covers 4 cache lines, at bottom of page
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8040, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8080, "test fail!");
            endaction

            action
                t.reportAccess('h7fc0, 'h0, MISS, 'd64, 'd200);  //Covers 4 cache lines, at top of page
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h7f80, "test fail!");
            endaction

            action
                t.reportAccess('h7fc0, 'h0, MISS, 'd64, 'd512);  //Cap that's too big
            endaction

            action
                t.reportAccess('h8040, 'h0, MISS, 'd64, 'd192);  //In middle of cap
            endaction

            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8000, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8080, "test fail!");
            endaction
        endseq
    );
endmodule