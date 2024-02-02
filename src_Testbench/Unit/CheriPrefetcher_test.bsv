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
    CheriPCPrefetcher t <- mkAllInCapPrefetcher(maxCapSizeToPrefetch);
    mkAutoFSM(
        seq
            action
                t.reportAccess('h8000, 'h0, MISS, 'd64, 'd200, 'd0);  //Covers 4 cache lines, at bottom of page
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
                t.reportAccess('h7fc0, 'h0, MISS, 'd64, 'd200, 'd0);  //Covers 4 cache lines, at top of page
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h7f80, "test fail!");
            endaction

            action
                t.reportAccess('h7fc0, 'h0, MISS, 'd64, 'd512, 'd0);  //Cap that's too big
            endaction

            action
                t.reportAccess('h8040, 'h0, MISS, 'd64, 'd192, 'd0);  //In middle of cap
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

module mkCheriStridePrefetcherTest(Empty);
    Parameter#(256) strideTableSize <- mkParameter;
    Parameter#(2) cLinesAheadToPrefetch <- mkParameter;
    CheriPCPrefetcher t <- mkCheriStridePrefetcher(strideTableSize, cLinesAheadToPrefetch);
    mkAutoFSM(
        seq
            action
                t.reportAccess('h8000, 'h0, MISS, 'd0, 'd0, 'd0);  
            endaction
            action
                t.reportAccess('h8010, 'h0, HIT, 'd0, 'd0, 'd0);  
            endaction
            action
                t.reportAccess('h8020, 'h0, HIT, 'd0, 'd0, 'd0);  
            endaction
            action
                t.reportAccess('h8030, 'h0, HIT, 'd0, 'd0, 'd0);  
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8060, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h80a0, "test fail!");
            endaction

            action
                t.reportAccess('h9000, 'h0, MISS, 'd0, 'd0, 'd1);  
            endaction
            action
                t.reportAccess('h9f00, 'h0, HIT, 'd0, 'd0, 'd1);  
            endaction
            action
                t.reportAccess('h9e00, 'h0, HIT, 'd0, 'd0, 'd1);  
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h9d00, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h9c00, "test fail!");
            endaction

            action
                t.reportAccess('h8040, 'h0, HIT, 'd0, 'd0, 'd0);  
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h80c0, "test fail!");
            endaction
        endseq
    );
endmodule