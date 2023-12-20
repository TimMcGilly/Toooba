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
import SignaturePathPrefetcher::*;
import RWBramCore::*;
import StmtFSM::*;
import Types::*;
import Fifos::*;
import Vector::*;
import ProcTypes::*;
import CCTypes::*;
import CacheUtils::*;

module mkDividerTest(Empty);
    Divider d <- mkDivider("./../../src_Testbench/Signature_path_prefetcher/div_table.memhex");
    mkAutoFSM(
        seq
            // ----- Send misses and stuff to one window -----
            action 
                $display("%t", $time); 
                d.doDiv1(0, 0);
            endaction
            action
                let x = d.getDiv1Res;
                d.deqDiv1Res;
                $display("0 / 0 = %h", x);
                doAssert(x == 'h0, "test fail!");
            endaction
            action
                d.doDiv1(4'b0111, 4'b1000);
                d.doDiv2(4'b0111, 4'b1001);
            endaction
            action
                let x = d.getDiv1Res;
                d.deqDiv1Res;
                $display("data1: %h", x);
                doAssert(x == 'b1101111, "test fail!");
                
                let y = d.getDiv2Res;
                d.deqDiv2Res;
                $display("data2: %h", y);
                doAssert(y == 'b1100011, "test fail!");
            endaction
            action
                $display("Test finished!");
            endaction
        endseq
    );
endmodule

module mkPrefetchCalculatorTest(Empty);
    PrefetchCalculator#(8, 8) d <- mkPrefetchCalculator(7'b0001111, "./../../src_Testbench/Signature_path_prefetcher/div_table.memhex");
    Prob alpha = 7'b1111111;
    mkAutoFSM(
        seq
            // ----- Send misses and stuff to one window -----
            action 
                $display("First action");
                LineAddr currAddr = 'h8000;
                Sig sig = 12'habc;
                Prob currCumProb = 7'b1111111;
                Count sigCount = 12;
                Vector#(4, DeltaEntry) deltaCounts;
                deltaCounts[0] = DeltaEntry{delta: 7'd1, count: 1};
                deltaCounts[1] = DeltaEntry{delta: 7'd2, count: 2};
                deltaCounts[2] = DeltaEntry{delta: {1'b1, 6'd1}, count: 3};
                deltaCounts[3] = DeltaEntry{delta: {1'b1, 6'd2}, count: 4};
                d.submitCandidates(currAddr, sig, alpha, currCumProb, sigCount, deltaCounts);
            endaction
            action
            endaction
            action
            endaction
            action
                let addr <- d.getNextPrefetchAddr;
                doAssert(addr == 'h8002, "test fail");
            endaction
            action
                $display("Second action");
                LineAddr currAddr = 'h9000;
                Sig sig = 12'habc;
                Prob currCumProb = 7'b1000000;
                Count sigCount = 12;
                Vector#(4, DeltaEntry) deltaCounts;
                deltaCounts[3] = DeltaEntry{delta: 7'd1, count: 1};
                deltaCounts[2] = DeltaEntry{delta: 7'd2, count: 2};
                deltaCounts[1] = DeltaEntry{delta: {1'b1, 6'd1}, count: 3};
                deltaCounts[0] = DeltaEntry{delta: {1'b1, 6'd2}, count: 4};
                d.submitCandidates(currAddr, sig, alpha, currCumProb, sigCount, deltaCounts);

                let addr <- d.getNextPrefetchAddr;
                doAssert(addr == 'h7fff, "test fail");
            endaction
            action
                let addr <- d.getNextPrefetchAddr;
                doAssert(addr == 'h7ffe, "test fail");
            endaction
            action
                let ptl <- d.getPTLookupEntry;
                doAssert(ptl.addr == 'h7ffe, "test fail");
                doAssert(ptl.sig == 'h5a2, "test fail");
                doAssert(ptl.currCumProb == 'h29, "test fail");
            endaction
            action
                let addr <- d.getNextPrefetchAddr;
                doAssert(addr == 'h8ffe, "test fail");
            endaction
            action 
                let addr <- d.getNextPrefetchAddr;
                doAssert(addr == 'h8fff, "test fail");
            endaction
            action 
                let ptl <- d.getPTLookupEntry;
                doAssert(ptl.addr == 'h8ffe, "test fail");
                doAssert(ptl.sig == 'h5a2, "test fail");
                doAssert(ptl.currCumProb == 'h14, "test fail");
            endaction
            action 
            endaction
            action
                $display("Test finished!");
            endaction
        endseq
    );
endmodule

module mkSignatureTableTest1(Empty);
    SignatureTable#(4, 16, 1) d <- mkSignatureTable;
    mkAutoFSM(
        seq
            action 
                LineAddr currAddr = 'h123456789ab;
                d.reportAccess(currAddr);
            endaction
            action
                LineAddr currAddr = 'h123456789ac;
                d.reportAccess(currAddr);
            endaction
            action
                LineAddr currAddr = 'h123456789ae;
                d.reportAccess(currAddr);
            endaction
            action
                let ptu <- d.getPTUpdateEntry;
                doAssert(ptu.oldSig == 'h0, "test fail");
                doAssert(ptu.observedDelta == 'h1, "test fail");
                let ptl <- d.getPTLookupEntry;
                doAssert(ptl.sig == 'h1, "test fail");
                doAssert(ptl.addr == 'h123456789ac, "test fail");
                doAssert(ptl.currCumProb == 'h7f, "test fail");
            endaction
            action
                let ptu <- d.getPTUpdateEntry;
                doAssert(ptu.oldSig == 'h1, "test fail");
                doAssert(ptu.observedDelta == 'h2, "test fail");
                let ptl <- d.getPTLookupEntry;
                doAssert(ptl.sig == 'ha, "test fail");
                doAssert(ptl.addr == 'h123456789ae, "test fail");
            endaction
            action 
                LineAddr currAddr = 'h00001234567;
                d.reportAccess(currAddr);
            endaction
            action
                LineAddr currAddr = 'h00001234563;
                d.reportAccess(currAddr);
            endaction
            action
                LineAddr currAddr = 'h0000123455f;
                d.reportAccess(currAddr);
            endaction
            action
            endaction
            action
            endaction
            action
                $display("Test finished!");
            endaction
        endseq
    );
endmodule

module mkSignatureTableTest2(Empty);
    SignatureTable#(4, 64, 2) d <- mkSignatureTable;
    mkAutoFSM(
        seq
            action 
                LineAddr currAddr = 'h00001111000;
                d.reportAccess(currAddr);
            endaction
            action
                LineAddr currAddr = 'h00001111002;
                d.reportAccess(currAddr);
            endaction
            action
                let ptu <- d.getPTUpdateEntry;
                doAssert(ptu.oldSig == 'h0, "test fail");
                doAssert(ptu.observedDelta == 'h2, "test fail");
                let ptl <- d.getPTLookupEntry;
                doAssert(ptl.sig == 'h2, "test fail");
            endaction
            action
                LineAddr currAddr = 'h0000222200a;
                d.reportAccess(currAddr);
            endaction
            action
                LineAddr currAddr = 'h0000333300b;
                d.reportAccess(currAddr);
            endaction
            action 
                LineAddr currAddr = 'h0000222200d;
                d.reportAccess(currAddr);
            endaction
            action
                let ptu <- d.getPTUpdateEntry;
                doAssert(ptu.oldSig == 'h0, "test fail");
                doAssert(ptu.observedDelta == 'h3, "test fail");
                let ptl <- d.getPTLookupEntry;
                doAssert(ptl.sig == 'h3, "test fail");
            endaction
            action 
                LineAddr currAddr = 'h0000222200c;
                d.reportAccess(currAddr);
            endaction
            action
                let ptu <- d.getPTUpdateEntry;
                doAssert(ptu.oldSig == 'h3, "test fail");
                doAssert(ptu.observedDelta == 'b1000001, "test fail");
                let ptl <- d.getPTLookupEntry;
                doAssert(ptl.sig == 'h059, "test fail");
            endaction
            action
                $display("Test finished!");
            endaction
        endseq
    );
endmodule

module mkSignatureTableTest3(Empty);
    SignatureTable#(4, 64, 4) d <- mkSignatureTable;
    mkAutoFSM(
        seq
            action 
                LineAddr currAddr = 'h00001111000;
                d.reportAccess(currAddr);
            endaction
            action
                LineAddr currAddr = 'h00002222000;
                d.reportAccess(currAddr);
            endaction
            action
                LineAddr currAddr = 'h00003333000;
                d.reportAccess(currAddr);
            endaction
            action
                LineAddr currAddr = 'h00004444000;
                d.reportAccess(currAddr);
            endaction
            action
                LineAddr currAddr = 'h00005555000;
                d.reportAccess(currAddr);
            endaction
            action
                LineAddr currAddr = 'h00002222001;
                d.reportAccess(currAddr);
            endaction
            action
                let ptu <- d.getPTUpdateEntry;
                let ptl <- d.getPTLookupEntry;
                doAssert(ptl.addr == 'h2222001, "test fail");
            endaction
            // Test different table entries
            action 
                LineAddr currAddr = 'h00001111000;
                d.reportAccess(currAddr);
            endaction
            action
                LineAddr currAddr = 'h00001111040;
                d.reportAccess(currAddr);
            endaction
            action
                LineAddr currAddr = 'h00002222040;
                d.reportAccess(currAddr);
            endaction
            action
                LineAddr currAddr = 'h00001111041;
                d.reportAccess(currAddr);
            endaction
            action
                let ptu <- d.getPTUpdateEntry;
                let ptl <- d.getPTLookupEntry;
                doAssert(ptl.addr == 'h1111041, "test fail");
            endaction
            action
                $display("Test finished!");
            endaction
        endseq
    );
endmodule

module mkPatternTableTest1(Empty);
    PatternTable#(16, 4) d <- mkPatternTable;
    // Testing replacement
    mkAutoFSM(
        seq
            action 
                PTLookupEntry ptl;
                ptl.sig = 4;
                ptl.addr = 3;
                ptl.currCumProb = 1;
                d.doPTLookup(ptl);

                PTUpdateEntry ptu;
                ptu.oldSig = 2;
                ptu.observedDelta = 3;
                d.doPTUpdate(ptu);
            endaction
            action
                PTUpdateEntry ptu;
                ptu.oldSig = 2;
                ptu.observedDelta = 3;
                d.doPTUpdate(ptu);
            endaction
            action
                PTLookupEntry ptl;
                ptl.sig = 2;
                ptl.addr = 5;
                ptl.currCumProb = 1;
                d.doPTLookup(ptl);
            endaction
            action
                let t <- d.getPTEntry;
                doAssert(tpl_1(t) == PTLookupEntry {sig:2, addr:5, currCumProb:1}, "test fail");
                doAssert(tpl_2(t).sigCount == 2, "test fail");
                doAssert(tpl_2(t).deltaCounts[0] == DeltaEntry {delta:3, count:2}, "test fail");
            endaction
            action
                PTUpdateEntry ptu;
                ptu.oldSig = 2;
                ptu.observedDelta = 1;
                d.doPTUpdate(ptu);
            endaction
            action
                PTLookupEntry ptl;
                ptl.sig = 2;
                ptl.addr = 5;
                ptl.currCumProb = 1;
                d.doPTLookup(ptl);
            endaction
            action
                let t <- d.getPTEntry;
                doAssert(tpl_1(t) == PTLookupEntry {sig:2, addr:5, currCumProb:1}, "test fail");
                doAssert(tpl_2(t).sigCount == 3, "test fail");
                doAssert(tpl_2(t).deltaCounts[0] == DeltaEntry {delta:3, count:2}, "test fail");
                doAssert(tpl_2(t).deltaCounts[1] == DeltaEntry {delta:1, count:1}, "test fail");
            endaction
            action
                PTUpdateEntry ptu;
                ptu.oldSig = 2;
                ptu.observedDelta = 4;
                d.doPTUpdate(ptu);
            endaction
            action
                PTUpdateEntry ptu;
                ptu.oldSig = 2;
                ptu.observedDelta = 5;
                d.doPTUpdate(ptu);
            endaction
            action
                PTUpdateEntry ptu;
                ptu.oldSig = 2;
                ptu.observedDelta = 6;
                d.doPTUpdate(ptu);
            endaction
            action
                PTLookupEntry ptl;
                ptl.sig = 2;
                ptl.addr = 5;
                ptl.currCumProb = 1;
                d.doPTLookup(ptl);
            endaction
            action
                let t <- d.getPTEntry;
                doAssert(tpl_1(t) == PTLookupEntry {sig:2, addr:5, currCumProb:1}, "test fail");
                doAssert(tpl_2(t).sigCount == 6, "test fail");
                doAssert(tpl_2(t).deltaCounts[0] == DeltaEntry {delta:3, count:2}, "test fail");
                doAssert(tpl_2(t).deltaCounts[1] == DeltaEntry {delta:6, count:1}, "test fail");
                doAssert(tpl_2(t).deltaCounts[2] == DeltaEntry {delta:4, count:1}, "test fail");
                doAssert(tpl_2(t).deltaCounts[3] == DeltaEntry {delta:5, count:1}, "test fail");
            endaction
            action
                PTUpdateEntry ptu;
                ptu.oldSig = 2;
                ptu.observedDelta = 6;
                d.doPTUpdate(ptu);
            endaction
            action
                PTUpdateEntry ptu;
                ptu.oldSig = 2;
                ptu.observedDelta = 6;
                d.doPTUpdate(ptu);
            endaction
            action
                PTUpdateEntry ptu;
                ptu.oldSig = 2;
                ptu.observedDelta = 7;
                d.doPTUpdate(ptu);

                PTLookupEntry ptl;
                ptl.sig = 2;
                ptl.addr = 5;
                ptl.currCumProb = 1;
                d.doPTLookup(ptl);
            endaction
            action
            endaction
            action
                let t <- d.getPTEntry;
                doAssert(tpl_1(t) == PTLookupEntry {sig:2, addr:5, currCumProb:1}, "test fail");
                doAssert(tpl_2(t).sigCount == 9, "test fail");
                doAssert(tpl_2(t).deltaCounts[0] == DeltaEntry {delta:3, count:2}, "test fail");
                doAssert(tpl_2(t).deltaCounts[1] == DeltaEntry {delta:6, count:3}, "test fail");
                doAssert(tpl_2(t).deltaCounts[2] == DeltaEntry {delta:7, count:1}, "test fail");
                doAssert(tpl_2(t).deltaCounts[3] == DeltaEntry {delta:5, count:1}, "test fail");
            endaction
            action
                PTUpdateEntry ptu;
                ptu.oldSig = 1;
                ptu.observedDelta = 10;
                d.doPTUpdate(ptu);

                PTLookupEntry ptl;
                ptl.sig = 1;
                ptl.addr = 100;
                ptl.currCumProb = 2;
                d.doPTLookup(ptl);
            endaction
            action
                let t <- d.getPTEntry;
                doAssert(tpl_1(t) == PTLookupEntry {sig:1, addr:100, currCumProb:2}, "test fail");
                doAssert(tpl_2(t).sigCount == 1, "test fail");
                doAssert(tpl_2(t).deltaCounts[0] == DeltaEntry {delta:10, count:1}, "test fail");
                doAssert(tpl_2(t).deltaCounts[1] == DeltaEntry {delta:0, count:0}, "test fail");
                doAssert(tpl_2(t).deltaCounts[2] == DeltaEntry {delta:0, count:0}, "test fail");
                doAssert(tpl_2(t).deltaCounts[3] == DeltaEntry {delta:0, count:0}, "test fail");
            endaction
            action
                $display("Test finished!");
            endaction
        endseq
    );
endmodule

module mkPatternTableTest2(Empty);
    PatternTable#(16, 4) d <- mkPatternTable;
    // Testing counter overflow
    Reg#(int) i <- mkRegU;
    mkAutoFSM(
        seq
            for (i <= 0; i < 13; i <= i + 1) 
                action 
                    PTUpdateEntry ptu;
                    ptu.oldSig = 1;
                    ptu.observedDelta = 3;
                    d.doPTUpdate(ptu);
                endaction
            action 
                PTUpdateEntry ptu;
                ptu.oldSig = 1;
                ptu.observedDelta = 4;
                d.doPTUpdate(ptu);
            endaction
            action 
                PTUpdateEntry ptu;
                ptu.oldSig = 1;
                ptu.observedDelta = 4;
                d.doPTUpdate(ptu);
            endaction
            action
                PTLookupEntry ptl;
                ptl.sig = 1;
                ptl.addr = 5;
                ptl.currCumProb = 1;
                d.doPTLookup(ptl);
            endaction
            action
                let t <- d.getPTEntry;
                doAssert(tpl_1(t) == PTLookupEntry {sig:1, addr:5, currCumProb:1}, "test fail");
                doAssert(tpl_2(t).sigCount == 15, "test fail");
                doAssert(tpl_2(t).deltaCounts[0] == DeltaEntry {delta:3, count:13}, "test fail");
                doAssert(tpl_2(t).deltaCounts[1] == DeltaEntry {delta:4, count:2}, "test fail");
            endaction
            action 
                PTUpdateEntry ptu;
                ptu.oldSig = 1;
                ptu.observedDelta = 5;
                d.doPTUpdate(ptu);
            endaction
            action
                PTLookupEntry ptl;
                ptl.sig = 1;
                ptl.addr = 5;
                ptl.currCumProb = 1;
                d.doPTLookup(ptl);
            endaction
            action
                let t <- d.getPTEntry;
                doAssert(tpl_1(t) == PTLookupEntry {sig:1, addr:5, currCumProb:1}, "test fail");
                doAssert(tpl_2(t).sigCount == 8, "test fail");
                doAssert(tpl_2(t).deltaCounts[0] == DeltaEntry {delta:3, count:6}, "test fail");
                doAssert(tpl_2(t).deltaCounts[1] == DeltaEntry {delta:4, count:1}, "test fail");
                doAssert(tpl_2(t).deltaCounts[2] == DeltaEntry {delta:5, count:1}, "test fail");
            endaction
            action
                $display("Test finished!");
            endaction
        endseq
    );
endmodule

module mkSignaturePathPrefetcherTest1(Empty);
    Parameter#(64) stSets <- mkParameter;
    Parameter#(4) stWays <- mkParameter;
    Parameter#(512) ptEntries <- mkParameter;
    Prob prefetchThreshold = 7'b1000000;
    Bool useFilter = False;
    Prefetcher d <- mkSignaturePathPrefetcher(
        "./../../src_Testbench/Signature_path_prefetcher/div_table.memhex",
        stSets, stWays, ptEntries, prefetchThreshold, useFilter);
    mkAutoFSM(
        seq
            action
                d.reportAccess('h8000, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h8080, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h8100, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h8180, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h8200, MISS);
            endaction
            action
                let addr <- d.getNextPrefetchAddr;
                LineAddr lineAddr = truncate(addr);
                doAssert(addr == 'h8280, "test fail");
            endaction
            action
                let addr <- d.getNextPrefetchAddr;
                LineAddr lineAddr = truncate(addr);
                doAssert(addr == 'h8300, "test fail");
            endaction
            action endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h8200, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h81c0, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h8180, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h8140, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h8100, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                let addr <- d.getNextPrefetchAddr;
                LineAddr lineAddr = truncate(addr);
                doAssert(addr == 'h80c0, "test fail");
            endaction
            action
                let addr <- d.getNextPrefetchAddr;
                LineAddr lineAddr = truncate(addr);
                doAssert(addr == 'h8080, "test fail");
            endaction
            action endaction
            action endaction
            action endaction
            action endaction
            action endaction
            action
                $display("Test finished!");
            endaction
        endseq
    );
endmodule

module mkSignaturePathPrefetcherTest2(Empty);
    Parameter#(64) stSets <- mkParameter;
    Parameter#(4) stWays <- mkParameter;
    Parameter#(512) ptEntries <- mkParameter;
    Prob prefetchThreshold = 7'b1000000;
    Bool useFilter = True;
    Prefetcher d <- mkSignaturePathPrefetcher(
        "./../../src_Testbench/Signature_path_prefetcher/div_table.memhex",
        stSets, stWays, ptEntries, prefetchThreshold, useFilter);
    //Test delta = 0 and the filter
    mkAutoFSM(
        seq
            action
                d.reportAccess('h8000, MISS);
            endaction
            action
                d.reportAccess('h8080, MISS);
            endaction
            action
                d.reportAccess('h8100, MISS);
            endaction
            action
                d.reportAccess('h8180, MISS);
            endaction
            action
                d.reportAccess('h8180, MISS);
            endaction
            action endaction
            action
                d.reportAccess('h8200, MISS);
            endaction
            action
                d.reportAccess('h8280, MISS);
            endaction
            action
                d.reportAccess('h8300, MISS);
            endaction
            action
                d.reportAccess('h8380, MISS);
            endaction
            action 
                let addr <- d.getNextPrefetchAddr;
                doAssert(addr == 'h8400, "fail");
            endaction
            action 
                let addr <- d.getNextPrefetchAddr;
                doAssert(addr == 'h8480, "fail");
            endaction
            action
                $display("Test finished!");
            endaction
        endseq
    );
endmodule

module mkSignaturePathPrefetcherTest3(Empty);
    Parameter#(64) stSets <- mkParameter;
    Parameter#(4) stWays <- mkParameter;
    Parameter#(4096) ptEntries <- mkParameter;
    Prob prefetchThreshold = 7'b0101000;
    Bool useFilter = False;
    Prefetcher d <- mkSignaturePathPrefetcher(
        "./../../src_Testbench/Signature_path_prefetcher/div_table.memhex",
        stSets, stWays, ptEntries, prefetchThreshold, useFilter);
    //Test prefetching multiple deltas
    mkAutoFSM(
        seq
            action
                d.reportAccess('h8000, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h8080, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h8100, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h8180, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h8200, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h8280, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                let addr <- d.getNextPrefetchAddr;
                LineAddr lineAddr = truncate(addr);
                doAssert(addr == 'h8300, "test fail");
            endaction
            action
                let addr <- d.getNextPrefetchAddr;
                LineAddr lineAddr = truncate(addr);
                doAssert(addr == 'h8380, "test fail");
            endaction
            action
                let addr <- d.getNextPrefetchAddr;
                LineAddr lineAddr = truncate(addr);
                doAssert(addr == 'h8400, "test fail");
            endaction
            action endaction
            action endaction
            action endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h8240, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h82c0, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h8340, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h83c0, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h8440, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action endaction
            action endaction
            action
                let addr <- d.getNextPrefetchAddr;
                LineAddr lineAddr = truncate(addr);
                doAssert(addr == 'h84c0, "test fail");
            endaction
            action
                let addr <- d.getNextPrefetchAddr;
                LineAddr lineAddr = truncate(addr);
                doAssert(addr == 'h8400, "test fail");
            endaction
            action
                $display("Test finished!");
            endaction
        endseq
    );
endmodule

module mkPrefetchFilterTest(Empty);
    PrefetchFilter#(1024, 4, 8) d <- mkPrefetchFilter;
    mkAutoFSM(
        seq
            action
                d.reportAccess('h8000, HIT);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.reportAccess('h8080, MISS);
            endaction
            action endaction
            action endaction
            action endaction
            action
                d.canPrefetchReq('h8080);
            endaction
            action 
                let {b, addr} <- d.canPrefetchResp;
                doAssert(!b, "test fail");
            endaction
            action endaction
            action
                d.canPrefetchReq('h9080);
            endaction
            action 
                let {b, addr} <- d.canPrefetchResp;
                doAssert(b, "test fail");
            endaction
            action endaction
            action
                d.canPrefetchReq('h8000008080);
            endaction
            action 
                let {b, addr} <- d.canPrefetchResp;
                doAssert(b, "test fail");
            endaction
            action
                d.canPrefetchReq('h8090);
            endaction
            action 
                let {b, addr} <- d.canPrefetchResp;
                doAssert(b, "test fail");
            endaction
            action
                d.reportAccess('h8000008080, HIT);
            endaction
            action
                d.reportAccess('h8090, HIT);
            endaction
            action
                $display("Test finished!");
            endaction
        endseq
    );
endmodule

module mkPrefetchFilterTest2(Empty);
    PrefetchFilter#(1024, 3, 8) d <- mkPrefetchFilter;
    mkAutoFSM(
        seq
            action
                d.reportAccess('h9000, HIT);
            endaction
            action endaction
            action endaction
            action
                d.reportAccess('h9080, MISS);
            endaction
            action endaction
            action endaction
            action
                d.canPrefetchReq('h8000);
            endaction
            action 
                let {b, addr} <- d.canPrefetchResp;
                doAssert(b, "test fail");
            endaction
            action
                d.canPrefetchReq('h8040);
            endaction
            action 
                let {b, addr} <- d.canPrefetchResp;
                doAssert(b, "test fail");
            endaction
            action
                d.canPrefetchReq('h8080);
            endaction
            action 
                let {b, addr} <- d.canPrefetchResp;
                doAssert(b, "test fail");
            endaction
            action
                d.reportAccess('h8000, HIT);
            endaction
            action
                d.reportAccess('h8040, HIT);
            endaction
            action
                d.reportAccess('h8080, HIT);
            endaction
            action
                d.canPrefetchReq('h80c0);
            endaction
            action
                d.canPrefetchReq('h8100);
                let {b, addr} <- d.canPrefetchResp;
                doAssert(b, "test fail");
            endaction
            action
                d.canPrefetchReq('h8140);
                let {b, addr} <- d.canPrefetchResp;
                doAssert(b, "test fail");
            endaction
            action
                d.canPrefetchReq('h8180);
                let {b, addr} <- d.canPrefetchResp;
                doAssert(b, "test fail");
            endaction
            action
                d.canPrefetchReq('h81c0);
                let {b, addr} <- d.canPrefetchResp;
                doAssert(b, "test fail");
            endaction
            action
                let alpha = d.getCurrAlpha;
                doAssert(alpha == 7'b1111111, "fail"); //default value
            endaction
            action
                d.canPrefetchReq('h8200);
                let {b, addr} <- d.canPrefetchResp;
                doAssert(b, "test fail");
            endaction
            action 
                let {b, addr} <- d.canPrefetchResp;
                doAssert(b, "test fail");
            endaction
            action
                let alpha = d.getCurrAlpha;
                $display("Alpha %b", alpha);
                doAssert(alpha == 7'b0110000, "fail"); 
            endaction

            //Second part -- now only increment pfUseful
            action
                d.reportAccess('h80c0, HIT);
            endaction
            action
                d.reportAccess('h8100, HIT);
            endaction
            action
                d.reportAccess('h8140, HIT);
            endaction
            action
                d.reportAccess('h8180, HIT);
            endaction
            action
                d.reportAccess('h81c0, HIT);
            endaction
            action
                d.reportAccess('h8200, HIT);
            endaction
            action
                d.canPrefetchReq('h8240);
            endaction
            action
                d.canPrefetchReq('h8280);
                let {b, addr} <- d.canPrefetchResp;
                doAssert(b, "test fail");
            endaction
            action
                d.canPrefetchReq('h82c0);
                let {b, addr} <- d.canPrefetchResp;
                doAssert(b, "test fail");
            endaction
            action
                let {b, addr} <- d.canPrefetchResp;
                doAssert(b, "test fail");
            endaction
            action
                let alpha = d.getCurrAlpha;
                $display("Alpha %b", alpha);
                doAssert(alpha == 7'b1010000, "fail"); 
            endaction

            action
                $display("Test finished!");
            endaction
        endseq
    );
endmodule