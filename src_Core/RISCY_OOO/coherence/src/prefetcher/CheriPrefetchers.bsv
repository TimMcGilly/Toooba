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
import SpecialRegs::*;

`define VERBOSE True

//If the capability is small, prefetches all lines within the capability
module mkAllInCapPrefetcher#(Parameter#(maxCapSizeToPrefetch) _)(CheriPCPrefetcher) provisos (
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
        Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase);
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

typedef enum {
  INIT = 2'd0, TRANSIENT = 2'd1, STEADY = 2'd2, NO_PRED = 2'd3
} StrideState deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(12) lastAddr; 
    Int#(12) stride;
    Bit#(4) cLinesPrefetched; //Stores how many cache lines have been prefetched for this entry
    StrideState state;
} StrideEntry deriving (Bits, Eq, FShow);

//Use virtual base of bounds to index into table 
module mkCheriStridePrefetcher#(Parameter#(strideTableSize) _, Parameter#(cLinesAheadToPrefetch) __)(CheriPCPrefetcher)
provisos(
    Alias#(strideTableIndexT, Bit#(TLog#(strideTableSize))),
    Add#(a__, TLog#(strideTableSize), 8)
    );
    RWBramCore#(strideTableIndexT, StrideEntry) strideTable <- mkRWBramCoreForwarded;
    FIFOF#(Tuple3#(Addr, Bit#(8), HitOrMiss)) memAccesses <- mkSizedBypassFIFOF(8);
    Reg#(Tuple3#(Addr, Bit#(8), HitOrMiss)) rdRespEntry <- mkReg(?);

    Fifo#(8, Addr) addrToPrefetch <- mkOverflowPipelineFifo;
    FIFO#(Tuple3#(StrideEntry, Addr, Bit#(8))) strideEntryForPrefetch <- mkBypassFIFO();
    Reg#(Maybe#(Bit#(4))) cLinesPrefetchedLatest <- mkReg(?);
    PulseWire holdReadReq <- mkPulseWire;
    Array #(Reg #(EventsPrefetcher)) perf_events <- mkDRegOR (3, unpack (0));

    rule sendReadReq if (!holdReadReq);
        match {.addr, .boundsHash, .hitMiss} = memAccesses.first;
        if (`VERBOSE) $display("%t Sending read req for %h!", $time, boundsHash);
        strideTable.rdReq(truncate(boundsHash));
        rdRespEntry <= memAccesses.first;
        memAccesses.deq;
    endrule


    rule updateStrideEntry;
        //Find slot in vector
        //if miss and slot empty
        //if slot init, put address, stride and move to transit
        //if slot transit or steady, verify stride, and move to steady
        //    also put last_prefetched
        //if stride wrong, move to transit
        match {.addr, .boundsHash, .hitMiss} = rdRespEntry;
        strideTableIndexT index = truncate(boundsHash);
        StrideEntry se = strideTable.rdResp;
        strideTable.deqRdResp;
        StrideEntry seNext = se;
        Int#(12) observedStride = unpack(addr[11:0] - se.lastAddr);
        if (`VERBOSE) $display("%t Stride Prefetcher updateStrideEntry ", $time,
            fshow(hitMiss), " ", addr,
            ". Entry ", index, " state is ", fshow(se.state), "\n");
        if (se.state == INIT && observedStride != 0) begin
            if (se.stride == observedStride) begin
                //fast track to steady
                seNext.state = STEADY;
                if (`VERBOSE) $display(", stride matches so fast track back to STEADY");
            end
            else begin
                seNext.stride = observedStride;
                seNext.state = TRANSIENT;
                if (`VERBOSE) $display(", stride doesn't match, so set to %h", seNext.stride);
            end
            seNext.lastAddr = truncate(addr);
        end
        else if (se.state == TRANSIENT && observedStride != 0) begin
            if (observedStride == se.stride) begin
                //stride confimed, move to steady
                seNext.cLinesPrefetched = 0;
                seNext.state = STEADY;
                if (`VERBOSE) $display(", stride %h is confirmed!", seNext.stride);
            end
            else begin
                //We're seeing random accesses, go to no pred
                seNext.state = NO_PRED;
                seNext.stride = observedStride;
                if (`VERBOSE) $display(", we have a random stride (%h), go to NO_PRED", seNext.stride);
            end
            seNext.lastAddr = truncate(addr);
        end
        else if (se.state == STEADY && observedStride != 0) begin
            if (observedStride == se.stride) begin
                if (se.lastAddr[11:6] != addr[11:6]) begin
                    //This means we have crossed a cache line since last access
                    seNext.cLinesPrefetched = 
                        (se.cLinesPrefetched == 0) ? 0 : se.cLinesPrefetched - 1;
                end
                if (`VERBOSE) $display(", stride %h stays confirmed!", seNext.stride);
            end
            else begin
                //We jump to some other random location, so reset number of lines prefetched
                seNext.cLinesPrefetched = 0;
                seNext.state = INIT;
                if (`VERBOSE) $display(", random jump (%x)! Move to INIT, don't reset stride", observedStride);
            end
            seNext.lastAddr = truncate(addr);
        end
        else if (se.state == NO_PRED && observedStride != 0) begin
            if (observedStride == se.stride) begin
                seNext.state = TRANSIENT;
                if (`VERBOSE) $display(", have repeated stride: %h, move to TRANSIENT", seNext.stride);
            end
            else begin
                seNext.stride = observedStride;
                if (`VERBOSE) $display(", have random stride: %h", seNext.stride);
            end
            seNext.lastAddr = truncate(addr);
        end
        else
            if (`VERBOSE) $display("");
        
        strideEntryForPrefetch.enq(tuple3(seNext, addr, boundsHash));
    endrule

    rule createPrefetchRequests;
        match {.se, .addr, .boundsHash} = strideEntryForPrefetch.first;
        //If this rule is looping, then we'll have a valid cLinesPrefetchedLatest
        Bit#(4) cLinesPrefetched = fromMaybe(se.cLinesPrefetched, cLinesPrefetchedLatest);

        Int#(16) cLineSize = fromInteger(valueof(DataSz));
        Int#(16) strideToUse = signExtend(se.stride);
        if (abs(strideToUse) < cLineSize) begin
            strideToUse = (strideToUse < 0) ? -cLineSize : cLineSize; 
        end
        Bit#(16) jumpDist = pack(strideToUse) * zeroExtend(cLinesPrefetched+1);
        let reqAddr = addr + signExtend(jumpDist);

        if (se.state == STEADY && 
            cLinesPrefetched != 
            fromInteger(valueof(cLinesAheadToPrefetch)) &&
            reqAddr[63:12] == addr[63:12] //Check if same page
        ) begin
            //can prefetch

            addrToPrefetch.enq(reqAddr);
            EventsPrefetcher evt = unpack(0);
            evt.evt_2 = 1;
            if (se.stride < 'd64) begin
                evt.evt_3 = 1;
            end
            perf_events[0] <= evt;
            // We will still be processing this StrideEntry next cycle, 
            // so hold off any potential read requests until we do a writeback
            holdReadReq.send();
            cLinesPrefetchedLatest <= Valid(cLinesPrefetched + 1);
            if (`VERBOSE) $display("%t Stride Prefetcher getNextPrefetchAddr requesting %h for entry %h", $time, reqAddr, boundsHash[7:0]);
        end
        else begin
            //cant prefetch
            if (`VERBOSE) $display("%t Stride Prefetcher no possible prefetch for entry %h", $time, strideTableIndexT'(truncate(boundsHash)));
            strideEntryForPrefetch.deq;
            se.cLinesPrefetched = cLinesPrefetched;
            cLinesPrefetchedLatest <= Invalid;
            strideTable.wrReq(truncate(boundsHash), se);
        end
    endrule

    rule printEvt; 
        /*
        let evt = EventsPrefetcher {
            evt_0: (!memAccesses.notFull) ? 1 : 0,
            evt_1: (!addrToPrefetch.notFull) ? 1 : 0,
            evt_2: hashIsSmall ? 1 : 0,
            evt_3: 1
        };
        $display ("%t Prefetcher returning events ", $time, fshow(evt));
        */
        
    endrule

    method Action reportAccess(Addr addr, Bit#(16) pcHash, HitOrMiss hitMiss, Addr boundsOffset, Addr boundsLength, Addr boundsVirtBase);
        Bit#(8) boundsHash = hash(boundsVirtBase ^ boundsLength);
        //if (boundsHash == 0)
            //hashIsSmall.send();
        if (`VERBOSE) $display("%t Prefetcher reportAccess %h %h, hash: %h", $time, boundsLength, boundsVirtBase, boundsHash);
        memAccesses.enq(tuple3 (addr, boundsHash, hitMiss));
    endmethod

    method ActionValue#(Addr) getNextPrefetchAddr;
        addrToPrefetch.deq;
        return addrToPrefetch.first;
    endmethod

`ifdef PERFORMANCE_MONITORING
    method EventsPrefetcher events;
        let evt = EventsPrefetcher {
            evt_0: (!memAccesses.notFull) ? 1 : 0,
            evt_1: (!addrToPrefetch.notFull) ? 1 : 0,
            evt_2: perf_events[0].evt_2,
            evt_3: perf_events[0].evt_3
        };
        return evt;
    endmethod
`endif

endmodule
