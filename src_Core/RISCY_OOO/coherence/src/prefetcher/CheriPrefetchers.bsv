// Copyright (c) 2024 Karlis Susters 
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
import Types::*;
import CacheUtils::*;
import CCTypes::*;
import ISA_Decls   :: *;
import ProcTypes::*;
import Vector::*;
import FIFO::*;
import Fifos::*;
import FIFOF::*;
import SpecialFIFOs :: *;
import Ehr::*;
import GetPut::*;
import RWBramCore::*;

`define VERBOSE True

//If the capability is small, prefetches all lines within the capability
module mkAllInCapPrefetcher#(Parameter#(maxCapSizeToPrefetch) _)(PCPrefetcher) provisos (
    NumAlias#(pageIndexBits, 6), //assume 4k pages
    Alias#(pageAddressT, Bit#(TSub#(LineAddrSz, pageIndexBits)))
);
    Reg#(LineAddr) prefetchNext <- mkReg(0);
    Reg#(LineAddr) prefetchEnd <- mkReg(0); //inclusive
    Reg#(LineAddr) originalMiss <- mkReg(0);

    rule skipOriginalMiss if (prefetchNext == originalMiss);
        prefetchNext <= prefetchNext + 1;
    endrule
    method Action reportAccess(Addr addr, Bit#(16) pcHash, HitOrMiss hitMiss, 
        Addr boundsOffset, Addr boundsLength);
        if (hitMiss == MISS && boundsLength != 0) begin
            LineAddr cLinesInBounds = truncateLSB(boundsLength) + 1;
            Addr boundsBase = addr-boundsOffset;
            Addr boundsTop = addr+(boundsLength-boundsOffset-1);
            if (`VERBOSE) $display("%t Prefetcher report MISS %h (bottom: %h, top: %h)", 
                $time, addr, boundsBase, boundsTop);
            if (boundsLength <= fromInteger(valueof(maxCapSizeToPrefetch))) begin
                pageAddressT basePage = truncateLSB(boundsBase);
                pageAddressT addrPage = truncateLSB(addr);
                pageAddressT topPage = truncateLSB(boundsTop);
                if (basePage != addrPage) begin
                    //If base is in a different page, fetch from bottom of this page.
                    boundsBase = Addr'{addrPage, 0};
                end
                if (topPage != addrPage) begin
                    //If base is in a different page, fetch until the top of this page.
                    boundsTop = Addr'{addrPage, 12'hfff};
                end
                prefetchNext <= getLineAddr(boundsBase);
                prefetchEnd <= getLineAddr(boundsTop);
                originalMiss <= getLineAddr(addr);
                if (`VERBOSE) $display("%t Prefetcher MISS bounds length %d, so set up prefetches from %h to %h", 
                    $time, boundsLength, boundsBase, boundsTop);
            end
        end
        else 
            if (`VERBOSE) $display("%t Prefetcher report HIT %h", $time, addr);
    endmethod
    method ActionValue#(Addr) getNextPrefetchAddr 
        if (prefetchNext <= prefetchEnd && prefetchNext != originalMiss);
        
        prefetchNext <= prefetchNext + 1;
        if (`VERBOSE) $display("%t Prefetcher getNextPrefetchAddr %h", $time,Addr'{prefetchNext, '0});
        return Addr'{prefetchNext, '0};

    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        return EventsPrefetcher { evt_0: 1,
                     evt_1: 2,
                     evt_2: 3,
                     evt_3: 4};
    endmethod
`endif

endmodule
