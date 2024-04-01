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
                t.reportAccess('h8000, 'h0, MISS, 'h0, 'h70, 'd0);  
            endaction
            action
                t.reportAccess('h8010, 'h0, HIT, 'h10, 'h70, 'd0);  
            endaction
            action
                t.reportAccess('h8020, 'h0, HIT, 'h20, 'h70, 'd0);  
            endaction
            action
                t.reportAccess('h8030, 'h0, HIT, 'h30, 'h81, 'd0);  
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8040, "test fail!");
            endaction
            action
                t.reportAccess('h8040, 'h0, HIT, 'h40, 'h81, 'd0);  
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8080, "test fail!");
            endaction
            //Cheri bounds prevent prefetching further up

            action
                t.reportAccess('ha000, 'h1, MISS, 'h350, 'h1100, 'd1);  
            endaction
            action
                t.reportAccess('h9f00, 'h1, HIT, 'h250, 'h1100, 'd1);  
            endaction
            action
                t.reportAccess('h9e00, 'h1, HIT, 'h1c0, 'h1100, 'd1);  
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h9d3f, "test fail!");
            endaction
            //Cheri bounds prevent prefetching further down

            action
                t.reportAccess('h8040, 'h0, HIT, 'd0, 'd0, 'd0);  
            endaction
            action //Still works if no bounds specified
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h80c0, "test fail!");
            endaction
        endseq
    );
endmodule


module mkCapBitmapPrefetcherTest1(Empty);
    Parameter#(16384) maxCapSizeToTrack <- mkParameter;
    Parameter#(32) bitmapTableSize <- mkParameter;
    Parameter#(4096) filterTableSize <- mkParameter;
    Parameter#(16) inverseDecayChance <- mkParameter;
    CheriPCPrefetcher t <- mkCapBitmapPrefetcher(maxCapSizeToTrack, bitmapTableSize, filterTableSize, inverseDecayChance);
    mkAutoFSM(
        seq
            action
                t.reportAccess('h8040, 'h0, MISS, 'h40, 'h100, 'h4000);  
            endaction
            action
                t.reportAccess('h9040, 'h0, MISS, 'h40, 'h100, 'h5000);  
            endaction
            action
                t.reportAccess('ha040, 'h0, MISS, 'h40, 'h100, 'h6000);  
            endaction
            action endaction
            action
                t.reportAccess('hb000, 'h0, MISS, 'h00, 'h100, 'h7000);  
            endaction
            action
                t.reportAccess('hb080, 'h0, MISS, 'h80, 'h100, 'h7000);  
            endaction
            action
                t.reportAccess('hb0c0, 'h0, MISS, 'hc0, 'h100, 'h7000);  
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'hb040, "test fail!");
            endaction
            
            //If cap is at top of page 
            action
                t.reportAccess('hbf80, 'h0, MISS, 'h00, 'h100, 'h8000);  
            endaction
            action 
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'hbfc0, "test fail!");
            endaction

            //If cap is at bottom of page 
            action
                t.reportAccess('hc000, 'h0, MISS, 'h80, 'h100, 'h8000);  
            endaction
            action 
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'hc040, "test fail!");
            endaction

            //Do a big cap across 4 pages
            action
                t.reportAccess('h8040, 'h0, MISS, 'h40, 'h4000, 'h1000);  
            endaction
            action
                t.reportAccess('ha080, 'h0, MISS, 'h1080, 'h4000, 'h1000);  
            endaction
            action
                t.reportAccess('h2000, 'h0, MISS, 'h1000, 'h4000, 'h2000);  
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h2080, "test fail!");
            endaction
            action
                t.reportAccess('h4000, 'h0, MISS, 'h0000, 'h4000, 'h2000);  
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h4040, "test fail!");
            endaction

            action endaction
            action endaction
            action endaction
            action endaction
        endseq
    );
endmodule

module mkCapBitmapPrefetcherTest2(Empty);
    Parameter#(16384) maxCapSizeToTrack <- mkParameter;
    Parameter#(32) bitmapTableSize <- mkParameter;
    Parameter#(4096) filterTableSize <- mkParameter;
    Parameter#(16) inverseDecayChance <- mkParameter;
    CheriPCPrefetcher t <- mkCapBitmapPrefetcher(maxCapSizeToTrack, bitmapTableSize, filterTableSize, inverseDecayChance);
    mkAutoFSM(
        seq
            //4 page cap
            action
                t.reportAccess('h8000, 'h0, MISS, 'h400, 'h4000, 'h4000);  
            endaction
            action
                t.reportAccess('h8040, 'h0, MISS, 'h440, 'h4000, 'h4000);  
            endaction
            action
                t.reportAccess('h8080, 'h0, MISS, 'h480, 'h4000, 'h4000);  
            endaction
            action
                t.reportAccess('h7e40, 'h0, MISS, 'h240, 'h4000, 'h4000);  
            endaction
            action
                t.reportAccess('h7e80, 'h0, MISS, 'h280, 'h4000, 'h4000);  
            endaction
            action
                t.reportAccess('h7e00, 'h0, MISS, 'h200, 'h4000, 'h4000);  
            endaction
            action
                t.reportAccess('h7d00, 'h0, MISS, 'h100, 'h4000, 'h4000);  
            endaction
            action
                t.reportAccess('h1a300, 'h0, MISS, 'h300, 'h4000, 'h5000);  
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h1a280, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h1a240, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h1a400, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h1a200, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h1a440, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h1a480, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h1a100, "test fail!");
            endaction

            action endaction
            action endaction
            action endaction
            action endaction
            action endaction

            action
                t.reportAccess('h1a080, 'h0, MISS, 'h300, 'h4000, 'h6000);  
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h1a000, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h1a180, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h1a1c0, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h1a200, "test fail!");
            endaction
        endseq
    );
endmodule


module mkCapBitmapPrefetcherTest3(Empty);
    Parameter#(16384) maxCapSizeToTrack <- mkParameter;
    Parameter#(32) bitmapTableSize <- mkParameter;
    Parameter#(4096) filterTableSize <- mkParameter;
    Parameter#(16) inverseDecayChance <- mkParameter;
    CheriPCPrefetcher t <- mkCapBitmapPrefetcher(maxCapSizeToTrack, bitmapTableSize, filterTableSize, inverseDecayChance);
    mkAutoFSM(
        seq
            //160 byte cap
            action
                t.reportAccess('h8010, 'h0, MISS, 'h010, 'h00a0, 'h4000);  
            endaction
            action
                t.reportAccess('h8050, 'h0, MISS, 'h050, 'h00a0, 'h4000);  
            endaction

            action
                t.reportAccess('h8120, 'h0, MISS, 'h020, 'h00a0, 'h4100);  
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8140, "test fail!");
            endaction

            action
                t.reportAccess('h8190, 'h0, MISS, 'h090, 'h00a0, 'h4100);  
            endaction

            //access new cap
            action
                t.reportAccess('h8250, 'h0, MISS, 'h050, 'h00a0, 'h4200);  
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8280, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8200, "test fail!");
            endaction
            
            //access new cap starting at 30 in cache line. spans 4 cache lines. access the last line
            action
                t.reportAccess('h83c0, 'h0, MISS, 'h090, 'h00a0, 'h4330);  
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8380, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8340, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8300, "test fail!");
            endaction

            //Access new cap, and see that the 4th cache line (outside of cap) is prefetched
            action
                t.reportAccess('h8480, 'h0, MISS, 'h080, 'h00a0, 'h4400);  
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h84c0, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8440, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8400, "test fail!");
            endaction

            //Test queueing up issuing prefetches
            action
                t.reportAccess('h8500, 'h0, MISS, 'h000, 'h00a0, 'h4500);  
            endaction
            action
                t.reportAccess('h8600, 'h0, MISS, 'h000, 'h00a0, 'h4600);  
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8540, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8580, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h85c0, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8640, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h8680, "test fail!");
            endaction
            action
                let x <- t.getNextPrefetchAddr;
                doAssert(x == 'h86c0, "test fail!");
            endaction
            action endaction
            action endaction
            action endaction

        endseq
    );
endmodule